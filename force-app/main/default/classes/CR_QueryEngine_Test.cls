@IsTest
private class CR_QueryEngine_Test {
    @IsTest
    static void validatesAndRunsTabularReport() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(false);

        // FLS-enforced validation + run must execute as a CRF-provisioned user.
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(report.Definition_JSON__c);
            System.assertEquals(true, validation.valid, JSON.serialize(validation.errors));

            CR_Types.QueryResult result = CR_QueryEngine.runReport(report.Definition_JSON__c, null, 100, null);
            System.assertEquals(2, result.rowCount);
            System.assertEquals(3, result.columns.size());
            System.assertEquals(false, result.aggregateResult);
        }
    }

    @IsTest
    static void serverSideSortOrdersTabularAcrossAllRows() {
        // Regression for the "date range shows only the first day or two" report: the viewer used
        // to sort only the loaded page. runReportByIdSorted pushes the ORDER BY to the server so it
        // spans the whole result set. Two rows with amounts 100 and 250 prove the order.
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult descRes = CR_QueryEngine.runReportByIdSorted(report.Id, null, 100, null, 'Amount__c', 'desc');
            String amtKey;
            for (CR_Types.ColumnInfo c : descRes.columns) {
                if (c.label == 'Amount') amtKey = c.key;
            }
            System.assertNotEquals(null, amtKey, 'Amount column should be present.');
            System.assertEquals(2, descRes.rowCount);
            System.assertEquals(250, dec(descRes.rows[0].get(amtKey)), 'Descending: highest amount first.');
            System.assertEquals(100, dec(descRes.rows[1].get(amtKey)), 'Descending: lowest amount last.');

            CR_Types.QueryResult ascRes = CR_QueryEngine.runReportByIdSorted(report.Id, null, 100, null, 'Amount__c', 'asc');
            System.assertEquals(100, dec(ascRes.rows[0].get(amtKey)), 'Ascending: lowest amount first.');
        }
    }

    /**
     * Regression: paging a report sorted by ANY non-Id field must return every row exactly
     * once. The cursor used to be a bare "Id > lastId", which only matches the result order
     * when the query is ordered by Id — every other sort silently dropped rows (a 57k-row
     * CSV export ended at 19,771). Amounts here descend as Ids ascend, so an Id-based cursor
     * on an Amount-ascending sort discards nearly everything after page 1.
     */
    @IsTest
    static void pagesCompletelyWhenSortedByANonIdField() {
        List<Fact_Opportunity__c> rows = new List<Fact_Opportunity__c>();
        for (Integer i = 0; i < 24; i++) {
            rows.add(newFact(i, 100 - i));           // amount falls as Id rises
        }
        for (Integer i = 24; i < 30; i++) {
            rows.add(newFact(i, null));              // exercise the NULLS FIRST/LAST branches
        }
        for (Integer i = 30; i < 36; i++) {
            rows.add(newFact(i, 42));                // ties -> must fall through to the Id tiebreak
        }
        insert rows;
        Integer total = rows.size();

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            for (String direction : new List<String>{ 'asc', 'desc' }) {
                String definitionJson = sortedByAmount(direction);
                Set<Id> seen = new Set<Id>();
                Integer duplicates = 0;
                String token = null;
                Integer guard = 0;
                do {
                    CR_Types.QueryResult page = CR_QueryEngine.runReport(definitionJson, token, 4, null);
                    for (Map<String, Object> row : page.rows) {
                        Id rowId = (Id) row.get('Id');
                        if (seen.contains(rowId)) {
                            duplicates++;
                        }
                        seen.add(rowId);
                    }
                    token = page.nextPageToken;
                    guard++;
                } while (token != null && guard < 100);

                System.assertEquals(total, seen.size(),
                    direction + ': every row must survive pagination, not just page 1.');
                System.assertEquals(0, duplicates, direction + ': no row may be served twice.');
            }
        }
    }

    /**
     * Regression for "the Next button stopped working": the report viewer applies a default
     * server-side sort on a fresh tabular load, but its nextPage() re-queries WITHOUT
     * resending that sort. A cursor names the sequence it came from, so continuing it must
     * reuse that ordering rather than page a different one (or fail).
     */
    @IsTest
    static void continuesTheCursorsOwnSortWhenTheCallerDoesNotResendIt() {
        List<Fact_Opportunity__c> rows = new List<Fact_Opportunity__c>();
        for (Integer i = 0; i < 20; i++) {
            rows.add(newFact(i, 100 - i));           // amount falls as Id rises
        }
        insert rows;

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            // Page 1 sorted by Amount; every later page asks with the UNSORTED definition,
            // exactly as the viewer's Next button does.
            String sortedJson = sortedByAmount('asc');
            String unsortedJson = CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c;

            CR_Types.QueryResult page = CR_QueryEngine.runReport(sortedJson, null, 4, null);
            Set<Id> seen = new Set<Id>();
            Integer duplicates = 0;
            for (Map<String, Object> row : page.rows) {
                seen.add((Id) row.get('Id'));
            }
            Integer guard = 0;
            while (page.nextPageToken != null && guard < 50) {
                page = CR_QueryEngine.runReport(unsortedJson, page.nextPageToken, 4, null);
                for (Map<String, Object> row : page.rows) {
                    Id rowId = (Id) row.get('Id');
                    if (seen.contains(rowId)) {
                        duplicates++;
                    }
                    seen.add(rowId);
                }
                guard++;
            }

            System.assertEquals(rows.size(), seen.size(),
                'Paging must stay complete even when the caller drops the sort on later pages.');
            System.assertEquals(0, duplicates, 'No row may be served twice.');
        }
    }

    // A token whose keys aren't valid sortable+filterable fields must still be refused rather
    // than widening what can be spliced into ORDER BY / WHERE.
    @IsTest
    static void rejectsAPageTokenNamingAnUnusableSortKey() {
        insert new List<Fact_Opportunity__c>{ newFact(0, 10), newFact(1, 20) };
        String forgedToken = EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(
            new Map<String, Object>{
                'k' => new List<String>{ 'No_Such_Field__c', 'Id' },
                'd' => new List<String>{ 'A', 'A' },
                'v' => new List<Object>{ 'x', '000000000000000AAA' }
            })));
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Boolean threw = false;
            try {
                CR_QueryEngine.runReport(sortedByAmount('asc'), forgedToken, 2, null);
            } catch (Exception ex) {
                threw = true;
            }
            System.assertEquals(true, threw, 'A token naming an unknown field must be rejected.');
        }
    }

    // Tokens minted before composite cursors existed carry only lastId. They were correct for
    // the Id-ordered queries that produced them, so in-flight pagination must keep working.
    @IsTest
    static void honoursLegacyLastIdOnlyPageTokens() {
        List<Fact_Opportunity__c> rows = new List<Fact_Opportunity__c>{
            newFact(0, 10), newFact(1, 20), newFact(2, 30)
        };
        insert rows;
        String legacyToken = EncodingUtil.base64Encode(Blob.valueOf(
            JSON.serialize(new Map<String, Object>{ 'lastId' => rows[0].Id })));

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(
                CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c,
                legacyToken, 100, null);
            System.assertEquals(2, result.rowCount, 'Legacy token should resume after the first row.');
        }
    }

    private static Fact_Opportunity__c newFact(Integer index, Decimal amount) {
        String suffix = String.valueOf(index + 1).leftPad(3, '0');
        return new Fact_Opportunity__c(
            Name = 'FO-P' + suffix,
            Source_Opportunity_Id__c = '0060000000' + suffix + 'AAA',
            Opportunity_Name__c = 'Row ' + suffix,
            Amount__c = amount,
            Stage_Name__c = 'Prospecting',
            Close_Date__c = Date.today(),
            Fiscal_Period__c = '2026-04',
            Snapshot_Date__c = Date.today(),
            Is_Current__c = true,
            Record_Count__c = 1
        );
    }

    private static String sortedByAmount(String direction) {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(
            CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('sort', new List<Object>{
            new Map<String, Object>{ 'field' => 'Amount__c', 'direction' => direction }
        });
        return JSON.serialize(definition);
    }

    @IsTest
    static void injectSortOverrideReplacesTheSort() {
        String def = '{"dataset":{"objectApiName":"X"},"sort":[{"field":"Old","direction":"asc"}]}';
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(
            CR_QueryEngine.injectSortOverride(def, 'NewField', 'desc'));
        List<Object> sortList = (List<Object>) m.get('sort');
        System.assertEquals(1, sortList.size(), 'Override replaces any existing sort.');
        System.assertEquals('NewField', ((Map<String, Object>) sortList[0]).get('field'));
        System.assertEquals('desc', ((Map<String, Object>) sortList[0]).get('direction'));

        // Unknown direction normalizes to asc; malformed JSON is returned unchanged.
        Map<String, Object> m2 = (Map<String, Object>) JSON.deserializeUntyped(
            CR_QueryEngine.injectSortOverride(def, 'F', 'sideways'));
        System.assertEquals('asc', ((Map<String, Object>) ((List<Object>) m2.get('sort'))[0]).get('direction'));
        System.assertEquals('not json', CR_QueryEngine.injectSortOverride('not json', 'F', 'asc'));
    }

    @IsTest
    static void getGroupSummaryReturnsFullGroupBreakdownAcrossAllRows() {
        // Regression for "group by shows only the loaded page's bucket": the summary aggregates
        // over the whole result set. Two rows with distinct stages -> two groups, count 1 each.
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            List<CR_QueryEngine.GroupCount> groups =
                CR_QueryEngine.getGroupSummary(report.Id, 'Stage_Name__c', null, null);
            System.assertEquals(2, groups.size(), 'Both distinct stages should appear as groups.');
            Map<String, Integer> byValue = new Map<String, Integer>();
            for (CR_QueryEngine.GroupCount g : groups) {
                byValue.put(g.value, g.count);
            }
            System.assertEquals(1, byValue.get('Prospecting'));
            System.assertEquals(1, byValue.get('Closed Won'));

            // Month granularity buckets the date field server-side (both rows share a close date).
            List<CR_QueryEngine.GroupCount> byMonth =
                CR_QueryEngine.getGroupSummary(report.Id, 'Close_Date__c', null, 'month');
            System.assertEquals(1, byMonth.size(), 'Both rows share one month bucket.');
            System.assertEquals(2, byMonth[0].count);
        }
        // Guards: no report or no group field returns empty rather than erroring.
        System.assertEquals(0, CR_QueryEngine.getGroupSummary(null, 'Stage_Name__c', null, null).size());
        System.assertEquals(0, CR_QueryEngine.getGroupSummary(report.Id, '', null, null).size());
    }

    @IsTest
    static void getReportRowCountReturnsTheFullFilteredCount() {
        CR_TestDataFactory.createFactOpportunityRows(); // 2 rows
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            System.assertEquals(2, CR_QueryEngine.getReportRowCount(report.Id, null),
                'Row count should reflect the whole result set, not a page.');
        }
        System.assertEquals(0, CR_QueryEngine.getReportRowCount(null, null));
    }

    @IsTest
    static void getCrossGroupSummaryBreaksDownByTwoDimensions() {
        CR_TestDataFactory.createFactOpportunityRows(); // Prospecting + Closed Won, same close month
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            List<CR_QueryEngine.GroupCount2> cross = CR_QueryEngine.getCrossGroupSummary(
                report.Id, 'Stage_Name__c', null, 'Close_Date__c', 'month', null
            );
            System.assertEquals(2, cross.size(), 'Two stages in one month -> two cross-groups.');
            Map<String, Integer> byStage = new Map<String, Integer>();
            for (CR_QueryEngine.GroupCount2 g : cross) {
                byStage.put(g.value1, g.count);
                System.assert(g.value2 != null && g.value2.startsWith('20'), 'Second dimension is the month bucket.');
            }
            System.assertEquals(1, byStage.get('Prospecting'));
            System.assertEquals(1, byStage.get('Closed Won'));
        }
        System.assertEquals(0, CR_QueryEngine.getCrossGroupSummary(report.Id, 'Stage_Name__c', null, '', null, null).size(),
            'A missing second field returns empty rather than erroring.');
    }

    private static Decimal dec(Object v) {
        return v == null ? null : Decimal.valueOf(String.valueOf(v));
    }

    @IsTest
    static void validateOverrideFiltersStructuralCatchesProblems() {
        System.assertEquals(0, CR_QueryEngine.validateOverrideFiltersStructural(null).size(),
            'Blank override = nothing to validate.');
        System.assertEquals(0,
            CR_QueryEngine.validateOverrideFiltersStructural('[{"field":"X","operator":"=","value":"y"}]').size(),
            'A well-formed override should produce no structural errors.');
        System.assertEquals(0,
            CR_QueryEngine.validateOverrideFiltersStructural(
                '{"logic":"AND","conditions":[{"field":"X","operator":">","value":1}]}').size(),
            'A nested conditions group should validate.');
        System.assert(!CR_QueryEngine.validateOverrideFiltersStructural('{not json').isEmpty(),
            'Malformed JSON should be flagged.');
        System.assert(!CR_QueryEngine.validateOverrideFiltersStructural('[{"field":"X","value":"y"}]').isEmpty(),
            'A filter missing its operator should be flagged.');
        System.assert(!CR_QueryEngine.validateOverrideFiltersStructural('[{"operator":"=","value":"y"}]').isEmpty(),
            'A filter missing its field should be flagged.');
        System.assert(!CR_QueryEngine.validateOverrideFiltersStructural('[{"field":"X","operator":"BOGUS","value":"y"}]').isEmpty(),
            'An unsupported operator should be flagged.');
    }

    @IsTest
    static void validateReportOverrideFiltersChecksFields() {
        // Live-mode report on a standard object: normalizePath returns fields as-is,
        // matching how real UAT datasets behave (the test 'fact' dataset remaps paths,
        // which masks field-existence checks).
        String liveDef = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'objectApiName' => 'Account', 'primaryObject' => 'Account', 'mode' => 'live'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Name' } },
            'filters' => new List<Object>(), 'groupings' => new List<Object>(),
            'aggregations' => new List<Object>(),
            'sort' => new List<Object>{ new Map<String, Object>{ 'field' => 'Id', 'direction' => 'ASC' } }
        });
        Report_Definition__c report = new Report_Definition__c(
            Name = 'Override Validation Test',
            Developer_Name__c = 'Ovr_Val_Test_' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            Root_Object__c = 'Account', Dataset_Key__c = 'Account',
            Definition_JSON__c = liveDef, Folder__c = 'Tests', Category__c = 'Unit',
            Is_Public__c = true, Version__c = 1
        );
        insert report;

        System.assertEquals(0,
            CR_QueryEngine.validateReportOverrideFilters(report.Id, '[{"field":"Name","operator":"=","value":"x"}]').size(),
            'A real field + valid operator should pass full validation.');
        // A non-existent field is reported with a message that NAMES the field
        // (regression guard for the "Script-thrown exception" message bug).
        List<String> badField = CR_QueryEngine.validateReportOverrideFilters(
            report.Id, '[{"field":"Definitely_Not_Here_zzz__c","operator":"=","value":"x"}]');
        System.assert(!badField.isEmpty(), 'A non-existent field should be reported.');
        System.assert(badField[0].contains('Definitely_Not_Here_zzz__c'),
            'The error should name the offending field, not "Script-thrown exception". Got: ' + badField);
        // A structurally-invalid override is rejected before the engine ever runs.
        System.assert(
            !CR_QueryEngine.validateReportOverrideFilters(report.Id, '[{"field":"Name","value":"x"}]').isEmpty(),
            'An override missing its operator should be reported.');
        System.assertEquals(0, CR_QueryEngine.validateReportOverrideFilters(null, null).size(),
            'A null report / blank override yields no errors.');
    }

    @IsTest
    static void runsAggregateReport() {
        CR_TestDataFactory.createFactOpportunityRows();
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('groupings', new List<Object>{ new Map<String, Object>{ 'field' => 'Stage_Name__c' } });
        definition.put('aggregations', new List<Object>{ new Map<String, Object>{ 'function' => 'SUM', 'field' => 'Amount__c' } });
        definition.put('fields', new List<Object>{ new Map<String, Object>{ 'path' => 'Stage_Name__c' } });

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);
            System.assertEquals(true, result.aggregateResult);
            System.assertEquals(2, result.rowCount);
        }
    }

    /**
     * The "100 daily bars" regression. Grouping a date field WITHOUT a granularity
     * produces one bucket per distinct day; with granularity=Quarter the engine must
     * emit CALENDAR_YEAR/CALENDAR_QUARTER, collapse the rows into year-quarter
     * buckets ("2026-Q1"), and order them chronologically.
     */
    @IsTest
    static void groupsDatesByQuarterInsteadOfPerDay() {
        // Three Close Dates inside a single quarter + one in the next quarter.
        List<Fact_Opportunity__c> rows = new List<Fact_Opportunity__c>();
        List<Date> dates = new List<Date>{
            Date.newInstance(2026, 1, 5),
            Date.newInstance(2026, 2, 11),
            Date.newInstance(2026, 3, 20),
            Date.newInstance(2026, 4, 2)
        };
        Integer i = 0;
        for (Date d : dates) {
            i++;
            rows.add(new Fact_Opportunity__c(
                Name = 'FO-Q' + i,
                Source_Opportunity_Id__c = '006000000000Q' + i + 'AAA',
                Opportunity_Name__c = 'Deal ' + i,
                Amount__c = 100,
                Stage_Name__c = 'Prospecting',
                Close_Date__c = d,
                Snapshot_Date__c = Date.today(),
                Is_Current__c = true,
                Record_Count__c = 1
            ));
        }
        insert rows;

        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(
            CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('groupings', new List<Object>{
            new Map<String, Object>{ 'field' => 'Close_Date__c', 'granularity' => 'Quarter' }
        });
        definition.put('aggregations', new List<Object>{
            new Map<String, Object>{ 'function' => 'COUNT', 'field' => 'Id' }
        });
        definition.put('fields', new List<Object>());

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);

            System.assertEquals(true, result.aggregateResult, 'Should be an aggregate run.');
            System.assert(result.executedSoql.contains('CALENDAR_QUARTER'),
                'Quarter grouping must use CALENDAR_QUARTER. SOQL: ' + result.executedSoql);
            // 4 dates across 2 quarters -> 2 buckets, NOT 4 per-day rows.
            System.assertEquals(2, result.rowCount,
                'Four dates spanning two quarters must collapse to two buckets, not one row per day.');
            System.assertEquals('2026-Q1', String.valueOf(result.rows[0].get('g0')),
                'Buckets must be readable and chronological.');
            System.assertEquals('2026-Q2', String.valueOf(result.rows[1].get('g0')));
            System.assertEquals(3, Integer.valueOf(result.rows[0].get('a0')), 'Q1 holds three of the dates.');
        }
    }

    /**
     * "My Records" regression. The fact tables store the rep as a NAME string, so a
     * filter comparing that column to the user's Id silently matched nothing and every
     * PRM user saw a blank report. $CURRENT_USER must resolve to the running user's
     * NAME (and $CURRENT_USER_ID to their Id) at query time.
     */
    @IsTest
    static void currentUserTokenResolvesToRunningUsersName() {
        User me = [SELECT Id, Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];

        CR_TestDataFactory.createFactOpportunityRows();
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(
            CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);

        // Filter on a NAME-style text column using the token. Opportunity_Name__c is a
        // plain text field, standing in for the facts' Assigned_To__c.
        definition.put('filters', new List<Object>{
            new Map<String, Object>{ 'field' => 'Opportunity_Name__c', 'operator' => '=', 'value' => '$CURRENT_USER' }
        });

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);
            // The SOQL must contain the running user's NAME, never the literal token
            // and never a raw 005... Id.
            System.assert(!result.executedSoql.contains('$CURRENT_USER'),
                'The token must be resolved, not passed through. SOQL: ' + result.executedSoql);
            System.assert(result.executedSoql.contains(UserInfo.getName()),
                'The token must resolve to the running user name. SOQL: ' + result.executedSoql);
        }

        // And the Id variant resolves to the Id.
        definition.put('filters', new List<Object>{
            new Map<String, Object>{ 'field' => 'Opportunity_Name__c', 'operator' => '=', 'value' => '$CURRENT_USER_ID' }
        });
        CR_Types.QueryResult byId = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);
        System.assert(byId.executedSoql.contains(String.valueOf(UserInfo.getUserId()).left(15)),
            'The Id token must resolve to the running user Id. SOQL: ' + byId.executedSoql);
    }

    /**
     * The column-filter picker used to derive its options from the rows the viewer had
     * loaded, so with 33k rows paged 100 at a time a rep could not even find their own
     * name in the "Assigned To" filter. Distinct values must come from every record the
     * report matches.
     */
    @IsTest
    static void distinctValuesCoverAllRecordsNotJustTheLoadedPage() {
        CR_TestDataFactory.createFactOpportunityRows(); // Prospecting + Closed Won
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            List<String> values = CR_QueryEngine.getDistinctValues(report.Id, 'Stage_Name__c', 500);
            System.assertEquals(2, values.size(),
                'Every distinct value in the report must be offered, not only those on the loaded page. Got: ' + values);
            System.assert(values.contains('Prospecting') && values.contains('Closed Won'),
                'Both stage values must be present. Got: ' + values);

            // A page-size of 1 must not shrink the option list — that was the bug.
            CR_Types.QueryResult onePage = CR_QueryEngine.runReportById(report.Id, null, 1, null);
            System.assertEquals(1, onePage.rowCount, 'Sanity: only one row is loaded.');
            System.assertEquals(2, CR_QueryEngine.getDistinctValues(report.Id, 'Stage_Name__c', 500).size(),
                'Distinct values must be independent of the page size.');

            // Non-groupable / unknown columns degrade gracefully rather than throwing.
            System.assertEquals(0, CR_QueryEngine.getDistinctValues(null, 'Stage_Name__c', 500).size());
        }
    }

    @IsTest
    static void appliesFormulasAndBuckets() {
        CR_TestDataFactory.createFactOpportunityRows();
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('formulas', new List<Object>{
            new Map<String, Object>{ 'name' => 'Weighted Amount', 'type' => 'number', 'expression' => 'Amount__c * 2' }
        });
        definition.put('buckets', new List<Object>{
            new Map<String, Object>{
                'name' => 'Deal Size',
                'sourceField' => 'Amount__c',
                'defaultValue' => 'Large',
                'rules' => new List<Object>{ new Map<String, Object>{ 'label' => 'Small', 'operator' => '<=', 'value' => 150 } }
            }
        });
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);
            System.assert(result.rows[0].containsKey('Weighted Amount'));
            System.assert(result.rows[0].containsKey('Deal Size'));
        }
    }

    @IsTest
    static void filtersAndPaginatesRows() {
        CR_TestDataFactory.createFactOpportunityRows();
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('filters', new List<Object>{ new Map<String, Object>{ 'field' => 'Amount__c', 'operator' => '>', 'value' => 50 } });

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            CR_Types.QueryResult firstPage = CR_QueryEngine.runReport(JSON.serialize(definition), null, 1, null);
            System.assertEquals(1, firstPage.rowCount);
            System.assertNotEquals(null, firstPage.nextPageToken);

            CR_Types.QueryResult secondPage = CR_QueryEngine.runReport(JSON.serialize(definition), firstPage.nextPageToken, 1, null);
            System.assertEquals(1, secondPage.rowCount);
        }
    }

    @IsTest
    static void validationRejectsUnknownFields() {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(CR_TestDataFactory.createFactOpportunityReport(false).Definition_JSON__c);
        definition.put('fields', new List<Object>{ new Map<String, Object>{ 'path' => 'Missing_Field__c' } });
        CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(JSON.serialize(definition));
        System.assertEquals(false, validation.valid);
        System.assert(!validation.errors.isEmpty());
    }

    @IsTest
    static void validationAcceptsObjectPrefixAndFieldCaseDifferences() {
        Map<String, Object> definition = new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Contract_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Contract',
                'primaryObject' => 'Contract'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Contract.name', 'label' => 'Contract Name' }
            },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        };

        CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(JSON.serialize(definition));

        System.assertEquals(true, validation.valid, JSON.serialize(validation.errors));
    }

    @IsTest
    static void usesDescribeLabelsWhenSavedLabelIsApiPath() {
        Map<String, Object> definition = new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Account.Name', 'label' => 'Account.Name' }
            },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        };

        CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);

        String expectedLabel = Account.SObjectType.getDescribe().fields.getMap().get('Name').getDescribe().getLabel();
        System.assertEquals(expectedLabel, result.columns[0].label);
    }

    @IsTest
    static void runsChildCollectionFieldsAsFlatRows() {
        String suffix = String.valueOf(Datetime.now().getTime());
        Group parentGroup = new Group(Name = 'CR Child Rows ' + suffix, DeveloperName = 'CR_Child_Rows_' + suffix, Type = 'Regular');
        Group nestedGroup = new Group(Name = 'CR Nested Child ' + suffix, DeveloperName = 'CR_Nested_Child_' + suffix, Type = 'Regular');
        insert new List<Group>{ parentGroup, nestedGroup };
        insert new List<GroupMember>{
            new GroupMember(GroupId = parentGroup.Id, UserOrGroupId = UserInfo.getUserId()),
            new GroupMember(GroupId = parentGroup.Id, UserOrGroupId = nestedGroup.Id)
        };

        Map<String, Object> definition = new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Group_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Group',
                'primaryObject' => 'Group'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Group.Name', 'label' => 'Group Name' },
                new Map<String, Object>{ 'path' => 'GroupMembers.UserOrGroupId', 'label' => 'Group Member' }
            },
            'filters' => new List<Object>{
                new Map<String, Object>{ 'field' => 'Id', 'operator' => '=', 'value' => parentGroup.Id }
            },
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>(),
            'sort' => new List<Object>{ new Map<String, Object>{ 'field' => 'Id', 'direction' => 'ASC' } }
        };

        CR_Types.QueryResult result = CR_QueryEngine.runReport(JSON.serialize(definition), null, 100, null);

        System.assert(result.executedSoql.contains('(SELECT UserOrGroupId FROM GroupMembers LIMIT 200)'), result.executedSoql);
        System.assertEquals(2, result.rowCount);
        Set<String> memberIds = new Set<String>();
        for (Map<String, Object> row : result.rows) {
            System.assertEquals(parentGroup.Name, row.get('Group.Name'));
            memberIds.add(String.valueOf(row.get('GroupMembers.UserOrGroupId')));
        }
        System.assertEquals(new Set<String>{ String.valueOf(UserInfo.getUserId()), String.valueOf(nestedGroup.Id) }, memberIds);
    }

    // Phase 1 v8: runReportsByIds bundles multiple saved-report executions
    // into one Apex call. Verify the happy path returns per-id results, the
    // error path surfaces as a per-id errorMessage rather than a throw, and
    // empty input returns an empty map (not null).
    @IsTest
    static void runReportsByIds_runs_each_id_and_keys_results() {
        CR_TestDataFactory.createFactOpportunityRows();
        // The factory's Developer_Name__c is fixed (unique constraint), so
        // build the second report by cloning the first and tweaking the key
        // rather than calling the factory twice.
        Report_Definition__c report1 = CR_TestDataFactory.createFactOpportunityReport(true);
        Report_Definition__c report2 = report1.clone(false, true, false, false);
        report2.Developer_Name__c = report1.Developer_Name__c + '_2';
        report2.Name = report1.Name + ' (Copy)';
        insert report2;

        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        Map<Id, CR_Types.QueryResult> out;
        System.runAs(admin) {
            out = CR_QueryEngine.runReportsByIds(
                new List<Id>{ report1.Id, report2.Id },
                100,
                null
            );
        }
        Test.stopTest();

        System.assertEquals(2, out.size());
        System.assert(out.containsKey(report1.Id));
        System.assert(out.containsKey(report2.Id));
        System.assertEquals(2, out.get(report1.Id).rowCount);
        System.assertEquals(2, out.get(report2.Id).rowCount);
    }

    @IsTest
    static void runReportsByIds_isolates_per_id_failures() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c good = CR_TestDataFactory.createFactOpportunityReport(true);
        // A non-existent Id causes runReportById's SOQL to throw QueryException;
        // the batch endpoint should catch and surface as errorMessage on that key
        // without affecting the good run.
        Id missingId = '0' + good.Id.to15().substring(1);

        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        Map<Id, CR_Types.QueryResult> out;
        System.runAs(admin) {
            out = CR_QueryEngine.runReportsByIds(
                new List<Id>{ good.Id, missingId },
                100,
                null
            );
        }
        Test.stopTest();

        System.assertEquals(2, out.size());
        System.assert(String.isBlank(out.get(good.Id).errorMessage), 'Good report should not have an error');
        System.assert(!String.isBlank(out.get(missingId).errorMessage), 'Missing id should carry errorMessage');
        System.assertEquals(2, out.get(good.Id).rowCount);
        System.assertEquals(0, out.get(missingId).rowCount);
    }

    @IsTest
    static void runReportsByIds_returns_empty_map_for_null_or_empty_input() {
        System.assertEquals(0, CR_QueryEngine.runReportsByIds(null, 100, null).size());
        System.assertEquals(0, CR_QueryEngine.runReportsByIds(new List<Id>(), 100, null).size());
    }

    @IsTest
    static void runReportsByIds_rejects_oversized_batches() {
        // Build a 51-element list of bogus ids to verify the cap is enforced
        // before any SOQL fires.
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 51; i++) {
            ids.add('a01000000000000AAA');
        }
        try {
            CR_QueryEngine.runReportsByIds(ids, 100, null);
            System.assert(false, 'Expected AuraHandledException for oversized batch');
        } catch (AuraHandledException ex) {
            // expected
        }
    }

    @IsTest
    static void validationRejectsChildCollectionFilters() {
        Map<String, Object> definition = new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Group_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Group',
                'primaryObject' => 'Group'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Group.Name' }
            },
            'filters' => new List<Object>{
                new Map<String, Object>{ 'field' => 'GroupMembers.UserOrGroupId', 'operator' => '=', 'value' => UserInfo.getUserId() }
            },
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        };

        CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(JSON.serialize(definition));

        System.assertEquals(false, validation.valid);
        System.assert(!validation.errors.isEmpty());
    }

    // Regression: "first run errors, second run works." Under OWD Public Read
    // Only, a non-owner has read-only ROW access to the Report_Definition__c,
    // so the end-of-run last-run stamp (a with-sharing UPDATE) threw
    // INSUFFICIENT_ACCESS_OR_READONLY and surfaced as "Reporting error" — but
    // only on a cache MISS; the next run came from Platform Cache and returned
    // before the stamp, masking the bug. The stamp now runs without sharing +
    // fail-soft, so a read-only user runs the report on the very first try.
    @IsTest
    static void runReportById_readOnlyUser_doesNotFailOnRunStamp() {
        User reader = makeReportingUser();
        CR_TestDataFactory.createFactOpportunityRows();
        // Inserted as the test (admin) user, so `reader` is a non-owner.
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);

        Test.startTest();
        System.runAs(reader) {
            CR_Types.QueryResult result = CR_QueryEngine.runReportById(report.Id, null, 100, null);
            System.assertNotEquals(null, result, 'A read-only user should get a result on the first run.');
            System.assertEquals(2, result.rowCount, 'The read-only user should run the report, not hit an access error.');
        }
        Test.stopTest();
    }

    // A user holding only the Custom_Reporting_User permission set: can read the
    // Fact dataset + run controllers, but has no edit/owner rights on the
    // report definition. Built inside runAs to dodge MIXED_DML with the data DML.
    private static User makeReportingUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crqe',
                Email = 'crqe@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'EngineReader',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crqe' + rand + '@example.com.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_User' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }
}