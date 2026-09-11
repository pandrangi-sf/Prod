public with sharing class CR_DashboardRunService {
    public class RunPayload {
        @AuraEnabled public Dashboard_Run__c run { get; set; }
        @AuraEnabled public List<Dashboard_Component_Run__c> componentRuns { get; set; }
        @AuraEnabled public Map<Id, CR_Types.QueryResult> componentResults { get; set; }
    }

    private class BoundedResult {
        CR_Types.QueryResult result;
        Boolean truncated = false;
    }

    private static final Integer MAX_COMPONENTS_PER_RUN = 12;
    private static final Integer MAX_PREVIEW_ROWS = 200;
    private static final Integer MAX_PREVIEW_COLUMNS = 25;
    private static final Integer MAX_RESULT_JSON_CHARS = 120000;

    // Fires real-time progress events to the Dashboard Viewer over the empApi
    // channel /event/Dashboard_Run_Event__e. Subscribers update their UI without
    // waiting for the polling fallback (which still runs at a slower interval).
    private static void publishRunEvent(Id runId, Id componentRunId, String status, String message) {
        if (runId == null || String.isBlank(status)) {
            return;
        }
        String trimmedMessage = message;
        if (trimmedMessage != null && trimmedMessage.length() > 255) {
            trimmedMessage = trimmedMessage.substring(0, 255);
        }
        try {
            EventBus.publish(new Dashboard_Run_Event__e(
                Dashboard_Run_Id__c = String.valueOf(runId),
                Component_Run_Id__c = componentRunId == null ? null : String.valueOf(componentRunId),
                Status__c = status,
                Message__c = trimmedMessage
            ));
        } catch (Exception ignored) {
            // Event publish failures must not break the run itself; viewer falls back to polling.
        }
    }

    @AuraEnabled
    public static Id enqueueRun(Id dashboardId, Boolean snapshot) {
        if (dashboardId == null) {
            throw new AuraHandledException('Dashboard Id is required.');
        }

        Dashboard__c dashboard = [
            SELECT Id, Name, Filter_JSON__c
            FROM Dashboard__c
            WHERE Id = :dashboardId
            LIMIT 1
        ];

        Integer componentQueryLimit = MAX_COMPONENTS_PER_RUN + 1;
        List<Dashboard_Component__c> components = [
            SELECT Id, Name, Report_Definition__c, Position_X__c, Position_Y__c
            FROM Dashboard_Component__c
            WHERE Dashboard__c = :dashboardId
            ORDER BY Position_Y__c, Position_X__c
            LIMIT :componentQueryLimit
        ];
        if (components.size() > MAX_COMPONENTS_PER_RUN) {
            throw new AuraHandledException(
                'Dashboard async runs support up to ' + MAX_COMPONENTS_PER_RUN
                + ' components at a time. Split this dashboard or remove components before running.'
            );
        }
        if (components.isEmpty()) {
            // Fail fast on click instead of letting the user wait for the queueable
            // to complete and surface a confusing "run complete" message.
            throw new AuraHandledException(
                'This dashboard has no saved components yet. Open it in the Dashboard Builder, add a component, and click Save Dashboard before running.'
            );
        }

        Dashboard_Run__c run = new Dashboard_Run__c(
            Name = safeName(dashboard.Name + ' Run ' + Datetime.now().format('yyyy-MM-dd HH:mm')),
            Dashboard__c = dashboard.Id,
            Status__c = 'Queued',
            Message__c = 'Dashboard run queued.',
            Dashboard_Filters_JSON__c = dashboard.Filter_JSON__c,
            Component_Count__c = components.size(),
            Completed_Component_Count__c = 0,
            Failed_Component_Count__c = 0,
            Is_Snapshot__c = snapshot == true
        );
        insert run;

        List<Dashboard_Component_Run__c> componentRuns = new List<Dashboard_Component_Run__c>();
        for (Dashboard_Component__c component : components) {
            componentRuns.add(new Dashboard_Component_Run__c(
                Name = safeName(component.Name + ' Run'),
                Dashboard_Run__c = run.Id,
                Dashboard_Component__c = component.Id,
                Report_Definition__c = component.Report_Definition__c,
                Status__c = component.Report_Definition__c == null ? 'Failed' : 'Queued',
                Message__c = component.Report_Definition__c == null ? 'No source report is assigned.' : 'Component run queued.',
                Row_Count__c = 0,
                Is_Truncated__c = false
            ));
        }
        if (!componentRuns.isEmpty()) {
            insert componentRuns;
        }

        System.enqueueJob(new DashboardRunQueueable(run.Id));
        return run.Id;
    }

    @AuraEnabled
    public static RunPayload getRun(Id runId) {
        if (runId == null) {
            throw new AuraHandledException('Dashboard Run Id is required.');
        }
        RunPayload payload = new RunPayload();
        payload.run = [
            SELECT Id, Name, Dashboard__c, Dashboard__r.Name, Status__c, Message__c,
                Dashboard_Filters_JSON__c, Started_At__c, Completed_At__c, Component_Count__c,
                Completed_Component_Count__c, Failed_Component_Count__c, Is_Snapshot__c
            FROM Dashboard_Run__c
            WHERE Id = :runId
            LIMIT 1
        ];
        payload.componentRuns = [
            SELECT Id, Name, Dashboard_Run__c, Dashboard_Component__c, Dashboard_Component__r.Name,
                Report_Definition__c, Status__c, Message__c, Result_JSON__c, Row_Count__c,
                Is_Truncated__c, Completed_At__c
            FROM Dashboard_Component_Run__c
            WHERE Dashboard_Run__c = :runId
            ORDER BY CreatedDate, Id
        ];
        payload.componentResults = new Map<Id, CR_Types.QueryResult>();
        for (Dashboard_Component_Run__c componentRun : payload.componentRuns) {
            if (String.isBlank(componentRun.Result_JSON__c)) {
                continue;
            }
            try {
                // Apex's typed JSON.deserialize can't handle Map<String, Object> fields
                // (it throws "Apex Type unsupported in JSON: Object" the moment any
                // generic-Object field appears in the payload). Use the untyped path
                // and rebuild the QueryResult manually so we tolerate any value shape.
                payload.componentResults.put(componentRun.Id, deserializeStoredResult(componentRun.Result_JSON__c));
            } catch (Exception ex) {
                payload.componentResults.put(componentRun.Id, errorResult('Stored result JSON could not be parsed: ' + ex.getMessage()));
            }
        }
        return payload;
    }

    @AuraEnabled(cacheable=true)
    public static List<Dashboard_Run__c> listRecentRuns(Id dashboardId, Integer maxResults) {
        if (dashboardId == null) {
            return new List<Dashboard_Run__c>();
        }
        Integer boundedLimit = Math.min(Math.max(maxResults == null ? 5 : maxResults, 1), 10);
        return [
            SELECT Id, Name, Dashboard__c, Status__c, Message__c, Started_At__c, Completed_At__c,
                Component_Count__c, Completed_Component_Count__c, Failed_Component_Count__c, Is_Snapshot__c
            FROM Dashboard_Run__c
            WHERE Dashboard__c = :dashboardId
            ORDER BY CreatedDate DESC
            LIMIT :boundedLimit
        ];
    }

    // Phase 1 UAT: surface saved snapshots inside the viewer so users don't
    // have to leave the app for the Dashboard Runs tab to re-open one.
    @AuraEnabled(cacheable=true)
    public static List<Dashboard_Run__c> listSnapshots(Id dashboardId, Integer maxResults) {
        if (dashboardId == null) {
            return new List<Dashboard_Run__c>();
        }
        Integer boundedLimit = Math.min(Math.max(maxResults == null ? 20 : maxResults, 1), 50);
        return [
            SELECT Id, Name, Dashboard__c, Status__c, Message__c, Started_At__c, Completed_At__c,
                Component_Count__c, Completed_Component_Count__c, Failed_Component_Count__c, Is_Snapshot__c
            FROM Dashboard_Run__c
            WHERE Dashboard__c = :dashboardId AND Is_Snapshot__c = true
            ORDER BY CreatedDate DESC
            LIMIT :boundedLimit
        ];
    }

    public class DashboardRunQueueable implements Queueable {
        private Id runId;

        public DashboardRunQueueable(Id runId) {
            this.runId = runId;
        }

        public void execute(QueueableContext context) {
            Dashboard_Run__c run = [
                SELECT Id, Status__c, Message__c, Dashboard_Filters_JSON__c, Started_At__c,
                    Completed_At__c, Component_Count__c
                FROM Dashboard_Run__c
                WHERE Id = :runId
                LIMIT 1
            ];

            run.Status__c = 'Running';
            run.Message__c = 'Dashboard run is processing.';
            run.Started_At__c = System.now();
            update run;

            List<Dashboard_Component_Run__c> componentRuns = [
                SELECT Id, Name, Dashboard_Component__c, Dashboard_Component__r.Name, Report_Definition__c,
                    Status__c, Message__c
                FROM Dashboard_Component_Run__c
                WHERE Dashboard_Run__c = :run.Id
                ORDER BY CreatedDate, Id
            ];

            Integer completedCount = 0;
            Integer failedCount = 0;
            Integer truncatedCount = 0;
            for (Dashboard_Component_Run__c componentRun : componentRuns) {
                if (componentRun.Report_Definition__c == null) {
                    failedCount++;
                    componentRun.Status__c = 'Failed';
                    componentRun.Message__c = 'No source report is assigned.';
                    componentRun.Result_JSON__c = JSON.serialize(errorResult(componentRun.Message__c));
                    componentRun.Completed_At__c = System.now();
                    update componentRun;
                    publishRunEvent(run.Id, componentRun.Id, 'Component_Failed', componentRun.Message__c);
                    continue;
                }

                componentRun.Status__c = 'Running';
                componentRun.Message__c = 'Component run is processing.';
                update componentRun;
                publishRunEvent(run.Id, componentRun.Id, 'Component_Running', null);

                try {
                    CR_Types.QueryResult rawResult = CR_QueryEngine.runReportById(
                        componentRun.Report_Definition__c,
                        null,
                        MAX_PREVIEW_ROWS,
                        run.Dashboard_Filters_JSON__c
                    );
                    BoundedResult bounded = boundResult(rawResult);
                    String resultJson = serializeWithinLimit(bounded);

                    componentRun.Result_JSON__c = resultJson;
                    componentRun.Row_Count__c = bounded.result.rowCount == null ? bounded.result.rows.size() : bounded.result.rowCount;
                    componentRun.Is_Truncated__c = bounded.truncated;
                    componentRun.Status__c = bounded.truncated ? 'Truncated' : 'Complete';
                    componentRun.Message__c = bounded.truncated
                        ? 'Preview was capped for safe browser rendering.'
                        : 'Component run complete.';
                    componentRun.Completed_At__c = System.now();
                    update componentRun;
                    publishRunEvent(run.Id, componentRun.Id, 'Component_Complete', componentRun.Message__c);

                    completedCount++;
                    if (bounded.truncated) {
                        truncatedCount++;
                    }
                } catch (Exception ex) {
                    componentRun.Status__c = 'Failed';
                    componentRun.Message__c = truncateText(ex.getMessage(), 1000);
                    componentRun.Result_JSON__c = JSON.serialize(errorResult('Component failed: ' + ex.getMessage()));
                    componentRun.Row_Count__c = 0;
                    componentRun.Is_Truncated__c = false;
                    componentRun.Completed_At__c = System.now();
                    update componentRun;
                    publishRunEvent(run.Id, componentRun.Id, 'Component_Failed', componentRun.Message__c);
                    failedCount++;
                }
            }

            run.Completed_Component_Count__c = completedCount;
            run.Failed_Component_Count__c = failedCount;
            run.Completed_At__c = System.now();
            if (failedCount == componentRuns.size() && !componentRuns.isEmpty()) {
                run.Status__c = 'Failed';
                run.Message__c = 'All dashboard components failed.';
            } else if (failedCount > 0 || truncatedCount > 0) {
                run.Status__c = 'Partial';
                run.Message__c = 'Run finished with ' + failedCount + ' failed and ' + truncatedCount + ' capped component(s).';
            } else {
                run.Status__c = 'Complete';
                run.Message__c = componentRuns.isEmpty()
                    ? 'No components saved on this dashboard yet. Open the Dashboard Builder, add a component, and click Save Dashboard before running.'
                    : 'Dashboard run complete.';
            }
            update run;
            publishRunEvent(run.Id, null, 'Run_' + run.Status__c, run.Message__c);
        }
    }

    private static BoundedResult boundResult(CR_Types.QueryResult rawResult) {
        BoundedResult bounded = new BoundedResult();
        CR_Types.QueryResult result = new CR_Types.QueryResult();
        result.columns = new List<CR_Types.ColumnInfo>();
        result.rows = new List<Map<String, Object>>();
        result.totals = rawResult == null || rawResult.totals == null ? new Map<String, Object>() : rawResult.totals;
        result.groupLevels = rawResult == null || rawResult.groupLevels == null ? new List<String>() : rawResult.groupLevels;
        result.nextPageToken = null;
        result.executedSoql = null;
        result.rowCount = rawResult == null || rawResult.rowCount == null ? 0 : rawResult.rowCount;
        result.aggregateResult = rawResult != null && rawResult.aggregateResult == true;
        result.warnings = rawResult == null || rawResult.warnings == null ? new List<String>() : new List<String>(rawResult.warnings);
        result.errorMessage = rawResult == null ? null : rawResult.errorMessage;

        if (rawResult == null) {
            bounded.result = result;
            return bounded;
        }

        Integer columnLimit = Math.min(rawResult.columns == null ? 0 : rawResult.columns.size(), MAX_PREVIEW_COLUMNS);
        for (Integer i = 0; i < columnLimit; i++) {
            CR_Types.ColumnInfo sourceColumn = rawResult.columns[i];
            CR_Types.ColumnInfo column = new CR_Types.ColumnInfo();
            column.key = sourceColumn.key;
            column.label = sourceColumn.label;
            column.dataType = sourceColumn.dataType;
            column.numeric = sourceColumn.numeric;
            result.columns.add(column);
        }
        if (rawResult.columns != null && rawResult.columns.size() > MAX_PREVIEW_COLUMNS) {
            bounded.truncated = true;
            addWarning(result, 'Preview limited to ' + MAX_PREVIEW_COLUMNS + ' columns.');
        }

        Integer rowLimit = Math.min(rawResult.rows == null ? 0 : rawResult.rows.size(), MAX_PREVIEW_ROWS);
        for (Integer rowIndex = 0; rowIndex < rowLimit; rowIndex++) {
            Map<String, Object> sourceRow = rawResult.rows[rowIndex];
            Map<String, Object> row = new Map<String, Object>();
            for (CR_Types.ColumnInfo column : result.columns) {
                row.put(column.key, sourceRow == null ? null : sourceRow.get(column.key));
            }
            result.rows.add(row);
        }
        if ((rawResult.rows != null && rawResult.rows.size() > MAX_PREVIEW_ROWS) || !String.isBlank(rawResult.nextPageToken)) {
            bounded.truncated = true;
            addWarning(result, 'Preview limited to ' + MAX_PREVIEW_ROWS + ' rows. Use export for full data.');
        }

        bounded.result = result;
        return bounded;
    }

    private static String serializeWithinLimit(BoundedResult bounded) {
        String resultJson = JSON.serialize(bounded.result);
        Boolean addedSizeWarning = false;
        while (resultJson.length() > MAX_RESULT_JSON_CHARS && !bounded.result.rows.isEmpty()) {
            Integer keepRows = Math.max(0, bounded.result.rows.size() / 2);
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            for (Integer i = 0; i < keepRows; i++) {
                rows.add(bounded.result.rows[i]);
            }
            bounded.result.rows = rows;
            bounded.truncated = true;
            if (!addedSizeWarning) {
                addWarning(bounded.result, 'Preview result JSON was reduced to stay within storage limits.');
                addedSizeWarning = true;
            }
            resultJson = JSON.serialize(bounded.result);
        }
        if (resultJson.length() > MAX_RESULT_JSON_CHARS) {
            bounded.truncated = true;
            CR_Types.QueryResult fallback = errorResult('Preview result exceeded the safe storage limit. Use export for full data.');
            fallback.warnings.add('Component data was not stored because the preview exceeded ' + MAX_RESULT_JSON_CHARS + ' characters.');
            bounded.result = fallback;
            resultJson = JSON.serialize(bounded.result);
        }
        return resultJson;
    }

    private static CR_Types.QueryResult errorResult(String message) {
        CR_Types.QueryResult result = new CR_Types.QueryResult();
        result.columns = new List<CR_Types.ColumnInfo>();
        result.rows = new List<Map<String, Object>>();
        result.totals = new Map<String, Object>();
        result.groupLevels = new List<String>();
        result.nextPageToken = null;
        result.executedSoql = null;
        result.rowCount = 0;
        result.aggregateResult = false;
        result.warnings = new List<String>();
        result.errorMessage = truncateText(message, 1000);
        return result;
    }

    /**
     * Reconstruct a CR_Types.QueryResult from JSON without using Apex's typed
     * deserializer. The typed path fails on any payload that has a Map<String, Object>
     * field with mixed value types ("Apex Type unsupported in JSON: Object"). The
     * untyped path always works; we just have to copy fields by name.
     */
    private static CR_Types.QueryResult deserializeStoredResult(String jsonText) {
        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        CR_Types.QueryResult result = new CR_Types.QueryResult();

        // Columns: list of typed ColumnInfo. Build via JSON.serialize → typed deserialize
        // round-trip — ColumnInfo has only scalar fields so the typed deserializer is fine.
        if (raw.get('columns') != null) {
            result.columns = (List<CR_Types.ColumnInfo>) JSON.deserialize(
                JSON.serialize(raw.get('columns')),
                List<CR_Types.ColumnInfo>.class
            );
        } else {
            result.columns = new List<CR_Types.ColumnInfo>();
        }

        // Rows: keep as raw List<Map<String, Object>> — that's what the LWC consumes.
        result.rows = new List<Map<String, Object>>();
        if (raw.get('rows') instanceof List<Object>) {
            for (Object row : (List<Object>) raw.get('rows')) {
                if (row instanceof Map<String, Object>) {
                    result.rows.add((Map<String, Object>) row);
                }
            }
        }

        result.totals = raw.get('totals') instanceof Map<String, Object>
            ? (Map<String, Object>) raw.get('totals')
            : new Map<String, Object>();

        result.groupLevels = new List<String>();
        if (raw.get('groupLevels') instanceof List<Object>) {
            for (Object g : (List<Object>) raw.get('groupLevels')) {
                if (g != null) result.groupLevels.add(String.valueOf(g));
            }
        }

        result.warnings = new List<String>();
        if (raw.get('warnings') instanceof List<Object>) {
            for (Object w : (List<Object>) raw.get('warnings')) {
                if (w != null) result.warnings.add(String.valueOf(w));
            }
        }

        result.nextPageToken = raw.get('nextPageToken') == null ? null : String.valueOf(raw.get('nextPageToken'));
        result.executedSoql = raw.get('executedSoql') == null ? null : String.valueOf(raw.get('executedSoql'));
        result.errorMessage = raw.get('errorMessage') == null ? null : String.valueOf(raw.get('errorMessage'));

        Object rowCountObj = raw.get('rowCount');
        if (rowCountObj instanceof Integer) result.rowCount = (Integer) rowCountObj;
        else if (rowCountObj instanceof Decimal) result.rowCount = ((Decimal) rowCountObj).intValue();
        else if (rowCountObj instanceof Long) result.rowCount = ((Long) rowCountObj).intValue();
        else result.rowCount = 0;

        Object aggObj = raw.get('aggregateResult');
        result.aggregateResult = aggObj instanceof Boolean ? (Boolean) aggObj : false;

        return result;
    }

    private static void addWarning(CR_Types.QueryResult result, String warning) {
        if (result.warnings == null) {
            result.warnings = new List<String>();
        }
        result.warnings.add(warning);
    }

    private static String safeName(String value) {
        String name = String.isBlank(value) ? 'Dashboard Run' : value.trim();
        return name.length() > 80 ? name.substring(0, 80) : name;
    }

    private static String truncateText(String value, Integer maxLength) {
        if (String.isBlank(value) || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, Math.max(0, maxLength - 3)) + '...';
    }
}