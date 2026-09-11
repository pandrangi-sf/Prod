// AI features for Vital Reports. Two AuraEnabled entry points
// (summarizeDashboard, recommendChartType) plus an isEnabled getter, all
// callable from LWC.
//
// Phase J2: summarizeDashboard now makes a live Anthropic Messages API
// callout (via the Named Credential named on CR_AI_Settings__mdt.Default)
// when the provider is Anthropic and a credential is configured. It feeds
// Claude a token-bounded view of the dashboard's latest run results behind a
// guard-railed system prompt that forbids citing any value not present in the
// data. When AI is on but no credential is set yet, it falls back to the J1
// sample so the panel still renders. recommendChartType remains the J1
// heuristic (no live consumer yet).
public with sharing class CR_AIService {

    private static final String ANTHROPIC_VERSION = '2023-06-01';
    private static final Integer CONTEXT_CHAR_CAP = 12000;
    private static final Integer MAX_ROWS_PER_TILE = 12;
    private static final Integer DEFAULT_MAX_TOKENS = 1024;
    private static final String DEFAULT_MODEL = 'claude-sonnet-4-6';

    public class AISummary {
        @AuraEnabled public String heading { get; set; }
        @AuraEnabled public String body { get; set; }
        @AuraEnabled public Boolean isStub { get; set; }
    }

    public class ChartRecommendation {
        @AuraEnabled public String chartType { get; set; }
        @AuraEnabled public String reason { get; set; }
        @AuraEnabled public Boolean isStub { get; set; }
    }

    // ---- Feature gate ----
    @AuraEnabled(cacheable=true)
    public static Boolean isEnabled() {
        CR_AI_Settings__mdt cfg = getSettings();
        return cfg != null && cfg.Provider__c != null && cfg.Provider__c != 'Disabled';
    }

    // Tests can't insert Custom Metadata, so they inject a settings record
    // here to exercise the enabled/live paths. Null in all real contexts.
    @TestVisible
    private static CR_AI_Settings__mdt settingsOverride;

    @TestVisible
    private static CR_AI_Settings__mdt getSettings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        // Prefer the runtime-editable CR_AI_Provider__c object record (managed
        // via the Manage AI Providers tab). Synthesize a CMT instance from it
        // so every caller continues to use the same shape. Falls back to the
        // legacy CR_AI_Settings__mdt 'Default' record for orgs that haven't
        // seeded the object yet — keeps the dashboard AI panel working
        // through the cut-over without a flag day.
        List<CR_AI_Provider__c> objRows = [
            SELECT Provider__c, Model__c, Max_Tokens__c, Named_Credential_Name__c
            FROM CR_AI_Provider__c
            WHERE Is_Active__c = true
            ORDER BY Is_Default__c DESC, LastModifiedDate DESC
            LIMIT 1
        ];
        if (!objRows.isEmpty()) {
            return new CR_AI_Settings__mdt(
                DeveloperName = 'Default',
                Provider__c = objRows[0].Provider__c,
                Model__c = objRows[0].Model__c,
                Max_Tokens__c = objRows[0].Max_Tokens__c,
                Named_Credential__c = objRows[0].Named_Credential_Name__c
            );
        }
        List<CR_AI_Settings__mdt> rows = [
            SELECT DeveloperName, Provider__c, Model__c, Max_Tokens__c, Named_Credential__c
            FROM CR_AI_Settings__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    // ---- Public entry points ----
    @AuraEnabled
    public static AISummary summarizeDashboard(Id dashboardId) {
        if (dashboardId == null) {
            throw new AuraHandledException('Dashboard id is required.');
        }
        if (!isEnabled()) {
            throw new AuraHandledException('AI features are disabled in this org. Enable via CR_AI_Settings.Default.Provider__c.');
        }
        Dashboard__c d = loadDashboardForContext(dashboardId);

        // isEnabled() guarantees Provider == 'Anthropic' at this point. If no
        // Named Credential is configured yet, keep the J1 sample so the panel
        // still renders something useful while setup is finished.
        CR_AI_Settings__mdt cfg = getSettings();
        if (String.isBlank(cfg.Named_Credential__c)) {
            return buildStubSummary(d);
        }

        String dataContext = buildDashboardContext(dashboardId);
        if (String.isBlank(dataContext)) {
            AISummary empty = new AISummary();
            empty.heading = 'Summary of "' + d.Name + '"';
            empty.body = '<p>There is no completed run data to summarize yet. Run the dashboard, then ask for a summary.</p>';
            empty.isStub = false;
            return empty;
        }

        String narrative = callAnthropic(
            cfg,
            buildSummarySystemPrompt(),
            'Dashboard: ' + d.Name + '\n\n' + dataContext + '\n\nWrite the summary now.'
        );
        AISummary s = new AISummary();
        s.heading = 'Summary of "' + d.Name + '"';
        s.body = narrative;
        s.isStub = false;
        return s;
    }

    @AuraEnabled
    public static ChartRecommendation recommendChartType(Id reportDefinitionId, String currentType) {
        if (reportDefinitionId == null) {
            throw new AuraHandledException('Report id is required.');
        }
        if (!isEnabled()) {
            throw new AuraHandledException('AI features are disabled in this org. Enable via CR_AI_Settings.Default.Provider__c.');
        }
        // Phase J1: rule-based stub so the UI hint renders sensibly even
        // without Claude wired up. Phase J2 calls Claude with the report's
        // column metadata + sample row and asks for a recommendation.
        return buildStubChartRecommendation(currentType);
    }

    // ---- Stub builders (J1) ----
    @TestVisible
    private static Dashboard__c loadDashboardForContext(Id dashboardId) {
        List<Dashboard__c> rows = [
            SELECT Id, Name, Folder__c, Category__c, Description__c,
                   (SELECT Id FROM Dashboard_Components__r LIMIT 50)
            FROM Dashboard__c WHERE Id = :dashboardId LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Dashboard not found: ' + dashboardId);
        }
        return rows[0];
    }

    @TestVisible
    private static AISummary buildStubSummary(Dashboard__c d) {
        Integer componentCount = d.Dashboard_Components__r == null ? 0 : d.Dashboard_Components__r.size();
        AISummary s = new AISummary();
        s.heading = 'Summary of "' + d.Name + '"';
        s.body =
            '<p><em>[Sample response — Phase J2 will replace this with a live Claude summary.]</em></p>'
            + '<p>This dashboard has <strong>' + componentCount + '</strong> component'
            + (componentCount == 1 ? '' : 's')
            + (String.isBlank(d.Folder__c) ? '' : ' in the <strong>' + d.Folder__c + '</strong> folder')
            + '.</p>'
            + (String.isBlank(d.Description__c)
                ? '<p>No description was set. Add one via the gear icon to give viewers context.</p>'
                : '<p><strong>Description:</strong> ' + d.Description__c + '</p>')
            + '<p>When Phase J2 is enabled, this section will contain a narrative summary of the actual tile values: peaks, dips, totals, anomalies. The framework will pass the latest Dashboard_Run results to Claude along with a guard-railed system prompt that only allows citation of numbers present in the data.</p>';
        s.isStub = true;
        return s;
    }

    @TestVisible
    private static ChartRecommendation buildStubChartRecommendation(String currentType) {
        // Lightweight heuristic so the J1 hint is at least directionally
        // useful: nudge the user toward bar if they're on auto, toward
        // metric if they're on table (most reports with 1 row chart better
        // as a metric), and otherwise validate their current pick.
        ChartRecommendation r = new ChartRecommendation();
        r.isStub = true;
        String lower = (currentType == null ? '' : currentType.toLowerCase());
        if (lower == 'auto' || String.isBlank(lower)) {
            r.chartType = 'bar';
            r.reason = '[Sample] Bar charts work well for most aggregated reports. Phase J2 will infer this from the report\'s column types instead.';
        } else if (lower == 'table') {
            r.chartType = 'metric';
            r.reason = '[Sample] Reports with a single aggregate row read better as a metric tile. Phase J2 will check the actual row count before suggesting this.';
        } else {
            r.chartType = lower;
            r.reason = '[Sample] Your current "' + currentType + '" pick looks reasonable. Phase J2 will compare against the data shape and confirm or suggest alternatives.';
        }
        return r;
    }

    // ---- Live Anthropic integration (J2) ----

    @TestVisible
    private static String buildSummarySystemPrompt() {
        return 'You are a reporting assistant embedded in a Salesforce BI tool called Vital Reports. '
            + 'You write a concise executive summary of the data from one dashboard run. '
            + 'STRICT RULES: only state numbers and facts that appear in the provided data; '
            + 'never invent, estimate, or extrapolate values; if the data is insufficient to say something, omit it. '
            + 'Highlight the largest values, notable totals, and any obvious outliers across the tiles. '
            + 'Keep it short — at most 4 sentences or 4 bullet points. '
            + 'Output simple HTML using only <p>, <ul>, <li>, and <strong> tags. '
            + 'Do not use headings, markdown, or code fences.';
    }

    // Compact, token-bounded text view of the dashboard's most recent run:
    // per tile, the columns, totals, and a capped sample of rows. Returns null
    // when there is no run or no tile carries usable result data.
    @TestVisible
    private static String buildDashboardContext(Id dashboardId) {
        List<Dashboard_Run__c> runs = [
            SELECT Id FROM Dashboard_Run__c
            WHERE Dashboard__c = :dashboardId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            return null;
        }
        List<Dashboard_Component_Run__c> compRuns = [
            SELECT Dashboard_Component__r.Name, Status__c, Row_Count__c, Result_JSON__c
            FROM Dashboard_Component_Run__c
            WHERE Dashboard_Run__c = :runs[0].Id
            ORDER BY CreatedDate, Id
        ];
        List<String> blocks = new List<String>();
        Integer total = 0;
        Integer idx = 0;
        for (Dashboard_Component_Run__c cr : compRuns) {
            idx++;
            if (total > CONTEXT_CHAR_CAP) {
                break;
            }
            String label = (cr.Dashboard_Component__r != null && cr.Dashboard_Component__r.Name != null)
                ? cr.Dashboard_Component__r.Name
                : ('Tile ' + idx);
            String block = renderComponentBlock(label, cr);
            if (block == null) {
                continue;
            }
            blocks.add(block);
            total += block.length();
        }
        return blocks.isEmpty() ? null : String.join(blocks, '\n\n');
    }

    @TestVisible
    private static String renderComponentBlock(String label, Dashboard_Component_Run__c cr) {
        if (String.isBlank(cr.Result_JSON__c)) {
            return null;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(cr.Result_JSON__c);
        } catch (Exception e) {
            return null;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            return null;
        }
        Map<String, Object> result = (Map<String, Object>) parsed;

        Integer rowCount = (cr.Row_Count__c == null) ? 0 : cr.Row_Count__c.intValue();
        List<String> lines = new List<String>{
            'Tile: ' + label + ' (' + rowCount + ' rows, status ' + cr.Status__c + ')'
        };

        List<String> colKeys = new List<String>();
        List<String> colLabels = new List<String>();
        if (result.get('columns') instanceof List<Object>) {
            for (Object col : (List<Object>) result.get('columns')) {
                if (col instanceof Map<String, Object>) {
                    Map<String, Object> cm = (Map<String, Object>) col;
                    String key = String.valueOf(cm.get('key'));
                    colKeys.add(key);
                    colLabels.add(cm.get('label') != null ? String.valueOf(cm.get('label')) : key);
                }
            }
        }
        if (!colLabels.isEmpty()) {
            lines.add('Columns: ' + String.join(colLabels, ', '));
        }

        if (result.get('totals') instanceof Map<String, Object>) {
            Map<String, Object> totals = (Map<String, Object>) result.get('totals');
            List<String> totalParts = new List<String>();
            for (String k : totals.keySet()) {
                totalParts.add(k + '=' + String.valueOf(totals.get(k)));
            }
            if (!totalParts.isEmpty()) {
                lines.add('Totals: ' + String.join(totalParts, ', '));
            }
        }

        if (result.get('rows') instanceof List<Object>) {
            List<Object> rows = (List<Object>) result.get('rows');
            List<String> rowLines = new List<String>();
            Integer shown = 0;
            for (Object ro : rows) {
                if (shown >= MAX_ROWS_PER_TILE) {
                    break;
                }
                if (!(ro instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> rm = (Map<String, Object>) ro;
                List<String> cells = new List<String>();
                List<String> keys = colKeys.isEmpty() ? new List<String>(rm.keySet()) : colKeys;
                for (String ck : keys) {
                    cells.add(ck + ': ' + String.valueOf(rm.get(ck)));
                }
                rowLines.add('- ' + String.join(cells, ', '));
                shown++;
            }
            if (!rowLines.isEmpty()) {
                lines.add('Rows:');
                lines.addAll(rowLines);
                if (rows.size() > shown) {
                    lines.add('- (… ' + (rows.size() - shown) + ' more rows omitted)');
                }
            }
        }

        // Header line only means there was nothing worth sending.
        return lines.size() <= 1 ? null : String.join(lines, '\n');
    }

    @TestVisible
    private static String callAnthropic(CR_AI_Settings__mdt cfg, String systemPrompt, String userContent) {
        Integer maxTokens = (cfg.Max_Tokens__c == null) ? DEFAULT_MAX_TOKENS : cfg.Max_Tokens__c.intValue();
        String model = String.isBlank(cfg.Model__c) ? DEFAULT_MODEL : cfg.Model__c;

        // cache_control on the (stable) system block lets the provider reuse a
        // prompt-cache entry across calls, cutting cost and latency.
        Map<String, Object> body = new Map<String, Object>{
            'model' => model,
            'max_tokens' => maxTokens,
            'system' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => systemPrompt,
                    'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' }
                }
            },
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => userContent }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.Named_Credential__c + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-version', ANTHROPIC_VERSION);
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        Integer status = res.getStatusCode();
        if (status < 200 || status >= 300) {
            throw new AuraHandledException('AI provider returned HTTP ' + status + ': ' + truncate(res.getBody(), 300));
        }
        return extractText(res.getBody());
    }

    @TestVisible
    private static String extractText(String responseBody) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            if (root.get('content') instanceof List<Object>) {
                List<String> parts = new List<String>();
                for (Object blk : (List<Object>) root.get('content')) {
                    if (blk instanceof Map<String, Object>) {
                        Map<String, Object> bm = (Map<String, Object>) blk;
                        if ('text'.equals(bm.get('type')) && bm.get('text') != null) {
                            parts.add(String.valueOf(bm.get('text')));
                        }
                    }
                }
                if (!parts.isEmpty()) {
                    return String.join(parts, '\n');
                }
            }
        } catch (Exception e) {
            // fall through to the generic error below
        }
        throw new AuraHandledException('AI provider returned an unrecognized response.');
    }

    private static String truncate(String s, Integer max) {
        if (s == null) {
            return '';
        }
        return s.length() <= max ? s : s.substring(0, max);
    }
}