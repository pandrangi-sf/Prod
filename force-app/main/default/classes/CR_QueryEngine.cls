public with sharing class CR_QueryEngine {
    private static final Integer DEFAULT_PAGE_SIZE = 100;
    private static final Integer MAX_PAGE_SIZE = 2000;
    private static final Integer CHILD_SUBQUERY_LIMIT = 200;
    private static final Set<String> ALLOWED_AGGREGATES = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
    private static final Set<String> ALLOWED_OPERATORS = new Set<String>{
        '=', '!=', '>', '>=', '<', '<=', 'LIKE', 'IN', 'NOT IN', 'INCLUDES', 'EXCLUDES', 'IS NULL', 'IS NOT NULL'
    };
    // Phase 3 v5: global killswitch for Platform Cache. Flip to false + redeploy
    // to disable all caching org-wide without removing the wiring (faster than
    // a metadata-rollback if a caching bug surfaces in prod).
    @TestVisible
    private static Boolean CACHE_ENABLED = true;

    private class DatasetResolution {
        String datasetKey;
        String mode;
        String sobjectApiName;
        String primaryObject;
    }

    private class QueryField {
        String requestedPath;
        String soqlPath;
        String label;
        String dataType;
        Boolean numeric;
        Boolean childCollection;
        String childRelationshipName;
        String childSoqlPath;
    }

    private class ChildFieldResolution {
        String relationshipName;
        String childObjectApiName;
        String childFieldPath;
    }

    @AuraEnabled(cacheable=true)
    public static CR_Types.ValidationResult validateDefinition(String definitionJson) {
        CR_Types.ValidationResult result = new CR_Types.ValidationResult();
        try {
            Map<String, Object> definition = parseDefinition(definitionJson);
            // Expand metric references first so validation checks the real aggregations
            // (and surfaces a friendly message if a metric is unknown/inactive/incompatible).
            CR_MetricService.resolveIntoDefinition(definition);
            DatasetResolution dataset = resolveDataset(definition);
            List<QueryField> fields = extractFields(definition, dataset);

            if (fields.isEmpty()) {
                result.addError('Select at least one field.');
            }
            for (String groupField : extractPathList(definition.get('groupings'), 'field')) {
                String groupPath = normalizePath(dataset, groupField);
                rejectChildCollectionPath(dataset, groupPath, 'groupings');
                validateFieldPath(dataset.sobjectApiName, groupPath);
            }
            for (Object aggregateObject : asObjectList(definition.get('aggregations'))) {
                Map<String, Object> aggregateMap = asMap(aggregateObject);
                String functionName = asString(aggregateMap.get('function')).toUpperCase();
                if (!ALLOWED_AGGREGATES.contains(functionName)) {
                    result.addError('Unsupported aggregate function: ' + functionName);
                }
                String fieldPath = normalizePath(dataset, asString(aggregateMap.get('field')));
                if (functionName != 'COUNT' || !String.isBlank(fieldPath)) {
                    rejectChildCollectionPath(dataset, fieldPath, 'aggregations');
                    validateFieldPath(dataset.sobjectApiName, fieldPath);
                }
            }
            validateFilters(dataset, definition.get('filters'), result);
        } catch (Exception ex) {
            result.addError(ex.getMessage());
        }
        return result;
    }

    // Non-throwing STRUCTURAL validation of an override / dashboard filter JSON.
    // Safe to call from ANY context (incl. Queueable / Batch): it never reaches a
    // `throw new AuraHandledException`, which is illegal — and uncatchable — off the
    // Aura/VF stack. Checks JSON parses, node shapes, and that each leaf filter has a
    // field + a supported operator. It does NOT describe-check field existence
    // (that requires the throwing engine path); the save-time validator does that.
    // Returns collected error messages; empty list = structurally valid.
    public static List<String> validateOverrideFiltersStructural(String filtersJson) {
        List<String> errors = new List<String>();
        if (String.isBlank(filtersJson)) {
            return errors;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(filtersJson);
        } catch (Exception ex) {
            errors.add('Filter override is not valid JSON.');
            return errors;
        }
        validateFilterNodeStructural(parsed, errors);
        return errors;
    }

    private static void validateFilterNodeStructural(Object node, List<String> errors) {
        if (node == null) {
            return;
        }
        if (node instanceof List<Object>) {
            for (Object child : (List<Object>) node) {
                validateFilterNodeStructural(child, errors);
            }
            return;
        }
        if (!(node instanceof Map<String, Object>)) {
            errors.add('Each filter must be an object with field, operator and value.');
            return;
        }
        Map<String, Object> m = (Map<String, Object>) node;
        if (m.containsKey('conditions')) {
            for (Object child : asObjectList(m.get('conditions'))) {
                validateFilterNodeStructural(child, errors);
            }
            return;
        }
        String field = firstNonBlank(new List<String>{ asString(m.get('field')), asString(m.get('path')) });
        String operator = asString(m.get('operator'));
        if (String.isBlank(field)) {
            errors.add('A filter is missing its field.');
        }
        if (String.isBlank(operator)) {
            errors.add('A filter is missing its operator.');
        } else if (!ALLOWED_OPERATORS.contains(operator.toUpperCase())) {
            errors.add('Unsupported filter operator: ' + operator);
        }
    }

    // FULL validation (incl. field existence/filterability) of an override filter
    // JSON against a saved report's dataset. Engine validation throws
    // AuraHandledException for bad fields/operators; those throws are caught here so
    // this only ever RETURNS errors. MUST be called from an Aura context (the save
    // path) — off the Aura stack the engine throws are uncatchable, so non-Aura
    // callers (the subscription Queueable) must use validateOverrideFiltersStructural.
    public static List<String> validateReportOverrideFilters(Id reportDefinitionId, String filtersJson) {
        List<String> errors = validateOverrideFiltersStructural(filtersJson);
        if (!errors.isEmpty() || String.isBlank(filtersJson) || reportDefinitionId == null) {
            return errors;
        }
        try {
            Report_Definition__c rec = [
                SELECT Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportDefinitionId LIMIT 1
            ];
            Map<String, Object> definition = parseDefinition(rec.Definition_JSON__c);
            DatasetResolution dataset = resolveDataset(definition);
            Schema.SObjectType st = Schema.getGlobalDescribe().get(dataset.sobjectApiName);
            Map<String, Schema.SObjectField> fieldMap = (st == null) ? null : st.getDescribe().fields.getMap();
            // Describe-based check (not the engine's throwing path): AuraHandledException
            // .getMessage() returns the unhelpful "Script-thrown exception", so building
            // our own message keeps the bad field name in the error shown to the admin.
            validateFilterFieldsExist(JSON.deserializeUntyped(filtersJson), dataset, fieldMap, errors);
        } catch (Exception ex) {
            errors.add('the report dataset could not be resolved for validation.');
        }
        return errors;
    }

    // Best-effort field-existence check for override filters at save time. Flags
    // clearly-absent simple (non-relationship) fields with a descriptive message;
    // relationship / fact-mapped paths are left to the run-time engine to avoid false
    // positives. Never throws.
    private static void validateFilterFieldsExist(
        Object node, DatasetResolution dataset, Map<String, Schema.SObjectField> fieldMap, List<String> errors
    ) {
        if (node == null || fieldMap == null) {
            return;
        }
        if (node instanceof List<Object>) {
            for (Object child : (List<Object>) node) {
                validateFilterFieldsExist(child, dataset, fieldMap, errors);
            }
            return;
        }
        if (!(node instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> m = (Map<String, Object>) node;
        if (m.containsKey('conditions')) {
            for (Object child : asObjectList(m.get('conditions'))) {
                validateFilterFieldsExist(child, dataset, fieldMap, errors);
            }
            return;
        }
        String raw = firstNonBlank(new List<String>{ asString(m.get('field')), asString(m.get('path')) });
        if (String.isBlank(raw)) {
            return; // structural pass already flagged a missing field
        }
        String path = normalizePath(dataset, raw);
        if (!path.contains('.') && !fieldMap.containsKey(path.toLowerCase())) {
            errors.add('No such field "' + raw + '" on ' + dataset.sobjectApiName + '.');
        }
    }

    @AuraEnabled
    public static CR_Types.QueryResult runReportById(Id reportDefinitionId, String pageToken, Integer pageSize, String dashboardFiltersJson) {
        return runSavedReport(reportDefinitionId, pageToken, pageSize, dashboardFiltersJson, null, null);
    }

    // Server-side sort variant. The report viewer calls this when a user sorts a column so the
    // ORDER BY is applied across the ENTIRE result set, not just the loaded page. The previous
    // viewer behavior sorted only the loaded page in JS — which made a date-range report look
    // like it held only the first day or two of data, because page 1 is Id-ordered and the ETL
    // inserts facts in date order. sortField is a column/field path; sortDir is 'asc'/'desc'.
    @AuraEnabled
    public static CR_Types.QueryResult runReportByIdSorted(Id reportDefinitionId, String pageToken, Integer pageSize, String dashboardFiltersJson, String sortField, String sortDir) {
        return runSavedReport(reportDefinitionId, pageToken, pageSize, dashboardFiltersJson, sortField, sortDir);
    }

    public class GroupCount {
        @AuraEnabled public String value;
        @AuraEnabled public Integer count;
    }

    public class GroupCount2 {
        @AuraEnabled public String value1;
        @AuraEnabled public String value2;
        @AuraEnabled public Integer count;
    }

    // Total number of rows the report returns under the current filters — a cheap COUNT so the
    // viewer can show "Showing 100 of 14,166" instead of letting page 1 read as the whole set.
    @AuraEnabled
    public static Integer getReportRowCount(Id reportDefinitionId, String dashboardFiltersJson) {
        if (reportDefinitionId == null) {
            return 0;
        }
        Report_Definition__c rec = [
            SELECT Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportDefinitionId LIMIT 1
        ];
        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(rec.Definition_JSON__c);
        def.put('groupings', new List<Object>());
        def.put('aggregations', new List<Object>{ new Map<String, Object>{ 'function' => 'COUNT' } });
        def.put('sort', new List<Object>());
        CR_Types.QueryResult r = runReport(JSON.serialize(def), null, 1, dashboardFiltersJson);
        for (CR_Types.ColumnInfo c : r.columns) {
            if (c.dataType == 'AGGREGATE') {
                Object v = (r.rows == null || r.rows.isEmpty()) ? null : r.rows[0].get(c.key);
                return v == null ? 0 : Integer.valueOf(String.valueOf(v));
            }
        }
        return 0;
    }

    // Two-dimension breakdown for "month x Record Type" style cross-grouping, computed server-side
    // over the whole result set. field1 (optionally bucketed by gran1) is the outer dimension,
    // field2 (optionally gran2) the inner. Returns one row per (value1, value2) with its count.
    @AuraEnabled
    public static List<GroupCount2> getCrossGroupSummary(
        Id reportDefinitionId, String field1, String gran1, String field2, String gran2, String dashboardFiltersJson
    ) {
        List<GroupCount2> out = new List<GroupCount2>();
        if (reportDefinitionId == null || String.isBlank(field1) || String.isBlank(field2)) {
            return out;
        }
        Report_Definition__c rec = [
            SELECT Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportDefinitionId LIMIT 1
        ];
        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(rec.Definition_JSON__c);
        Map<String, Object> g1 = new Map<String, Object>{ 'field' => field1 };
        if (String.isNotBlank(gran1)) g1.put('granularity', gran1);
        Map<String, Object> g2 = new Map<String, Object>{ 'field' => field2 };
        if (String.isNotBlank(gran2)) g2.put('granularity', gran2);
        def.put('groupings', new List<Object>{ g1, g2 });
        def.put('aggregations', new List<Object>{ new Map<String, Object>{ 'function' => 'COUNT' } });
        def.put('sort', new List<Object>());

        CR_Types.QueryResult r = runReport(JSON.serialize(def), null, 2000, dashboardFiltersJson);
        List<String> groupKeys = new List<String>();
        String countKey;
        for (CR_Types.ColumnInfo c : r.columns) {
            if (c.dataType == 'AGGREGATE') {
                countKey = c.key;
            } else {
                groupKeys.add(c.key);
            }
        }
        if (groupKeys.size() < 2) {
            return out;
        }
        for (Map<String, Object> row : r.rows) {
            GroupCount2 gc = new GroupCount2();
            gc.value1 = row.get(groupKeys[0]) == null ? null : String.valueOf(row.get(groupKeys[0]));
            gc.value2 = row.get(groupKeys[1]) == null ? null : String.valueOf(row.get(groupKeys[1]));
            gc.count = row.get(countKey) == null ? 0 : Integer.valueOf(String.valueOf(row.get(countKey)));
            out.add(gc);
        }
        return out;
    }

    // Full group breakdown for a report + a group field, computed by a server-side aggregate so it
    // covers the ENTIRE result set. The viewer used to group only the loaded page, which made
    // "group by month" show a single bucket on a date-range report. Respects the same filters the
    // table is showing (dashboard + interactive column filters, passed as dashboardFiltersJson).
    @AuraEnabled
    public static List<GroupCount> getGroupSummary(Id reportDefinitionId, String groupField, String dashboardFiltersJson, String granularity) {
        List<GroupCount> out = new List<GroupCount>();
        if (reportDefinitionId == null || String.isBlank(groupField)) {
            return out;
        }
        Report_Definition__c rec = [
            SELECT Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportDefinitionId LIMIT 1
        ];
        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(rec.Definition_JSON__c);
        // A granularity (day/week/month/quarter/year) buckets a date field server-side — used by
        // the viewer's Time Grain "Group by month", which previously bucketed the loaded page in
        // JS (page-local, and with a timezone rollback). Blank = group by the raw field value.
        Map<String, Object> grouping = new Map<String, Object>{ 'field' => groupField };
        if (String.isNotBlank(granularity)) {
            grouping.put('granularity', granularity);
        }
        def.put('groupings', new List<Object>{ grouping });
        def.put('aggregations', new List<Object>{ new Map<String, Object>{ 'function' => 'COUNT' } });
        def.put('sort', new List<Object>());

        CR_Types.QueryResult r = runReport(JSON.serialize(def), null, 2000, dashboardFiltersJson);
        String groupKey;
        String countKey;
        for (CR_Types.ColumnInfo c : r.columns) {
            if (c.dataType == 'AGGREGATE') {
                countKey = c.key;
            } else if (groupKey == null) {
                groupKey = c.key;
            }
        }
        for (Map<String, Object> row : r.rows) {
            GroupCount gc = new GroupCount();
            gc.value = row.get(groupKey) == null ? null : String.valueOf(row.get(groupKey));
            gc.count = row.get(countKey) == null ? 0 : Integer.valueOf(String.valueOf(row.get(countKey)));
            out.add(gc);
        }
        return out;
    }

    private static CR_Types.QueryResult runSavedReport(Id reportDefinitionId, String pageToken, Integer pageSize, String dashboardFiltersJson, String sortFieldOverride, String sortDirOverride) {
        // Phase 1 v7: log every saved-report execution to Report_Run__c for
        // capacity planning and slow-report trending. Timing wraps the inner
        // runReport call only — Apex cursor query against Report_Definition__c
        // and the bookkeeping update are intentionally excluded so the duration
        // reflects what the SOQL builder + executor actually spent.
        //
        // Phase 3 v5: try Platform Cache before SOQL. Cache only on first-page
        // (unpaged) reads; paged reads include a stateful pageToken that we'd
        // have to bake into the cache key (and most users don't re-fetch the
        // same page within the TTL anyway).
        Report_Definition__c record = [
            SELECT Id, Name, Definition_JSON__c, Dataset_Key__c
            FROM Report_Definition__c
            WHERE Id = :reportDefinitionId
            LIMIT 1
        ];

        // A user-chosen column sort is injected into the definition so ORDER BY runs server-side.
        String definitionJson = record.Definition_JSON__c;
        Boolean hasSortOverride = String.isNotBlank(sortFieldOverride);
        if (hasSortOverride) {
            definitionJson = injectSortOverride(definitionJson, sortFieldOverride, sortDirOverride);
        }

        // Cache READ attempt (only on first-page reads + when cache enabled). Skip for sorted
        // views — they vary by sort and must not read from or write to the shared cache key.
        Boolean cacheable = CACHE_ENABLED
            && !hasSortOverride
            && String.isBlank(pageToken)
            && isCacheEnabledForDataset(record.Dataset_Key__c);
        String cacheKey = cacheable ? CR_QueryCacheService.buildKey(reportDefinitionId, dashboardFiltersJson) : null;
        if (cacheable) {
            CR_Types.QueryResult cached = CR_QueryCacheService.get(cacheKey);
            if (cached != null) {
                cached.cacheHit = true;
                // Don't log to Report_Run__c on cache hit — the audit log
                // is about real SOQL executions, not free renders.
                return cached;
            }
        }

        Datetime runAt = System.now();
        Long startMs = System.currentTimeMillis();
        CR_Types.QueryResult result;
        try {
            result = runReport(definitionJson, pageToken, pageSize, dashboardFiltersJson);
        } catch (Exception ex) {
            CR_RunHistoryService.logRun(
                reportDefinitionId,
                runAt,
                (Integer)(System.currentTimeMillis() - startMs),
                0,
                false,
                ex.getMessage()
            );
            throw ex;
        }
        Integer durationMs = (Integer)(System.currentTimeMillis() - startMs);
        CR_RunHistoryService.logRun(
            reportDefinitionId,
            runAt,
            durationMs,
            result == null ? 0 : result.rowCount,
            result != null && result.aggregateResult == true,
            null
        );
        if (result != null) {
            result.cacheHit = false;
            // Cache WRITE on miss + success. Errors above re-throw before reaching here,
            // so a row in cache always represents a successful execution.
            if (cacheable) {
                CR_QueryCacheService.put(cacheKey, result, ttlForDataset(record.Dataset_Key__c));
            }
        }
        // Stamp last-run status. Done without sharing + fail-soft: under OWD
        // Public Read Only a non-owner/non-admin has read-only ROW access, so a
        // "with sharing" update here throws INSUFFICIENT_ACCESS_OR_READONLY and
        // breaks an otherwise-successful run. It bites only on a cache MISS
        // (first run); the next run is served from Platform Cache and returns
        // before this line, which masked the bug as "first run fails, second
        // works." Bookkeeping must never fail the user's report — same contract
        // as CR_RunHistoryService.logRun.
        new RunStamper().stamp(reportDefinitionId, result == null ? 0 : result.rowCount);
        return result;
    }

    // Writes Last_Run_At/Status regardless of the running user's record-level
    // sharing on the Report_Definition__c. Apex DML already runs in system mode
    // for CRUD/FLS; the "without sharing" here is what lets a Public-Read-Only,
    // non-owner user stamp a record they can only read. Fail-soft by design.
    private without sharing class RunStamper {
        private void stamp(Id reportDefinitionId, Integer rowCount) {
            try {
                update new Report_Definition__c(
                    Id = reportDefinitionId,
                    Last_Run_At__c = System.now(),
                    Last_Run_Status__c = 'Success: ' + rowCount + ' rows returned'
                );
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN, 'CR_QueryEngine run stamp suppressed: ' + ex.getMessage());
            }
        }
    }

    // Reads CR_Dataset__mdt.Cache_Enabled__c. Defaults to true if the dataset
    // metadata record doesn't exist (unknown dataset → assume cacheable; the
    // global CACHE_ENABLED killswitch is the master safety net).
    private static Boolean isCacheEnabledForDataset(String datasetKey) {
        if (String.isBlank(datasetKey)) return true;
        CR_Dataset__mdt md = CR_Dataset__mdt.getInstance(datasetKey);
        return md == null || md.Cache_Enabled__c == null || md.Cache_Enabled__c == true;
    }

    // Reads CR_Dataset__mdt.Cache_TTL_Seconds__c. Returns null to let the
    // CR_QueryCacheService apply its own default (300s).
    private static Integer ttlForDataset(String datasetKey) {
        if (String.isBlank(datasetKey)) return null;
        CR_Dataset__mdt md = CR_Dataset__mdt.getInstance(datasetKey);
        if (md == null || md.Cache_TTL_Seconds__c == null) return null;
        return Integer.valueOf(md.Cache_TTL_Seconds__c);
    }

    // Bundles N saved-report executions into a single Apex round-trip. Used by
    // dashboard "Refresh All Widgets" to avoid paying network RTT per widget.
    // Apex is single-threaded inside a transaction, so the queries themselves
    // still run sequentially — the savings are RTT × (N-1).
    //
    // Cap at 50 reports per call to stay well under the SOQL-per-transaction
    // governor (100); a single dashboard rarely exceeds 12 widgets so this is
    // ample headroom without inviting abuse.
    @AuraEnabled
    public static Map<Id, CR_Types.QueryResult> runReportsByIds(
        List<Id> reportDefinitionIds,
        Integer pageSize,
        String dashboardFiltersJson
    ) {
        Map<Id, CR_Types.QueryResult> out = new Map<Id, CR_Types.QueryResult>();
        if (reportDefinitionIds == null || reportDefinitionIds.isEmpty()) return out;
        if (reportDefinitionIds.size() > 50) {
            throw new AuraHandledException('runReportsByIds accepts at most 50 ids per call.');
        }
        // Per-id failures are reported as a populated errorMessage on the
        // QueryResult rather than throwing — a single bad report shouldn't
        // sink the whole dashboard refresh.
        for (Id rdId : reportDefinitionIds) {
            try {
                out.put(rdId, runReportById(rdId, null, pageSize, dashboardFiltersJson));
            } catch (Exception ex) {
                CR_Types.QueryResult err = new CR_Types.QueryResult();
                err.columns = new List<CR_Types.ColumnInfo>();
                err.rows = new List<Map<String, Object>>();
                err.totals = new Map<String, Object>();
                err.groupLevels = new List<String>();
                err.warnings = new List<String>();
                err.rowCount = 0;
                err.errorMessage = ex.getMessage();
                out.put(rdId, err);
            }
        }
        return out;
    }

    @AuraEnabled
    public static CR_Types.QueryResult runReport(String definitionJson, String pageToken, Integer pageSize, String dashboardFiltersJson) {
        Integer boundedPageSize = Math.min(Math.max(pageSize == null ? DEFAULT_PAGE_SIZE : pageSize, 1), MAX_PAGE_SIZE);
        Map<String, Object> definition = parseDefinition(definitionJson);
        // Expand any governed-metric references into concrete aggregations before the
        // engine reads them. No-op unless the definition actually cites a metric.
        CR_MetricService.resolveIntoDefinition(definition);
        DatasetResolution dataset = resolveDataset(definition);
        List<QueryField> fields = extractFields(definition, dataset);
        List<GroupSpec> groupSpecs = buildGroupSpecs(dataset, definition.get('groupings'));
        List<Object> aggregations = asObjectList(definition.get('aggregations'));
        Boolean aggregateQuery = !aggregations.isEmpty() || !groupSpecs.isEmpty();

        List<String> sortWarnings = new List<String>();
        // Tabular only: aggregate queries build their own ORDER BY in buildAggregateSoql and
        // never paginate, and running sort validation over them here would start throwing on
        // sort entries that were previously ignored.
        List<SortKey> sortKeys = aggregateQuery ? null : buildSortKeys(dataset, definition, sortWarnings);
        // A cursor names the ordered sequence it is a position in, so continuing it must reuse
        // that ordering. Callers don't always resend the active sort with the page request (the
        // report viewer's Next button doesn't), and ordering page 2 differently from the cursor
        // is precisely the mismatch that loses rows. Honour the cursor's own ordering instead.
        if (!aggregateQuery) {
            sortKeys = alignSortKeysToToken(dataset, pageToken, sortKeys);
        }

        String whereClause = buildWhereClause(dataset, definition.get('filters'));
        String dashboardWhere = String.isBlank(dashboardFiltersJson) ? '' : buildWhereClause(dataset, parseDashboardFiltersSafe(dashboardFiltersJson));
        String tokenWhere = aggregateQuery ? '' : buildTokenWhere(pageToken, sortKeys);
        List<String> whereParts = new List<String>();
        if (!String.isBlank(whereClause)) whereParts.add(whereClause);
        if (!String.isBlank(dashboardWhere)) whereParts.add(dashboardWhere);
        if (!String.isBlank(tokenWhere)) whereParts.add(tokenWhere);

        String soql = aggregateQuery
            ? buildAggregateSoql(dataset, fields, groupSpecs, aggregations, whereParts, definition)
            : buildTabularSoql(dataset, fields, whereParts, sortKeys, boundedPageSize);

        CR_Types.QueryResult result = aggregateQuery
            ? executeAggregate(soql, fields, groupSpecs, aggregations, dataset)
            : executeTabular(soql, fields, sortKeys, boundedPageSize);
        result.executedSoql = soql;
        result.aggregateResult = aggregateQuery;
        result.warnings = sortWarnings;
        // Viewer-side default grouping hint (display only; no SOQL impact).
        Object viewGroupBy = definition.get('viewGroupBy');
        result.viewGroupBy = viewGroupBy == null ? null : String.valueOf(viewGroupBy);
        result.rows = CR_FormulaEngine.applyFormulasAndBuckets(result.rows, definition);
        return result;
    }

    private static Map<String, Object> parseDefinition(String definitionJson) {
        if (String.isBlank(definitionJson)) {
            throw new AuraHandledException('Report definition JSON is required.');
        }
        Object rawDefinition = JSON.deserializeUntyped(definitionJson);
        if (!(rawDefinition instanceof Map<String, Object>)) {
            throw new AuraHandledException('Report definition must be a JSON object.');
        }
        return (Map<String, Object>) rawDefinition;
    }

    private static DatasetResolution resolveDataset(Map<String, Object> definition) {
        DatasetResolution dataset = new DatasetResolution();
        Object datasetObject = definition.get('dataset');
        Map<String, Object> datasetMap = datasetObject instanceof Map<String, Object> ? (Map<String, Object>) datasetObject : null;
        String datasetKey = datasetMap == null ? asString(datasetObject) : asString(datasetMap.get('datasetKey'));
        dataset.datasetKey = datasetKey;
        dataset.mode = datasetMap == null ? null : asString(datasetMap.get('mode'));
        dataset.sobjectApiName = datasetMap == null ? null : firstNonBlank(new List<String>{
            asString(datasetMap.get('objectApiName')),
            asString(datasetMap.get('factObject')),
            asString(datasetMap.get('primaryObject'))
        });
        dataset.primaryObject = datasetMap == null ? null : firstNonBlank(new List<String>{
            asString(datasetMap.get('primaryObject')),
            dataset.sobjectApiName
        });

        if (String.isBlank(dataset.sobjectApiName) && !String.isBlank(datasetKey)) {
            if (Schema.getGlobalDescribe().containsKey(datasetKey)) {
                dataset.sobjectApiName = datasetKey;
                dataset.primaryObject = datasetKey;
                dataset.mode = 'live';
            } else {
                CR_Dataset__mdt metadata = CR_Dataset__mdt.getInstance(datasetKey);
                if (metadata != null) {
                    dataset.sobjectApiName = metadata.SObject_API_Name__c;
                    dataset.mode = String.isBlank(metadata.Mode__c) ? 'hybrid' : metadata.Mode__c;
                    dataset.primaryObject = dataset.sobjectApiName;
                }
            }
        }

        if (String.isBlank(dataset.sobjectApiName)) {
            throw new AuraHandledException('Dataset must resolve to a queryable object.');
        }
        if (String.isBlank(dataset.primaryObject)) {
            dataset.primaryObject = dataset.sobjectApiName;
        }
        Schema.SObjectType sobjectType = Schema.getGlobalDescribe().get(dataset.sobjectApiName);
        if (sobjectType == null || !sobjectType.getDescribe().isQueryable() || !sobjectType.getDescribe().isAccessible()) {
            throw new AuraHandledException('You do not have access to query dataset object ' + dataset.sobjectApiName + '.');
        }
        return dataset;
    }

    private static List<QueryField> extractFields(Map<String, Object> definition, DatasetResolution dataset) {
        List<QueryField> fields = new List<QueryField>();
        for (Object fieldObject : asObjectList(definition.get('fields'))) {
            String path;
            String label;
            if (fieldObject instanceof String) {
                path = (String) fieldObject;
            } else {
                Map<String, Object> fieldMap = asMap(fieldObject);
                path = firstNonBlank(new List<String>{ asString(fieldMap.get('path')), asString(fieldMap.get('field')) });
                label = asString(fieldMap.get('label'));
            }
            if (String.isBlank(path)) {
                continue;
            }

            QueryField field = new QueryField();
            field.requestedPath = path;
            field.soqlPath = normalizePath(dataset, path);
            field.childCollection = false;

            ChildFieldResolution childResolution = resolveChildField(dataset.sobjectApiName, field.soqlPath);
            Schema.DescribeFieldResult fieldDescribe;
            if (childResolution == null) {
                fieldDescribe = validateFieldPath(dataset.sobjectApiName, field.soqlPath);
            } else {
                field.childCollection = true;
                field.childRelationshipName = childResolution.relationshipName;
                field.childSoqlPath = childResolution.childFieldPath;
                fieldDescribe = validateFieldPath(childResolution.childObjectApiName, childResolution.childFieldPath);
            }
            String chosenLabel = shouldUseDescribeLabel(label, field.requestedPath, field.soqlPath) ? fieldDescribe.getLabel() : label;
            // Phase 1 v18: legacy reports were saved with column labels of the form
            // "<Primary Object Label>: <Field Label>" (the selector's old picker
            // format leaked through into fieldLabels). Strip that leading
            // primary-object-label prefix so the column header reads as just the
            // field label. New reports already produce the clean form.
            field.label = stripPrimaryObjectLabelPrefix(chosenLabel, dataset);
            field.dataType = String.valueOf(fieldDescribe.getType());
            field.numeric = isNumeric(fieldDescribe.getType());
            fields.add(field);
        }
        return fields;
    }

    // Backward-compat helper for Phase 1 v18 label cleanup. Older selector
    // builds prefixed every primary-field option label with the dataset's
    // object label ("Fact Visit Activity Service: Subject"); reports saved
    // during that period have those verbose strings baked into their
    // fieldLabels map. We strip the prefix at engine load time so existing
    // reports display clean column headers without forcing a re-save.
    @TestVisible
    private static String stripPrimaryObjectLabelPrefix(String chosenLabel, DatasetResolution dataset) {
        if (String.isBlank(chosenLabel) || dataset == null || String.isBlank(dataset.sobjectApiName)) {
            return chosenLabel;
        }
        Schema.SObjectType sobjectType = Schema.getGlobalDescribe().get(dataset.sobjectApiName);
        if (sobjectType == null) {
            return chosenLabel;
        }
        String objectLabel = sobjectType.getDescribe().getLabel();
        if (String.isBlank(objectLabel)) {
            return chosenLabel;
        }
        String prefix = objectLabel + ': ';
        if (chosenLabel.length() > prefix.length()
            && chosenLabel.substring(0, prefix.length()).equalsIgnoreCase(prefix)) {
            return chosenLabel.substring(prefix.length()).trim();
        }
        return chosenLabel;
    }

    private static Boolean shouldUseDescribeLabel(String label, String requestedPath, String soqlPath) {
        if (String.isBlank(label)) {
            return true;
        }
        String trimmed = label.trim();
        return equalsIgnoreCase(trimmed, requestedPath) || equalsIgnoreCase(trimmed, soqlPath);
    }

    private static ChildFieldResolution resolveChildField(String rootObject, String soqlPath) {
        if (String.isBlank(rootObject) || String.isBlank(soqlPath) || !soqlPath.contains('.')) {
            return null;
        }
        Schema.SObjectType rootType = Schema.getGlobalDescribe().get(rootObject);
        if (rootType == null) {
            return null;
        }

        List<String> segments = soqlPath.split('\\.');
        String relationshipName = segments[0];
        String childFieldPath = joinSegments(segments, 1);
        for (Schema.ChildRelationship child : rootType.getDescribe().getChildRelationships()) {
            if (!equalsIgnoreCase(child.getRelationshipName(), relationshipName) || child.getChildSObject() == null) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = child.getChildSObject().getDescribe();
            if (!childDescribe.isQueryable() || !childDescribe.isAccessible()) {
                throw new AuraHandledException('You do not have access to query child relationship ' + child.getRelationshipName() + '.');
            }

            ChildFieldResolution resolution = new ChildFieldResolution();
            resolution.relationshipName = child.getRelationshipName();
            resolution.childObjectApiName = childDescribe.getName();
            resolution.childFieldPath = childFieldPath;
            return resolution;
        }
        return null;
    }

    private static void rejectChildCollectionPath(DatasetResolution dataset, String normalizedPath, String usage) {
        if (resolveChildField(dataset.sobjectApiName, normalizedPath) != null) {
            throw new AuraHandledException('Child collection fields cannot be used for ' + usage + ' yet: ' + normalizedPath);
        }
    }

    private static Schema.DescribeFieldResult validateFieldPath(String rootObject, String soqlPath) {
        if (String.isBlank(soqlPath)) {
            throw new AuraHandledException('Field path is required.');
        }
        Schema.SObjectType currentType = Schema.getGlobalDescribe().get(rootObject);
        if (currentType == null) {
            throw new AuraHandledException('Object not found: ' + rootObject);
        }
        List<String> segments = soqlPath.split('\\.');
        for (Integer i = 0; i < segments.size(); i++) {
            String segment = segments[i];
            Map<String, Schema.SObjectField> fields = currentType.getDescribe().fields.getMap();
            if (i == segments.size() - 1) {
                Schema.SObjectField sobjectField = getFieldByApiName(fields, segment);
                if (sobjectField == null) {
                    throw new AuraHandledException('Field not found: ' + soqlPath);
                }
                Schema.DescribeFieldResult fieldDescribe = sobjectField.getDescribe();
                if (!fieldDescribe.isAccessible()) {
                    throw new AuraHandledException('You do not have field access to ' + soqlPath + '.');
                }
                return fieldDescribe;
            }

            Schema.DescribeFieldResult relationshipField = findRelationshipField(fields, segment);
            if (relationshipField == null || relationshipField.getReferenceTo().isEmpty()) {
                throw new AuraHandledException('Relationship not found: ' + segment + ' in ' + soqlPath);
            }
            currentType = relationshipField.getReferenceTo()[0];
        }
        throw new AuraHandledException('Invalid field path: ' + soqlPath);
    }

    private static Schema.DescribeFieldResult findRelationshipField(Map<String, Schema.SObjectField> fields, String relationshipName) {
        for (Schema.SObjectField sobjectField : fields.values()) {
            Schema.DescribeFieldResult fieldDescribe = sobjectField.getDescribe();
            if (equalsIgnoreCase(fieldDescribe.getRelationshipName(), relationshipName)
                && fieldDescribe.isAccessible()) {
                return fieldDescribe;
            }
        }
        String customLookupName = relationshipName.endsWith('__r') ? relationshipName.replace('__r', '__c') : null;
        Schema.SObjectField customLookup = customLookupName == null ? null : getFieldByApiName(fields, customLookupName);
        if (customLookup != null) {
            Schema.DescribeFieldResult fieldDescribe = customLookup.getDescribe();
            return fieldDescribe.isAccessible() ? fieldDescribe : null;
        }
        return null;
    }

    private static Schema.SObjectField getFieldByApiName(Map<String, Schema.SObjectField> fields, String apiName) {
        if (fields.containsKey(apiName)) {
            return fields.get(apiName);
        }
        for (String fieldName : fields.keySet()) {
            if (equalsIgnoreCase(fieldName, apiName)) {
                return fields.get(fieldName);
            }
        }
        return null;
    }

    private static Boolean equalsIgnoreCase(String left, String right) {
        return left != null && right != null && left.toLowerCase() == right.toLowerCase();
    }

    private static String buildTabularSoql(
        DatasetResolution dataset,
        List<QueryField> fields,
        List<String> whereParts,
        List<SortKey> sortKeys,
        Integer pageSize
    ) {
        Set<String> selected = new Set<String>();
        Map<String, Set<String>> childSelected = new Map<String, Set<String>>();
        selected.add('Id');
        // Sort keys must be readable off the row to mint the next cursor, even when the
        // report doesn't display them as columns. Extra SELECT entries don't affect the
        // returned rows — those are built from `fields`.
        for (SortKey key : sortKeys) {
            if (key.cursorSafe) {
                selected.add(key.path);
            }
        }
        for (QueryField field : fields) {
            if (field.childCollection == true) {
                if (!childSelected.containsKey(field.childRelationshipName)) {
                    childSelected.put(field.childRelationshipName, new Set<String>());
                }
                childSelected.get(field.childRelationshipName).add(field.childSoqlPath);
            } else {
                selected.add(field.soqlPath);
            }
        }

        List<String> selectParts = new List<String>(selected);
        for (String relationshipName : childSelected.keySet()) {
            List<String> childFields = new List<String>(childSelected.get(relationshipName));
            childFields.sort();
            selectParts.add('(SELECT ' + String.join(childFields, ', ') + ' FROM ' + relationshipName + ' LIMIT ' + CHILD_SUBQUERY_LIMIT + ')');
        }

        String soql = 'SELECT ' + String.join(selectParts, ', ');
        soql += ' FROM ' + dataset.sobjectApiName;
        if (!whereParts.isEmpty()) {
            soql += ' WHERE ' + String.join(whereParts, ' AND ');
        }
        soql += orderByClause(sortKeys);
        soql += ' LIMIT ' + pageSize;
        return soql;
    }

    /**
     * One grouping level. A DATE/DATETIME grouping with a granularity expands into
     * one or two SOQL expressions (Quarter -> CALENDAR_YEAR + CALENDAR_QUARTER) that
     * are recombined into a single readable bucket ("2026-Q2") at read time. Without
     * a granularity the field groups raw, exactly as before.
     */
    private class GroupSpec {
        String path;
        String granularity; // null | Day | Week | Month | Quarter | Year
        String label;
        String outKey;      // g0, g1 ... the key charts/pivot read
        List<String> exprs = new List<String>();
        List<String> aliases = new List<String>();
    }

    private static final Set<String> DATE_GRAINS = new Set<String>{ 'DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR' };

    private static String normalizeGranularity(String raw) {
        if (String.isBlank(raw)) return null;
        String g = raw.trim().toUpperCase();
        if (!DATE_GRAINS.contains(g)) return null; // 'None'/unknown => raw grouping
        return g.substring(0, 1) + g.substring(1).toLowerCase();
    }

    private static List<GroupSpec> buildGroupSpecs(DatasetResolution dataset, Object groupingsObj) {
        List<GroupSpec> specs = new List<GroupSpec>();
        Integer i = 0;
        for (Object o : asObjectList(groupingsObj)) {
            Map<String, Object> m = asMap(o);
            String rawField = asString(m.get('field'));
            if (String.isBlank(rawField)) continue;
            String path = normalizePath(dataset, rawField);
            rejectChildCollectionPath(dataset, path, 'groupings');
            Schema.DescribeFieldResult dfr = validateFieldPath(dataset.sobjectApiName, path);

            GroupSpec spec = new GroupSpec();
            spec.path = path;
            spec.outKey = 'g' + i;
            spec.label = dfr.getLabel();
            String grain = normalizeGranularity(asString(m.get('granularity')));
            Boolean isDatetime = dfr.getType() == Schema.DisplayType.Datetime;
            Boolean isDate = isDatetime || dfr.getType() == Schema.DisplayType.Date;

            if (!isDate || grain == null) {
                // Non-date field, or no granularity requested: unchanged behaviour.
                spec.exprs.add(path);
                spec.aliases.add(spec.outKey);
            } else if (grain == 'Day') {
                spec.granularity = grain;
                spec.exprs.add(isDatetime ? 'DAY_ONLY(' + path + ')' : path);
                spec.aliases.add(spec.outKey);
                spec.label += ' (Day)';
            } else if (grain == 'Year') {
                spec.granularity = grain;
                spec.exprs.add('CALENDAR_YEAR(' + path + ')');
                spec.aliases.add(spec.outKey);
                spec.label += ' (Year)';
            } else {
                // Quarter / Month / Week need year + part so buckets don't collide
                // across years (Q1-2025 vs Q1-2026).
                spec.granularity = grain;
                spec.exprs.add('CALENDAR_YEAR(' + path + ')');
                spec.aliases.add(spec.outKey + 'y');
                String partFn = grain == 'Quarter'
                    ? 'CALENDAR_QUARTER'
                    : (grain == 'Month' ? 'CALENDAR_MONTH' : 'WEEK_IN_YEAR');
                spec.exprs.add(partFn + '(' + path + ')');
                spec.aliases.add(spec.outKey + 'p');
                spec.label += ' (' + grain + ')';
            }
            specs.add(spec);
            i++;
        }
        return specs;
    }

    private static Object formatGroupValue(GroupSpec spec, AggregateResult ar) {
        if (spec.granularity == null || spec.granularity == 'Day') {
            return ar.get(spec.aliases[0]);
        }
        if (spec.granularity == 'Year') {
            Object y = ar.get(spec.aliases[0]);
            return y == null ? null : String.valueOf(y);
        }
        Object yearVal = ar.get(spec.aliases[0]);
        Object partVal = ar.get(spec.aliases[1]);
        if (yearVal == null || partVal == null) return null;
        String year = String.valueOf(yearVal);
        String part = String.valueOf(partVal);
        if (spec.granularity == 'Quarter') return year + '-Q' + part;
        if (spec.granularity == 'Month') return year + '-' + part.leftPad(2, '0');
        return year + '-W' + part.leftPad(2, '0');
    }

    private static String buildAggregateSoql(
        DatasetResolution dataset,
        List<QueryField> fields,
        List<GroupSpec> groupSpecs,
        List<Object> aggregations,
        List<String> whereParts,
        Map<String, Object> definition
    ) {
        List<String> selectParts = new List<String>();
        List<String> groupExprs = new List<String>();
        Boolean hasDateBucket = false;
        for (GroupSpec spec : groupSpecs) {
            for (Integer k = 0; k < spec.exprs.size(); k++) {
                selectParts.add(spec.exprs[k] + ' ' + spec.aliases[k]);
                groupExprs.add(spec.exprs[k]);
            }
            if (spec.granularity != null) hasDateBucket = true;
        }

        Integer aggregateIndex = 0;
        for (Object aggregateObject : aggregations) {
            Map<String, Object> aggregateMap = asMap(aggregateObject);
            String functionName = asString(aggregateMap.get('function')).toUpperCase();
            String fieldPath = normalizePath(dataset, asString(aggregateMap.get('field')));
            if (String.isBlank(fieldPath) && functionName == 'COUNT') {
                fieldPath = 'Id';
            }
            rejectChildCollectionPath(dataset, fieldPath, 'aggregations');
            validateFieldPath(dataset.sobjectApiName, fieldPath);
            selectParts.add(functionName + '(' + fieldPath + ') a' + aggregateIndex);
            aggregateIndex++;
        }
        if (aggregations.isEmpty()) {
            selectParts.add('COUNT(Id) a0');
        }

        String soql = 'SELECT ' + String.join(selectParts, ', ') + ' FROM ' + dataset.sobjectApiName;
        if (!whereParts.isEmpty()) {
            soql += ' WHERE ' + String.join(whereParts, ' AND ');
        }
        if (!groupExprs.isEmpty()) {
            soql += ' GROUP BY ' + String.join(groupExprs, ', ');
            // Time buckets are meaningless out of order — sort chronologically so a
            // "by Quarter" chart reads left-to-right. (Non-date groupings keep their
            // existing, unordered behaviour.)
            if (hasDateBucket) {
                soql += ' ORDER BY ' + String.join(groupExprs, ' ASC, ') + ' ASC';
            }
        }
        return soql;
    }

    private static CR_Types.QueryResult executeTabular(String soql, List<QueryField> fields, List<SortKey> sortKeys, Integer pageSize) {
        List<SObject> records = Database.query(soql);
        // Strip inaccessible fields per running user's FLS so deep relationship hops
        // don't leak values past the up-front validateFieldPath describe checks.
        if (!records.isEmpty()) {
            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.READABLE, records);
            records = decision.getRecords();
        }
        CR_Types.QueryResult result = initResult(fields);
        List<QueryField> rootFields = new List<QueryField>();
        Map<String, List<QueryField>> childFieldsByRelationship = new Map<String, List<QueryField>>();
        for (QueryField field : fields) {
            if (field.childCollection == true) {
                if (!childFieldsByRelationship.containsKey(field.childRelationshipName)) {
                    childFieldsByRelationship.put(field.childRelationshipName, new List<QueryField>());
                }
                childFieldsByRelationship.get(field.childRelationshipName).add(field);
            } else {
                rootFields.add(field);
            }
        }

        for (SObject record : records) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('Id', record.get('Id'));
            for (QueryField field : rootFields) {
                row.put(field.requestedPath, getPathValue(record, field.soqlPath));
            }
            if (childFieldsByRelationship.isEmpty()) {
                result.rows.add(row);
            } else {
                result.rows.addAll(expandChildRows(record, row, childFieldsByRelationship));
            }
        }
        result.rowCount = result.rows.size();
        if (records.size() == pageSize && !records.isEmpty()) {
            // The cursor carries the full sort tuple of the last row, plus the key paths it
            // was minted from so the next call can prove the sort hasn't changed underneath it.
            SObject lastRecord = records[records.size() - 1];
            List<String> cursorPaths = new List<String>();
            List<String> cursorDirs = new List<String>();
            List<Object> cursorValues = new List<Object>();
            for (SortKey key : sortKeys) {
                if (!key.cursorSafe) {
                    continue;
                }
                cursorPaths.add(key.path);
                cursorDirs.add(key.descending ? 'D' : 'A');
                cursorValues.add(getPathValue(lastRecord, key.path));
            }
            result.nextPageToken = EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(
                new Map<String, Object>{ 'k' => cursorPaths, 'd' => cursorDirs, 'v' => cursorValues }
            )));
        }
        return result;
    }

    private static List<Map<String, Object>> expandChildRows(
        SObject parentRecord,
        Map<String, Object> baseRow,
        Map<String, List<QueryField>> childFieldsByRelationship
    ) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>{ baseRow };
        for (String relationshipName : childFieldsByRelationship.keySet()) {
            List<QueryField> relationshipFields = childFieldsByRelationship.get(relationshipName);
            List<SObject> children = parentRecord.getSObjects(relationshipName);
            if (children == null || children.isEmpty()) {
                for (Map<String, Object> row : rows) {
                    for (QueryField field : relationshipFields) {
                        row.put(field.requestedPath, null);
                    }
                }
                continue;
            }

            List<Map<String, Object>> nextRows = new List<Map<String, Object>>();
            for (Map<String, Object> row : rows) {
                for (SObject child : children) {
                    Map<String, Object> childRow = row.clone();
                    for (QueryField field : relationshipFields) {
                        childRow.put(field.requestedPath, getPathValue(child, field.childSoqlPath));
                    }
                    nextRows.add(childRow);
                }
            }
            rows = nextRows;
        }
        return rows;
    }

    private static CR_Types.QueryResult executeAggregate(
        String soql,
        List<QueryField> fields,
        List<GroupSpec> groupSpecs,
        List<Object> aggregations,
        DatasetResolution dataset
    ) {
        List<AggregateResult> records = Database.query(soql);
        CR_Types.QueryResult result = initResult(new List<QueryField>());

        List<String> groupPaths = new List<String>();
        for (GroupSpec spec : groupSpecs) {
            groupPaths.add(spec.path);
            CR_Types.ColumnInfo groupColumn = new CR_Types.ColumnInfo();
            groupColumn.key = spec.outKey;
            groupColumn.label = spec.label;
            groupColumn.dataType = 'GROUP';
            groupColumn.numeric = false;
            result.columns.add(groupColumn);
        }
        result.groupLevels = groupPaths;

        Integer aggregateColumnCount = aggregations.isEmpty() ? 1 : aggregations.size();
        for (Integer i = 0; i < aggregateColumnCount; i++) {
            CR_Types.ColumnInfo aggregateColumn = new CR_Types.ColumnInfo();
            aggregateColumn.key = 'a' + i;
            aggregateColumn.label = aggregations.isEmpty()
                ? 'Count'
                : aggregateLabel(dataset, asMap(aggregations[i]));
            aggregateColumn.dataType = 'AGGREGATE';
            aggregateColumn.numeric = true;
            result.columns.add(aggregateColumn);
        }

        for (AggregateResult aggregate : records) {
            Map<String, Object> row = new Map<String, Object>();
            for (GroupSpec spec : groupSpecs) {
                row.put(spec.outKey, formatGroupValue(spec, aggregate));
            }
            for (Integer i = 0; i < aggregateColumnCount; i++) {
                row.put('a' + i, aggregate.get('a' + i));
            }
            result.rows.add(row);
        }
        result.rowCount = result.rows.size();
        return result;
    }

    // A human column header instead of the raw SOQL alias ("COUNT(Id)").
    private static String aggregateLabel(DatasetResolution dataset, Map<String, Object> aggregateMap) {
        String fn = asString(aggregateMap.get('function')).toUpperCase();
        String rawField = asString(aggregateMap.get('field'));
        String pretty = fn.substring(0, 1) + fn.substring(1).toLowerCase();
        if (String.isBlank(rawField) || rawField.equalsIgnoreCase('Id')) {
            return fn == 'COUNT' ? 'Count' : pretty;
        }
        String fieldLabel = rawField;
        try {
            fieldLabel = validateFieldPath(dataset.sobjectApiName, normalizePath(dataset, rawField)).getLabel();
        } catch (Exception e) {
            // fall back to the raw path
        }
        return pretty + ' of ' + fieldLabel;
    }

    private static CR_Types.QueryResult initResult(List<QueryField> fields) {
        CR_Types.QueryResult result = new CR_Types.QueryResult();
        result.columns = new List<CR_Types.ColumnInfo>();
        result.rows = new List<Map<String, Object>>();
        result.totals = new Map<String, Object>();
        result.groupLevels = new List<String>();
        result.warnings = new List<String>();
        for (QueryField field : fields) {
            CR_Types.ColumnInfo column = new CR_Types.ColumnInfo();
            column.key = field.requestedPath;
            column.label = field.label;
            column.dataType = field.dataType;
            column.numeric = field.numeric;
            result.columns.add(column);
        }
        return result;
    }

    private static Object getPathValue(SObject record, String soqlPath) {
        List<String> segments = soqlPath.split('\\.');
        SObject current = record;
        for (Integer i = 0; i < segments.size(); i++) {
            if (current == null) {
                return null;
            }
            if (i == segments.size() - 1) {
                return current.get(segments[i]);
            }
            current = current.getSObject(segments[i]);
        }
        return null;
    }

    private static String buildWhereClause(DatasetResolution dataset, Object filtersObject) {
        if (filtersObject == null) {
            return '';
        }
        if (filtersObject instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object filter : (List<Object>) filtersObject) {
                String fragment = buildFilterFragment(dataset, filter);
                if (!String.isBlank(fragment)) {
                    parts.add(fragment);
                }
            }
            return String.join(parts, ' AND ');
        }
        return buildFilterFragment(dataset, filtersObject);
    }

    private static String buildFilterFragment(DatasetResolution dataset, Object filterObject) {
        Map<String, Object> filterMap = asMap(filterObject);
        if (filterMap.containsKey('conditions')) {
            String logic = asString(filterMap.get('logic')).toUpperCase();
            if (logic != 'OR') {
                logic = 'AND';
            }
            List<String> parts = new List<String>();
            for (Object child : asObjectList(filterMap.get('conditions'))) {
                String childFragment = buildFilterFragment(dataset, child);
                if (!String.isBlank(childFragment)) {
                    parts.add(childFragment);
                }
            }
            return parts.isEmpty() ? '' : '(' + String.join(parts, ' ' + logic + ' ') + ')';
        }

        String fieldPath = normalizePath(dataset, firstNonBlank(new List<String>{
            asString(filterMap.get('field')),
            asString(filterMap.get('path'))
        }));
        String operatorRaw = asString(filterMap.get('operator'));
        if (String.isBlank(operatorRaw)) {
            throw new AuraHandledException('A filter is missing its operator.');
        }
        String operator = operatorRaw.toUpperCase();
        if (!ALLOWED_OPERATORS.contains(operator)) {
            throw new AuraHandledException('Unsupported filter operator: ' + operator);
        }
        rejectChildCollectionPath(dataset, fieldPath, 'filters');
        Schema.DescribeFieldResult fieldDescribe = validateFieldPath(dataset.sobjectApiName, fieldPath);
        if (!fieldDescribe.isFilterable()) {
            throw new AuraHandledException('Field is not filterable: ' + fieldPath);
        }
        if (operator == 'IS NULL') {
            // SOQL accepts "= null" but not the literal "IS NULL" syntax — translate.
            return fieldPath + ' = null';
        }
        if (operator == 'IS NOT NULL') {
            return fieldPath + ' != null';
        }
        Object coercedValue = coerceFilterValue(filterMap.get('value'), fieldDescribe.getType(), operator);
        return fieldPath + ' ' + operator + ' ' + formatLiteral(coercedValue);
    }

    // Convert raw JSON-deserialized filter values into the typed Apex value the SOQL
    // formatter expects, based on the target field's DisplayType. The LWC sends Date and
    // DateTime values as ISO strings (because JSON has no native temporal types), so
    // formatLiteral would otherwise wrap them in quotes and Salesforce would reject the
    // SOQL with "must be of type dateTime and should not be enclosed in quotes".
    @TestVisible
    private static Object coerceFilterValue(Object value, Schema.DisplayType fieldType, String operator) {
        if (value == null) return null;
        if (value instanceof List<Object>) {
            List<Object> coerced = new List<Object>();
            for (Object item : (List<Object>) value) {
                coerced.add(coerceFilterValue(item, fieldType, operator));
            }
            return coerced;
        }
        if (!(value instanceof String)) return value;
        String s = (String) value;
        // SOQL relative-date literals (TODAY, LAST_N_DAYS:7, ...) stay as-is; formatLiteral
        // detects them via isSoqlDateLiteral and emits them unquoted.
        if (isSoqlDateLiteral(s)) return s;
        if (fieldType == Schema.DisplayType.Date) {
            try { return Date.valueOf(s); } catch (Exception ex) { return s; }
        }
        if (fieldType == Schema.DisplayType.DateTime) {
            try {
                // lightning-input type="datetime" emits ISO 8601 like
                // "2026-05-05T15:35:00.000Z". JSON.deserialize maps that to Datetime.
                return (Datetime) JSON.deserialize('"' + s + '"', Datetime.class);
            } catch (Exception ex) {
                return s;
            }
        }
        if (fieldType == Schema.DisplayType.Boolean) {
            if (s == 'true') return true;
            if (s == 'false') return false;
        }
        return s;
    }

    private static void validateFilters(DatasetResolution dataset, Object filtersObject, CR_Types.ValidationResult result) {
        try {
            buildWhereClause(dataset, filtersObject);
        } catch (Exception ex) {
            result.addError(ex.getMessage());
        }
    }

    /**
     * One ORDER BY term.
     *
     * Keyset pagination compares the cursor in a WHERE clause, so the cursor MUST be
     * built from the exact same key list, in the same order, that ORDER BY emits. When
     * the two disagree the page order and the page cursor describe different sequences
     * and rows are silently skipped — see buildCursorWhere.
     */
    private class SortKey {
        String path;
        Boolean descending = false;
        Schema.DisplayType fieldType;
        // Only cursorSafe keys may appear in a cursor predicate or be read back off a row.
        Boolean cursorSafe = false;
    }

    /**
     * The ordered sort keys for a tabular query. Id ASC is always appended: it is unique,
     * so the key tuple is a total order and the cursor can never stall on ties.
     */
    private static List<SortKey> buildSortKeys(
        DatasetResolution dataset,
        Map<String, Object> definition,
        List<String> warningsOut
    ) {
        List<SortKey> keys = new List<SortKey>();
        for (Object sortObject : asObjectList(definition.get('sort'))) {
            Map<String, Object> sortMap = asMap(sortObject);
            String rawPath = asString(sortMap.get('field'));
            String path = normalizePath(dataset, rawPath);
            rejectChildCollectionPath(dataset, path, 'sorting');
            Schema.DescribeFieldResult fieldDescribe = validateFieldPath(dataset.sobjectApiName, path);
            if (!fieldDescribe.isSortable()) {
                continue;
            }
            // A sortable-but-not-filterable field cannot appear in a cursor predicate, so
            // paging it would truncate the result set. Dropping the sort keeps the data
            // COMPLETE (order falls back to Id) and says so, rather than quietly losing rows.
            if (!fieldDescribe.isFilterable()) {
                if (warningsOut != null) {
                    warningsOut.add(
                        'Sort on "' + rawPath + '" was ignored because the field cannot be filtered — '
                        + 'keeping it would have dropped rows from paginated results and exports.'
                    );
                }
                continue;
            }
            SortKey key = new SortKey();
            key.path = path;
            key.descending = descending(sortMap);
            key.fieldType = fieldDescribe.getType();
            key.cursorSafe = true;
            keys.add(key);
        }
        SortKey idKey = new SortKey();
        idKey.path = 'Id';
        idKey.fieldType = Schema.DisplayType.ID;
        idKey.cursorSafe = true;
        keys.add(idKey);
        return keys;
    }

    private static Boolean descending(Map<String, Object> sortMap) {
        return normalizeDirection(asString(sortMap.get('direction'))) == 'DESC';
    }

    /**
     * Re-derive the sort keys from a page token when it describes a different ordering than
     * the definition currently would.
     *
     * Continuing a cursor means continuing THE SEQUENCE THAT CURSOR CAME FROM. A caller that
     * paginates without resending the sort it originally applied (the report viewer's Next
     * button does exactly this, because a fresh tabular load auto-applies a default date sort)
     * would otherwise ask for page 2 of a different ordering than page 1 — which is the
     * mismatch that drops rows. Rebuilding from the token keeps ORDER BY and the cursor
     * describing one sequence, so paging stays complete regardless of what the client resends.
     *
     * Changing sort is still a NEW sequence: callers must start it with a null token.
     */
    private static List<SortKey> alignSortKeysToToken(
        DatasetResolution dataset,
        String pageToken,
        List<SortKey> definitionSortKeys
    ) {
        if (String.isBlank(pageToken)) {
            return definitionSortKeys;
        }
        Map<String, Object> token;
        try {
            token = (Map<String, Object>) JSON.deserializeUntyped(
                EncodingUtil.base64Decode(pageToken).toString()
            );
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid pagination token.');
        }
        List<Object> cursorPaths = asObjectList(token.get('k'));
        List<Object> cursorDirs = asObjectList(token.get('d'));
        // Legacy lastId-only tokens carry no ordering; they belong to an Id-ordered query.
        if (cursorPaths.isEmpty() || cursorDirs.size() != cursorPaths.size()) {
            return definitionSortKeys;
        }
        if (sortKeysMatch(definitionSortKeys, cursorPaths, cursorDirs)) {
            return definitionSortKeys;
        }

        List<SortKey> tokenKeys = new List<SortKey>();
        for (Integer i = 0; i < cursorPaths.size(); i++) {
            String path = asString(cursorPaths[i]);
            if (String.isBlank(path)) {
                throw new AuraHandledException('Invalid pagination token.');
            }
            if (path == 'Id') {
                SortKey idKey = new SortKey();
                idKey.path = 'Id';
                idKey.descending = asString(cursorDirs[i]) == 'D';
                idKey.fieldType = Schema.DisplayType.ID;
                idKey.cursorSafe = true;
                tokenKeys.add(idKey);
                continue;
            }
            // Same gates as buildSortKeys — a token must never widen what can be sorted or
            // spliced into a WHERE clause.
            rejectChildCollectionPath(dataset, path, 'sorting');
            Schema.DescribeFieldResult fieldDescribe = validateFieldPath(dataset.sobjectApiName, path);
            if (!fieldDescribe.isSortable() || !fieldDescribe.isFilterable()) {
                throw new AuraHandledException('Invalid pagination token.');
            }
            SortKey key = new SortKey();
            key.path = path;
            key.descending = asString(cursorDirs[i]) == 'D';
            key.fieldType = fieldDescribe.getType();
            key.cursorSafe = true;
            tokenKeys.add(key);
        }
        // Id must be the final tiebreaker or the tuple isn't a total order.
        if (tokenKeys.isEmpty() || tokenKeys[tokenKeys.size() - 1].path != 'Id') {
            throw new AuraHandledException('Invalid pagination token.');
        }
        return tokenKeys;
    }

    private static Boolean sortKeysMatch(List<SortKey> keys, List<Object> paths, List<Object> dirs) {
        if (keys == null || keys.size() != paths.size()) {
            return false;
        }
        for (Integer i = 0; i < keys.size(); i++) {
            if (asString(paths[i]) != keys[i].path
                || asString(dirs[i]) != (keys[i].descending ? 'D' : 'A')) {
                return false;
            }
        }
        return true;
    }

    /**
     * NULLS FIRST/LAST is stated explicitly rather than left to the platform default,
     * because buildCursorWhere's predicates encode exactly this null placement. Leaving
     * it implicit would make correctness depend on an unstated platform behaviour.
     */
    private static String orderByClause(List<SortKey> keys) {
        if (keys == null || keys.isEmpty()) {
            return '';
        }
        List<String> orderParts = new List<String>();
        for (SortKey key : keys) {
            orderParts.add(key.path + (key.descending ? ' DESC NULLS LAST' : ' ASC NULLS FIRST'));
        }
        return ' ORDER BY ' + String.join(orderParts, ', ');
    }

    // Replace the definition's sort with the user's chosen column so buildSortKeys emits it as the
    // primary ORDER BY (Id ASC remains the tabular tiebreaker). Non-throwing: a malformed
    // definition is returned unchanged so runReport surfaces the real error.
    @TestVisible
    private static String injectSortOverride(String definitionJson, String sortField, String sortDir) {
        try {
            Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(definitionJson);
            String dir = 'desc'.equalsIgnoreCase(sortDir) ? 'desc' : 'asc';
            def.put('sort', new List<Object>{
                new Map<String, Object>{ 'field' => sortField, 'direction' => dir }
            });
            return JSON.serialize(def);
        } catch (Exception e) {
            return definitionJson;
        }
    }

    private static Object parseDashboardFiltersSafe(String filtersJson) {
        try {
            return JSON.deserializeUntyped(filtersJson);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid dashboard filters JSON.');
        }
    }

    /**
     * Cursor ("seek") predicate for the next page: every row strictly after the previous
     * page's last row, in the query's own sort order.
     *
     * For keys k1..kn (kn is always Id, unique) with the previous row's values v1..vn:
     *
     *     (k1 after v1)
     *  OR (k1 = v1 AND k2 after v2)
     *  OR (k1 = v1 AND k2 = v2 AND ... AND Id > vn)
     *
     * "after" depends on direction and on null placement, which orderByClause pins down
     * explicitly. SOQL comparisons never match null, so:
     *   ASC  (NULLS FIRST): v null -> k != null           | v set -> k > v
     *   DESC (NULLS LAST):  v null -> nothing follows it  | v set -> k < v OR k = null
     *
     * Until this existed the predicate was a bare "Id > lastId", which is only correct
     * when the query is ordered by Id. Any other sort dropped every row whose Id happened
     * to fall below the previous page's last Id — a 57k-row export silently ended at 19,771.
     */
    private static String buildTokenWhere(String pageToken, List<SortKey> sortKeys) {
        if (String.isBlank(pageToken)) {
            return '';
        }
        Map<String, Object> token;
        try {
            token = (Map<String, Object>) JSON.deserializeUntyped(
                EncodingUtil.base64Decode(pageToken).toString()
            );
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid pagination token.');
        }

        List<Object> cursorPaths = asObjectList(token.get('k'));
        if (cursorPaths.isEmpty()) {
            // Legacy token: lastId only. Emitted before composite cursors existed, and
            // correct for the Id-ordered queries that produced it. Honour in-flight paging.
            String lastId = asString(token.get('lastId'));
            if (String.isBlank(lastId)) {
                return '';
            }
            try {
                // Defense-in-depth: Id.valueOf rejects anything that isn't a real 15/18-char Id.
                return 'Id > ' + formatCursorLiteral(String.valueOf(Id.valueOf(lastId)));
            } catch (Exception ex) {
                throw new AuraHandledException('Invalid pagination token.');
            }
        }

        List<Object> cursorValues = asObjectList(token.get('v'));
        List<Object> cursorDirs = asObjectList(token.get('d'));
        // A token minted against a different sort than the one now being run describes a
        // different sequence; honouring it would skip or repeat rows. Direction matters as
        // much as the field — the same keys ascending vs descending are different sequences.
        if (sortKeys == null
            || cursorPaths.size() != sortKeys.size()
            || cursorValues.size() != sortKeys.size()
            || cursorDirs.size() != sortKeys.size()) {
            throw new AuraHandledException('Invalid pagination token.');
        }
        for (Integer i = 0; i < sortKeys.size(); i++) {
            if (!sortKeys[i].cursorSafe
                || asString(cursorPaths[i]) != sortKeys[i].path
                || asString(cursorDirs[i]) != (sortKeys[i].descending ? 'D' : 'A')) {
                throw new AuraHandledException('Invalid pagination token.');
            }
        }

        try {
            List<Object> typedValues = new List<Object>();
            for (Integer i = 0; i < sortKeys.size(); i++) {
                // JSON round-tripping flattens dates to strings; coerce back so the SOQL
                // literal is emitted unquoted for Date/Datetime columns.
                typedValues.add(coerceFilterValue(cursorValues[i], sortKeys[i].fieldType, '='));
            }
            if (typedValues[sortKeys.size() - 1] != null) {
                Id.valueOf(String.valueOf(typedValues[sortKeys.size() - 1]));
            }

            List<String> orGroups = new List<String>();
            for (Integer i = 0; i < sortKeys.size(); i++) {
                String after = strictlyAfterPredicate(sortKeys[i], typedValues[i]);
                if (after == null) {
                    continue;
                }
                List<String> conjuncts = new List<String>();
                for (Integer j = 0; j < i; j++) {
                    conjuncts.add(sortKeyEqualsPredicate(sortKeys[j], typedValues[j]));
                }
                conjuncts.add(after);
                orGroups.add('(' + String.join(conjuncts, ' AND ') + ')');
            }
            return orGroups.isEmpty() ? '' : '(' + String.join(orGroups, ' OR ') + ')';
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid pagination token.');
        }
    }

    // Rows strictly after `value` on this key alone. Null means "nothing can follow it",
    // so that OR-branch is dropped (deeper tiebreaks still apply via later branches).
    private static String strictlyAfterPredicate(SortKey key, Object value) {
        if (!key.descending) {
            return value == null
                ? '(' + key.path + ' != null)'
                : '(' + key.path + ' > ' + formatCursorLiteral(value) + ')';
        }
        if (value == null) {
            return null;
        }
        return '(' + key.path + ' < ' + formatCursorLiteral(value) + ' OR ' + key.path + ' = null)';
    }

    private static String sortKeyEqualsPredicate(SortKey key, Object value) {
        return value == null
            ? '(' + key.path + ' = null)'
            : '(' + key.path + ' = ' + formatCursorLiteral(value) + ')';
    }

    /**
     * Literal for a cursor value. Deliberately NOT formatLiteral: that one also resolves
     * $CURRENT_USER tokens and emits recognised SOQL date literals unquoted, which are
     * expression features. A cursor value is data read back off a record — a text column
     * holding "TODAY" must round-trip as the string 'TODAY', not as a date literal.
     */
    private static String formatCursorLiteral(Object value) {
        if (value == null) {
            return 'null';
        }
        if (value instanceof Boolean || value instanceof Decimal || value instanceof Integer
            || value instanceof Long || value instanceof Double) {
            return String.valueOf(value);
        }
        if (value instanceof Date) {
            Date dateValue = (Date) value;
            return Datetime.newInstanceGmt(dateValue.year(), dateValue.month(), dateValue.day(), 0, 0, 0)
                .formatGmt('yyyy-MM-dd');
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        }
        if (value instanceof Time) {
            return String.valueOf(value);
        }
        return '\'' + String.escapeSingleQuotes(String.valueOf(value)) + '\'';
    }

    private static String normalizePath(DatasetResolution dataset, String path) {
        if (String.isBlank(path)) {
            return '';
        }
        String mapped = mapKnownFactPath(dataset, path);
        if (!String.isBlank(mapped)) {
            return mapped;
        }
        String trimmed = path.trim();
        if (!String.isBlank(dataset.sobjectApiName) && startsWithObjectPrefix(trimmed, dataset.sobjectApiName)) {
            return trimmed.substring(dataset.sobjectApiName.length() + 1);
        }
        if (!String.isBlank(dataset.primaryObject) && startsWithObjectPrefix(trimmed, dataset.primaryObject)) {
            return trimmed.substring(dataset.primaryObject.length() + 1);
        }
        return trimmed;
    }

    private static Boolean startsWithObjectPrefix(String path, String objectApiName) {
        return path != null
            && objectApiName != null
            && path.length() > objectApiName.length()
            && path.substring(0, objectApiName.length()).toLowerCase() == objectApiName.toLowerCase()
            && path.substring(objectApiName.length(), objectApiName.length() + 1) == '.';
    }

    private static List<String> normalizePathList(DatasetResolution dataset, List<String> paths) {
        List<String> normalized = new List<String>();
        for (String path : paths) {
            if (!String.isBlank(path)) {
                normalized.add(normalizePath(dataset, path));
            }
        }
        return normalized;
    }

    private static String mapKnownFactPath(DatasetResolution dataset, String path) {
        if (dataset == null || String.isBlank(path)) {
            return null;
        }
        Map<String, String> mapByPath = new Map<String, String>{
            'Opportunity.Name' => 'Opportunity_Name__c',
            'Opportunity.Amount' => 'Amount__c',
            'Opportunity.StageName' => 'Stage_Name__c',
            'Opportunity.CloseDate' => 'Close_Date__c',
            'Opportunity.Account.Name' => 'Dim_Account__r.Account_Name__c',
            'Opportunity.Account.Industry' => 'Dim_Account__r.Industry__c',
            'Opportunity.Owner.Name' => 'Dim_Owner__r.User_Name__c',
            'Opportunity.Owner.Email' => 'Dim_Owner__r.Email__c',
            'Case.CaseNumber' => 'Case_Number__c',
            'Case.Status' => 'Status__c',
            'Case.Priority' => 'Priority__c',
            'Case.CreatedDate' => 'Created_Date__c',
            'Case.Account.Name' => 'Dim_Account__r.Account_Name__c',
            'Case.Owner.Name' => 'Dim_Owner__r.User_Name__c',
            'Case.Owner.Email' => 'Dim_Owner__r.Email__c'
        };
        Boolean factDataset = dataset.sobjectApiName == 'Fact_Opportunity__c' || dataset.sobjectApiName == 'Fact_Case__c';
        return factDataset && mapByPath.containsKey(path.trim()) ? mapByPath.get(path.trim()) : null;
    }

    private static String normalizeDirection(String direction) {
        return String.isBlank(direction) || direction.toUpperCase() != 'DESC' ? 'ASC' : 'DESC';
    }

    /**
     * Distinct values for one column, across EVERY record the report matches — not
     * just the page the viewer happens to have loaded. The column-filter picker used
     * to derive its options from the loaded rows, so with 33k rows paged 100 at a time
     * a user could only filter by the handful of values on page 1 (a rep literally
     * could not find their own name). Scoped by the report's own filters so the list
     * reflects the report, and capped so a high-cardinality column can't melt the UI.
     *
     * Returns an empty list for non-groupable fields (e.g. long text); the client
     * falls back to deriving options from the loaded rows.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getDistinctValues(Id reportId, String fieldPath, Integer maxValues) {
        List<String> out = new List<String>();
        if (reportId == null || String.isBlank(fieldPath)) {
            return out;
        }
        Integer cap = (maxValues == null || maxValues <= 0) ? 500 : Math.min(maxValues, 1000);

        List<Report_Definition__c> rows = [
            SELECT Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportId LIMIT 1
        ];
        if (rows.isEmpty()) {
            return out;
        }
        Map<String, Object> definition = parseDefinition(rows[0].Definition_JSON__c);
        DatasetResolution dataset = resolveDataset(definition);

        String path = normalizePath(dataset, fieldPath);
        rejectChildCollectionPath(dataset, path, 'filters');
        Schema.DescribeFieldResult describe = validateFieldPath(dataset.sobjectApiName, path);
        if (!describe.isGroupable()) {
            return out;
        }

        List<String> whereParts = new List<String>();
        String reportWhere = buildWhereClause(dataset, definition.get('filters'));
        if (String.isNotBlank(reportWhere)) {
            whereParts.add(reportWhere);
        }
        whereParts.add(path + ' != null');

        String soql = 'SELECT ' + path + ' v FROM ' + dataset.sobjectApiName
            + ' WHERE ' + String.join(whereParts, ' AND ')
            + ' GROUP BY ' + path
            + ' ORDER BY ' + path + ' ASC'
            + ' LIMIT ' + cap;

        for (AggregateResult ar : Database.query(soql)) {
            Object v = ar.get('v');
            if (v != null) {
                out.add(String.valueOf(v));
            }
        }
        return out;
    }

    private static String formatLiteral(Object value) {
        if (value == null) {
            return 'null';
        }
        // Dynamic "me" tokens, resolved for the running user at query time. The fact
        // tables store the rep as a NAME string (Assigned_To__c), not a User lookup —
        // comparing that column to a user Id silently matches nothing, which is why a
        // report has to be able to ask for the right one:
        //   $CURRENT_USER     -> the running user's Name  (name/text columns)
        //   $CURRENT_USER_ID  -> the running user's Id    (User lookups / Id columns)
        if (value instanceof String) {
            String token = (String) value;
            if (token.equalsIgnoreCase('$CURRENT_USER')) {
                value = UserInfo.getName();
            } else if (token.equalsIgnoreCase('$CURRENT_USER_ID')) {
                value = String.valueOf(UserInfo.getUserId());
            }
        }
        if (value instanceof List<Object>) {
            List<String> values = new List<String>();
            for (Object item : (List<Object>) value) {
                values.add(formatLiteral(item));
            }
            return '(' + String.join(values, ', ') + ')';
        }
        if (value instanceof Boolean || value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double) {
            return String.valueOf(value);
        }
        if (value instanceof Date) {
            // String.valueOf(Date) returns "yyyy-MM-dd HH:mm:ss" with a trailing time component
            // — invalid as a SOQL Date literal. Format yyyy-MM-dd explicitly.
            Date d = (Date) value;
            return Datetime.newInstanceGmt(d.year(), d.month(), d.day(), 0, 0, 0).formatGmt('yyyy-MM-dd');
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        }
        String stringValue = String.valueOf(value);
        if (isSoqlDateLiteral(stringValue)) {
            return stringValue;
        }
        return '\'' + String.escapeSingleQuotes(stringValue) + '\'';
    }

    @TestVisible
    private static Boolean isSoqlDateLiteral(String value) {
        if (String.isBlank(value)) return false;
        // Whitelist of SOQL date literals. Whitelisting (vs the prior all-caps regex) is
        // required because user-typed text like "OHIC" otherwise matched and got injected
        // unquoted into SOQL, producing "Subject__c = OHIC" parse errors.
        Set<String> simple = new Set<String>{
            'TODAY','YESTERDAY','TOMORROW',
            'THIS_WEEK','LAST_WEEK','NEXT_WEEK',
            'THIS_MONTH','LAST_MONTH','NEXT_MONTH',
            'THIS_QUARTER','LAST_QUARTER','NEXT_QUARTER',
            'THIS_YEAR','LAST_YEAR','NEXT_YEAR',
            'THIS_FISCAL_QUARTER','LAST_FISCAL_QUARTER','NEXT_FISCAL_QUARTER',
            'THIS_FISCAL_YEAR','LAST_FISCAL_YEAR','NEXT_FISCAL_YEAR'
        };
        if (simple.contains(value)) return true;
        // Parameterized literals: LAST_N_DAYS:7, NEXT_N_QUARTERS:2, N_DAYS_AGO:14, etc.
        String unitGroup = '(DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS)';
        return Pattern.matches('^((LAST_N|NEXT_N)_' + unitGroup + '|N_' + unitGroup + '_AGO):\\d+$', value);
    }

    private static String joinSegments(List<String> segments, Integer startIndex) {
        List<String> tail = new List<String>();
        for (Integer i = startIndex; i < segments.size(); i++) {
            tail.add(segments[i]);
        }
        return String.join(tail, '.');
    }

    private static List<String> extractPathList(Object rawList, String mapKey) {
        List<String> paths = new List<String>();
        for (Object raw : asObjectList(rawList)) {
            if (raw instanceof String) {
                paths.add((String) raw);
            } else {
                paths.add(asString(asMap(raw).get(mapKey)));
            }
        }
        return paths;
    }

    private static Boolean isNumeric(Schema.DisplayType displayType) {
        return displayType == Schema.DisplayType.Currency
            || displayType == Schema.DisplayType.Double
            || displayType == Schema.DisplayType.Integer
            || displayType == Schema.DisplayType.Long
            || displayType == Schema.DisplayType.Percent;
    }

    private static List<Object> asObjectList(Object value) {
        if (value == null) {
            return new List<Object>();
        }
        if (value instanceof List<Object>) {
            return (List<Object>) value;
        }
        return new List<Object>{ value };
    }

    private static Map<String, Object> asMap(Object value) {
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        return new Map<String, Object>();
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String firstNonBlank(List<String> values) {
        for (String value : values) {
            if (!String.isBlank(value)) {
                return value;
            }
        }
        return null;
    }
}