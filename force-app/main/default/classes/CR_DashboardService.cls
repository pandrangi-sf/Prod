public with sharing class CR_DashboardService {
    public class DashboardPayload {
        @AuraEnabled public Dashboard__c dashboard { get; set; }
        @AuraEnabled public List<Dashboard_Component__c> components { get; set; }
        @AuraEnabled public Map<Id, CR_Types.QueryResult> componentResults { get; set; }
    }

    private static final Integer JSON_FIELD_MAX_LENGTH = 130000;

    @AuraEnabled
    public static Id saveDashboard(
        Id dashboardId,
        String name,
        String folder,
        String category,
        String filterJson,
        String layoutJson,
        Boolean isPublic,
        String componentsJson,
        Decimal lastKnownVersion
    ) {
        // Phase A signature retained as a thin wrapper so older client code
        // (including any cached LWC bundles in users' browsers immediately
        // after deploy) still works without arg-shape mismatch errors.
        return saveDashboardV2(
            dashboardId, name, folder, category, filterJson, layoutJson,
            isPublic, componentsJson, lastKnownVersion,
            null, null, null, null, null, null
        );
    }

    @AuraEnabled
    public static Id saveDashboardV2(
        Id dashboardId,
        String name,
        String folder,
        String category,
        String filterJson,
        String layoutJson,
        Boolean isPublic,
        String componentsJson,
        Decimal lastKnownVersion,
        String theme,
        String palette,
        String gridSize,
        String runAsMode,
        Id runAsUserId,
        Boolean allowViewerRunAsChoice
    ) {
        return saveDashboardV3(
            dashboardId, name, folder, category, filterJson, layoutJson,
            isPublic, componentsJson, lastKnownVersion,
            theme, palette, gridSize, runAsMode, runAsUserId, allowViewerRunAsChoice,
            null
        );
    }

    // Phase I: v3 adds `description` as the only new arg. Older clients on v2
    // continue to work via the wrapper above with description=null.
    @AuraEnabled
    public static Id saveDashboardV3(
        Id dashboardId,
        String name,
        String folder,
        String category,
        String filterJson,
        String layoutJson,
        Boolean isPublic,
        String componentsJson,
        Decimal lastKnownVersion,
        String theme,
        String palette,
        String gridSize,
        String runAsMode,
        Id runAsUserId,
        Boolean allowViewerRunAsChoice,
        String description
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('Dashboard name is required.');
        }
        // Building is gated by object CRUD: Apex DML runs in system mode for
        // CRUD by default, so without this an insert/update would succeed even
        // for a view-only user. Mirrors the isDeletable guard in deleteDashboard.
        if (dashboardId == null && !Schema.sObjectType.Dashboard__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to create dashboards.');
        }
        if (dashboardId != null && !Schema.sObjectType.Dashboard__c.isUpdateable()) {
            throw new AuraHandledException('You do not have permission to edit dashboards.');
        }
        validateJsonSize('Filters', filterJson);
        validateJsonSize('Layout', layoutJson);
        validateJsonSize('Components', componentsJson);

        // DR08: validate dashboard-level filters against each component's report
        // definition before persisting, so we don't write a dashboard that fails
        // to load. Errors are surfaced per-component so the user knows where to fix.
        List<String> filterErrors = validateDashboardFilters(filterJson, componentsJson);
        if (!filterErrors.isEmpty()) {
            throw new AuraHandledException(
                'Dashboard filters could not be applied to all component reports:\n  - '
                + String.join(filterErrors, '\n  - ')
            );
        }

        // Reject duplicate Names. Developer_Name__c has <unique>true</unique> in the
        // schema, but normalizeDeveloperName appends a random suffix so the platform
        // constraint never trips on collisions. Enforce uniqueness on Name here so
        // users get a clear error instead of two indistinguishable dashboards.
        List<Dashboard__c> existingByName = dashboardId == null
            ? [SELECT Id FROM Dashboard__c WHERE Name = :name LIMIT 1]
            : [SELECT Id FROM Dashboard__c WHERE Name = :name AND Id != :dashboardId LIMIT 1];
        if (!existingByName.isEmpty()) {
            throw new AuraHandledException(
                'A dashboard named "' + name + '" already exists. Pick a different name.'
            );
        }

        Dashboard__c dashboard;
        if (dashboardId == null) {
            dashboard = new Dashboard__c();
        } else {
            dashboard = [SELECT Id, Version__c FROM Dashboard__c WHERE Id = :dashboardId LIMIT 1];
            if (lastKnownVersion != null && dashboard.Version__c != null
                && dashboard.Version__c != lastKnownVersion) {
                // [CR_CONFLICT] prefix matches what crDashboardBuilder.save() detects
                // for the sticky reload toast.
                throw new AuraHandledException(
                    '[CR_CONFLICT] This dashboard was modified by another user since you loaded it. ' +
                    'Reload to see the latest changes before saving.'
                );
            }
        }
        dashboard.Name = name;
        dashboard.Developer_Name__c = normalizeDeveloperName(name);
        dashboard.Folder__c = folder;
        dashboard.Folder_Ref__c = CR_FolderService.resolveFolderId(folder);
        dashboard.Category__c = category;
        dashboard.Filter_JSON__c = filterJson;
        dashboard.Layout_JSON__c = layoutJson;
        dashboard.Is_Public__c = isPublic == true;
        dashboard.Version__c = dashboard.Version__c == null ? 1 : dashboard.Version__c + 1;
        // Phase B fields. Picklists are <restricted>true</restricted> so we
        // null-coalesce client values to the defaults when blank to avoid
        // INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on save.
        if (String.isNotBlank(theme)) {
            dashboard.Theme__c = theme;
        }
        if (String.isNotBlank(palette)) {
            dashboard.Palette__c = palette;
        }
        if (String.isNotBlank(gridSize)) {
            dashboard.Grid_Size__c = gridSize;
        }
        if (String.isNotBlank(runAsMode)) {
            dashboard.Run_As_Mode__c = runAsMode;
        }
        // Run_As_User is a Lookup, so null is allowed and clears the relationship
        // when the mode flips back to Me/Viewer.
        dashboard.Run_As_User__c = runAsUserId;
        if (allowViewerRunAsChoice != null) {
            dashboard.Allow_Viewer_Run_As_Choice__c = allowViewerRunAsChoice;
        }
        // Phase I: description is optional; only overwrite when the client sent
        // a non-null value, so older v2 callers don't blank an existing value.
        if (description != null) {
            dashboard.Description__c = description;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            if (dashboardId == null) {
                insert dashboard;
            } else {
                update dashboard;
            }

            // Diff-based component sync: keep stable Ids for components that
            // existed before this save so Dashboard_Component_Run__c lookups
            // and any external bookmarks remain valid.
            Map<Id, Dashboard_Component__c> existingById = new Map<Id, Dashboard_Component__c>();
            if (dashboardId != null) {
                for (Dashboard_Component__c existing : [
                    SELECT Id FROM Dashboard_Component__c WHERE Dashboard__c = :dashboard.Id
                ]) {
                    existingById.put(existing.Id, existing);
                }
            }

            List<Dashboard_Component__c> toUpsert = new List<Dashboard_Component__c>();
            Set<Id> incomingIds = new Set<Id>();
            for (Object rawComponent : asObjectList(JSON.deserializeUntyped(String.isBlank(componentsJson) ? '[]' : componentsJson))) {
                Map<String, Object> componentMap = asMap(rawComponent);
                Dashboard_Component__c component = new Dashboard_Component__c();
                String idStr = asString(componentMap.get('id'));
                if (String.isNotBlank(idStr)) {
                    try {
                        Id existingId = Id.valueOf(idStr);
                        if (existingById.containsKey(existingId)) {
                            component.Id = existingId;
                            incomingIds.add(existingId);
                        }
                    } catch (Exception ignored) {
                        // Bad id from client — treat as new component.
                    }
                }
                component.Name = asString(componentMap.get('name'));
                // Dashboard__c is a non-reparentable master-detail field, so the
                // platform rejects writes to it on update. Set it only on insert.
                if (component.Id == null) {
                    component.Dashboard__c = dashboard.Id;
                }
                component.Report_Definition__c = (Id) asString(componentMap.get('reportDefinitionId'));
                component.Visualization_JSON__c = JSON.serialize(componentMap.get('visualization'));
                component.Position_X__c = toDecimal(componentMap.get('x'));
                component.Position_Y__c = toDecimal(componentMap.get('y'));
                component.Width__c = toDecimal(componentMap.get('w'));
                component.Height__c = toDecimal(componentMap.get('h'));
                toUpsert.add(component);
            }

            List<Dashboard_Component__c> toDelete = new List<Dashboard_Component__c>();
            for (Id existingId : existingById.keySet()) {
                if (!incomingIds.contains(existingId)) {
                    toDelete.add(existingById.get(existingId));
                }
            }

            if (!toUpsert.isEmpty()) {
                upsert toUpsert;
            }
            if (!toDelete.isEmpty()) {
                delete toDelete;
            }
        } catch (Exception ex) {
            Database.rollback(savepoint);
            throw new AuraHandledException('Save failed: ' + ex.getMessage());
        }
        return dashboard.Id;
    }

    // Phase A: hard-delete a dashboard (master-detail cascade removes the
    // child Dashboard_Component__c rows; Dashboard_Component_Run__c lookups are
    // configured with deleteConstraint=SetNull, so historic run rows survive
    // with a null Component reference).
    @AuraEnabled
    public static void deleteDashboard(Id dashboardId) {
        if (dashboardId == null) {
            throw new AuraHandledException('Dashboard id is required.');
        }
        if (!Schema.sObjectType.Dashboard__c.isDeletable()) {
            throw new AuraHandledException('You do not have permission to delete dashboards.');
        }
        List<Dashboard__c> rows = [SELECT Id FROM Dashboard__c WHERE Id = :dashboardId LIMIT 1];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Dashboard not found: ' + dashboardId);
        }
        try {
            delete rows;
        } catch (Exception ex) {
            throw new AuraHandledException('Delete failed: ' + ex.getMessage());
        }
    }

    // Phase A: clone an existing dashboard with a new Name. Copies the parent
    // record and every child component (with their visualization JSON, layout,
    // sizing). Owner is set to the running user. Version resets to 1.
    @AuraEnabled
    public static Id cloneDashboard(Id sourceDashboardId, String newName) {
        if (sourceDashboardId == null) {
            throw new AuraHandledException('Source dashboard id is required.');
        }
        if (String.isBlank(newName)) {
            throw new AuraHandledException('New dashboard name is required.');
        }
        if (!Schema.sObjectType.Dashboard__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to create dashboards.');
        }
        List<Dashboard__c> existingByName = [
            SELECT Id FROM Dashboard__c WHERE Name = :newName LIMIT 1
        ];
        if (!existingByName.isEmpty()) {
            throw new AuraHandledException(
                'A dashboard named "' + newName + '" already exists. Pick a different name.'
            );
        }

        Dashboard__c source = [
            SELECT Id, Name, Folder__c, Folder_Ref__c, Category__c, Filter_JSON__c, Layout_JSON__c, Is_Public__c,
                   Theme__c, Palette__c, Grid_Size__c, Run_As_Mode__c, Run_As_User__c, Allow_Viewer_Run_As_Choice__c,
                   Description__c
            FROM Dashboard__c
            WHERE Id = :sourceDashboardId
            LIMIT 1
        ];

        Savepoint savepoint = Database.setSavepoint();
        try {
            Dashboard__c clone = new Dashboard__c(
                Name = newName,
                Developer_Name__c = normalizeDeveloperName(newName),
                Folder__c = source.Folder__c,
                Folder_Ref__c = source.Folder_Ref__c,
                Category__c = source.Category__c,
                Filter_JSON__c = source.Filter_JSON__c,
                Layout_JSON__c = source.Layout_JSON__c,
                Is_Public__c = source.Is_Public__c,
                Theme__c = source.Theme__c,
                Palette__c = source.Palette__c,
                Grid_Size__c = source.Grid_Size__c,
                Run_As_Mode__c = source.Run_As_Mode__c,
                Run_As_User__c = source.Run_As_User__c,
                Allow_Viewer_Run_As_Choice__c = source.Allow_Viewer_Run_As_Choice__c,
                Description__c = source.Description__c,
                Version__c = 1
            );
            insert clone;

            List<Dashboard_Component__c> sourceComponents = [
                SELECT Name, Report_Definition__c, Visualization_JSON__c,
                       Position_X__c, Position_Y__c, Width__c, Height__c
                FROM Dashboard_Component__c
                WHERE Dashboard__c = :sourceDashboardId
            ];
            if (!sourceComponents.isEmpty()) {
                List<Dashboard_Component__c> clonedComponents = new List<Dashboard_Component__c>();
                for (Dashboard_Component__c c : sourceComponents) {
                    clonedComponents.add(new Dashboard_Component__c(
                        Name = c.Name,
                        Dashboard__c = clone.Id,
                        Report_Definition__c = c.Report_Definition__c,
                        Visualization_JSON__c = c.Visualization_JSON__c,
                        Position_X__c = c.Position_X__c,
                        Position_Y__c = c.Position_Y__c,
                        Width__c = c.Width__c,
                        Height__c = c.Height__c
                    ));
                }
                insert clonedComponents;
            }
            return clone.Id;
        } catch (Exception ex) {
            Database.rollback(savepoint);
            throw new AuraHandledException('Clone failed: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static void saveComponentChartType(Id componentId, String chartType) {
        if (componentId == null) {
            throw new AuraHandledException('componentId is required.');
        }
        if (String.isBlank(chartType)) {
            throw new AuraHandledException('chartType is required.');
        }
        // Editing a component is editing its dashboard — gate on dashboard edit.
        if (!Schema.sObjectType.Dashboard__c.isUpdateable()) {
            throw new AuraHandledException('You do not have permission to edit dashboards.');
        }
        // Maps the picker's chart-type token to the persisted viz.type. Both
        // sides of the table accept synonyms so client and server stay loose
        // about 'donut' vs 'doughnut' and 'horizontal' vs 'horizontalbar'.
        Map<String, String> chartTypeToVisualization = new Map<String, String>{
            'bar'           => 'bar',
            'horizontal'    => 'horizontal',
            'horizontalbar' => 'horizontal',
            'hbar'          => 'horizontal',
            'line'          => 'line',
            'donut'         => 'donut',
            'doughnut'      => 'donut',
            'pie'           => 'pie',
            'metric'        => 'metric',
            'gauge'         => 'gauge',
            'table'         => 'table'
        };
        String vizType = chartTypeToVisualization.get(chartType.toLowerCase());
        if (vizType == null) {
            throw new AuraHandledException('Unsupported chart type: ' + chartType);
        }
        List<Dashboard_Component__c> rows = [
            SELECT Id, Visualization_JSON__c
            FROM Dashboard_Component__c
            WHERE Id = :componentId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Component not found: ' + componentId);
        }
        Dashboard_Component__c component = rows[0];
        Map<String, Object> viz = new Map<String, Object>();
        if (String.isNotBlank(component.Visualization_JSON__c)) {
            try {
                Object parsed = JSON.deserializeUntyped(component.Visualization_JSON__c);
                if (parsed instanceof Map<String, Object>) {
                    viz = (Map<String, Object>) parsed;
                }
            } catch (Exception ignored) {
                // Malformed JSON — start fresh.
            }
        }
        viz.put('type', vizType);
        component.Visualization_JSON__c = JSON.serialize(viz);
        update component;
    }

    @TestVisible
    private static List<String> validateDashboardFilters(String filterJson, String componentsJson) {
        List<String> errors = new List<String>();
        if (String.isBlank(filterJson) || filterJson.trim() == '[]') return errors;
        if (String.isBlank(componentsJson) || componentsJson.trim() == '[]') return errors;

        // Collect distinct report-definition ids from the components JSON.
        Set<Id> reportIds = new Set<Id>();
        for (Object raw : asObjectList(JSON.deserializeUntyped(componentsJson))) {
            Map<String, Object> m = asMap(raw);
            String rawId = asString(m.get('reportDefinitionId'));
            if (String.isBlank(rawId)) continue;
            try {
                reportIds.add((Id) rawId);
            } catch (Exception ex) {
                // skip malformed ids; the component itself will fail at insert time
            }
        }
        if (reportIds.isEmpty()) return errors;

        // For each component report, merge dashboard filters into the report's
        // existing filters and run the engine's full validation. Anything that
        // fails (unknown field, unsupported operator, etc.) gets reported per report.
        List<Object> dashboardFilters;
        try {
            dashboardFilters = (List<Object>) JSON.deserializeUntyped(filterJson);
        } catch (Exception ex) {
            errors.add('Dashboard filter JSON could not be parsed: ' + ex.getMessage());
            return errors;
        }

        for (Report_Definition__c report : [
            SELECT Id, Name, Definition_JSON__c
            FROM Report_Definition__c
            WHERE Id IN :reportIds
        ]) {
            try {
                Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(report.Definition_JSON__c);
                List<Object> existingFilters = def.get('filters') instanceof List<Object>
                    ? (List<Object>) def.get('filters')
                    : new List<Object>();
                List<Object> mergedFilters = new List<Object>();
                mergedFilters.addAll(existingFilters);
                mergedFilters.addAll(dashboardFilters);
                def.put('filters', mergedFilters);
                CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(JSON.serialize(def));
                if (!validation.valid) {
                    errors.add('"' + report.Name + '": ' + String.join(validation.errors, '; '));
                }
            } catch (Exception ex) {
                errors.add('"' + report.Name + '": ' + ex.getMessage());
            }
        }
        return errors;
    }

    @TestVisible
    private static void validateJsonSize(String label, String value) {
        if (value != null && value.length() > JSON_FIELD_MAX_LENGTH) {
            throw new AuraHandledException(
                label + ' JSON is too large (' + value.length() + ' characters). '
                + 'The underlying field caps at 131,072. Reduce content or split the dashboard.'
            );
        }
    }

    // Phase I: feeds the New Dashboard Wizard's folder combobox. Returns the
    // distinct non-blank Folder__c values across existing dashboards so users
    // can pick an existing folder without typing. Picklist + auto-creation
    // (typing a new name) handled client-side.
    // Lets the viewer hide New/Edit/Delete/Clone when the user is view-only.
    // The save/delete/clone methods enforce this server-side too.
    @AuraEnabled(cacheable=true)
    public static Boolean canBuildDashboards() {
        return Schema.sObjectType.Dashboard__c.isCreateable();
    }

    @AuraEnabled(cacheable=true)
    public static List<String> listFolders() {
        List<String> folders = new List<String>();
        for (AggregateResult ar : [
            SELECT Folder__c folderName
            FROM Dashboard__c
            WHERE Folder__c != null
            GROUP BY Folder__c
            ORDER BY Folder__c ASC
            LIMIT 200
        ]) {
            String f = (String) ar.get('folderName');
            if (String.isNotBlank(f)) folders.add(f);
        }
        return folders;
    }

    // Phase I: cheap preflight for the New Dashboard Wizard so the user finds
    // out about a duplicate name before they build a whole dashboard. Server-
    // side save() still does the authoritative check (uniqueness rule
    // enforced at insert time, see existingByName guard above) — this is
    // strictly a UX-friendly early-warning.
    @AuraEnabled(cacheable=true)
    public static Boolean dashboardNameExists(String name) {
        if (String.isBlank(name)) return false;
        return [SELECT COUNT() FROM Dashboard__c WHERE Name = :name LIMIT 1] > 0;
    }

    @AuraEnabled(cacheable=true)
    public static List<Dashboard__c> listDashboards(String searchTerm) {
        String likeTerm = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';
        Id currentUserId = UserInfo.getUserId();
        return [
            SELECT Id, Name, Folder__c, Category__c, Is_Public__c, LastModifiedDate
            FROM Dashboard__c
            WHERE Name LIKE :likeTerm
            AND (Is_Public__c = true OR OwnerId = :currentUserId)
            ORDER BY LastModifiedDate DESC
            LIMIT 200
        ];
    }

    @AuraEnabled
    public static DashboardPayload loadDashboard(Id dashboardId, Boolean includeResults) {
        DashboardPayload payload = new DashboardPayload();
        payload.dashboard = [
            SELECT Id, Name, Folder__c, Category__c, Filter_JSON__c, Layout_JSON__c, Is_Public__c, Version__c,
                   Theme__c, Palette__c, Grid_Size__c, Run_As_Mode__c, Run_As_User__c, Allow_Viewer_Run_As_Choice__c,
                   Description__c
            FROM Dashboard__c
            WHERE Id = :dashboardId
            LIMIT 1
        ];
        payload.components = [
            SELECT Id, Name, Report_Definition__c, Visualization_JSON__c, Position_X__c, Position_Y__c, Width__c, Height__c
            FROM Dashboard_Component__c
            WHERE Dashboard__c = :dashboardId
            ORDER BY Position_Y__c, Position_X__c
        ];
        payload.componentResults = new Map<Id, CR_Types.QueryResult>();
        if (includeResults == true) {
            // DR06 partial: dedup report execution within a single load.
            // Two components sharing the same Report_Definition__c only run once.
            Map<Id, CR_Types.QueryResult> resultsByReportId = new Map<Id, CR_Types.QueryResult>();
            for (Dashboard_Component__c component : payload.components) {
                if (component.Report_Definition__c == null) {
                    continue;
                }
                CR_Types.QueryResult result;
                if (resultsByReportId.containsKey(component.Report_Definition__c)) {
                    result = resultsByReportId.get(component.Report_Definition__c);
                } else {
                    // DR07: per-component fault isolation. One bad report definition
                    // produces a placeholder result with errorMessage set, instead of
                    // throwing and breaking the whole dashboard load.
                    try {
                        result = CR_QueryEngine.runReportById(
                            component.Report_Definition__c,
                            null,
                            250,
                            payload.dashboard.Filter_JSON__c
                        );
                    } catch (Exception ex) {
                        result = errorResult('Component "' + component.Name + '" failed: ' + ex.getMessage());
                    }
                    resultsByReportId.put(component.Report_Definition__c, result);
                }
                payload.componentResults.put(component.Id, result);
            }
        }
        return payload;
    }

    @TestVisible
    private static CR_Types.QueryResult errorResult(String message) {
        CR_Types.QueryResult result = new CR_Types.QueryResult();
        result.columns = new List<CR_Types.ColumnInfo>();
        result.rows = new List<Map<String, Object>>();
        result.totals = new Map<String, Object>();
        result.groupLevels = new List<String>();
        result.warnings = new List<String>();
        result.rowCount = 0;
        result.aggregateResult = false;
        result.errorMessage = message;
        return result;
    }

    private static List<Object> asObjectList(Object value) {
        if (value == null) return new List<Object>();
        if (value instanceof List<Object>) return (List<Object>) value;
        return new List<Object>{ value };
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Decimal toDecimal(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) return 0;
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String normalizeDeveloperName(String name) {
        String value = String.isBlank(name) ? 'Custom_Dashboard' : name.replaceAll('[^A-Za-z0-9]+', '_');
        value = value.replaceAll('^_+', '').replaceAll('_+$', '');
        if (String.isBlank(value)) value = 'Custom_Dashboard';
        if (value.length() > 80) value = value.substring(0, 80);
        return value + '_' + String.valueOf(Crypto.getRandomInteger());
    }
}