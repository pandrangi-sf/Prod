@isTest
private class CR_AIService_Test {

    @isTest
    static void isEnabledReflectsProviderSetting() {
        // The Default record in the customMetadata folder ships with
        // Provider=Disabled. isEnabled() should return false in qa/UAT/prod
        // until an admin flips it.
        Test.startTest();
        Boolean enabled = CR_AIService.isEnabled();
        Test.stopTest();
        System.assertEquals(false, enabled, 'Provider defaults to Disabled; AI must be off out of the box.');
    }

    @isTest
    static void summarizeDashboardRejectsWhenDisabled() {
        Dashboard__c d = new Dashboard__c(
            Name = 'AI Test Disabled',
            Developer_Name__c = 'AI_Test_Disabled_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;

        Boolean threw = false;
        Test.startTest();
        try {
            CR_AIService.summarizeDashboard(d.Id);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'Disabled provider should reject the call.');
    }

    @isTest
    static void summarizeDashboardRejectsNullId() {
        Boolean threw = false;
        Test.startTest();
        try {
            CR_AIService.summarizeDashboard(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'Null id should throw before checking provider.');
    }

    @isTest
    static void recommendChartTypeRejectsWhenDisabled() {
        // Synthesize a Report_Definition__c via the existing save endpoint
        // so we have a valid id to pass — the stub doesn't actually load it.
        String reportJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Id' } },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        Id rId = CR_ReportDefinitionService.saveReport(
            null, 'AI Test Report ' + String.valueOf(Crypto.getRandomInteger()),
            'Account_AdHoc', reportJson, 'Tests', 'Unit', false, null, null
        );

        Boolean threw = false;
        Test.startTest();
        try {
            CR_AIService.recommendChartType(rId, 'bar');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'Disabled provider should reject chart-type calls too.');
    }

    @isTest
    static void buildStubSummaryRendersBasicContext() {
        // Direct call to the @TestVisible builder so we exercise the stub
        // even though the public path is gated by Provider=Disabled.
        Dashboard__c d = new Dashboard__c(
            Name = 'Stub Test Dashboard',
            Folder__c = 'AI Tests',
            Description__c = 'Used to verify stub formatting',
            Developer_Name__c = 'Stub_Test_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;

        Test.startTest();
        CR_AIService.AISummary s = CR_AIService.buildStubSummary(d);
        Test.stopTest();

        System.assertEquals(true, s.isStub, 'J1 stubs must self-identify');
        System.assert(s.heading.contains('Stub Test Dashboard'), 'Heading should include the dashboard name');
        System.assert(s.body.contains('Sample response'), 'Body should mark itself as a sample');
        System.assert(s.body.contains('Used to verify stub formatting'), 'Body should include the description');
    }

    @isTest
    static void buildStubChartRecommendationBranchesCorrectly() {
        Test.startTest();
        CR_AIService.ChartRecommendation autoRec  = CR_AIService.buildStubChartRecommendation('auto');
        CR_AIService.ChartRecommendation blankRec = CR_AIService.buildStubChartRecommendation('');
        CR_AIService.ChartRecommendation nullRec  = CR_AIService.buildStubChartRecommendation(null);
        CR_AIService.ChartRecommendation tableRec = CR_AIService.buildStubChartRecommendation('table');
        CR_AIService.ChartRecommendation passRec  = CR_AIService.buildStubChartRecommendation('line');
        Test.stopTest();

        System.assertEquals('bar', autoRec.chartType,  'auto should nudge to bar');
        System.assertEquals('bar', blankRec.chartType, 'blank should nudge to bar');
        System.assertEquals('bar', nullRec.chartType,  'null should nudge to bar');
        System.assertEquals('metric', tableRec.chartType, 'table should nudge to metric');
        System.assertEquals('line', passRec.chartType, 'Existing valid types should pass through');
        System.assertEquals(true, autoRec.isStub, 'J1 stubs must self-identify');
    }

    // ---- J2 live-callout paths ----

    private class AnthropicMock implements HttpCalloutMock {
        private Integer status;
        private String body;
        AnthropicMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            System.assert(req.getEndpoint().startsWith('callout:Anthropic_API/v1/messages'),
                'Should call the configured Named Credential. Got: ' + req.getEndpoint());
            System.assertEquals('2023-06-01', req.getHeader('anthropic-version'),
                'anthropic-version header is required.');
            System.assert(req.getBody().contains('cache_control'),
                'System prompt should be sent with prompt caching enabled.');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }

    private static void enableAnthropic(String namedCredential) {
        CR_AIService.settingsOverride = new CR_AI_Settings__mdt(
            Provider__c = 'Anthropic',
            Model__c = 'claude-sonnet-4-6',
            Max_Tokens__c = 512,
            Named_Credential__c = namedCredential
        );
    }

    private static Dashboard__c dashboardWithRunData(String name) {
        Dashboard__c d = new Dashboard__c(
            Name = name,
            Developer_Name__c = name.replaceAll('[^a-zA-Z0-9]', '_') + '_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;
        Dashboard_Component__c c = new Dashboard_Component__c(Name = 'Pipeline by Stage', Dashboard__c = d.Id);
        insert c;
        Dashboard_Run__c run = new Dashboard_Run__c(Dashboard__c = d.Id, Status__c = 'Complete', Completed_At__c = Datetime.now());
        insert run;
        String resultJson = JSON.serialize(new Map<String, Object>{
            'columns' => new List<Object>{
                new Map<String, Object>{ 'key' => 'stage', 'label' => 'Stage' },
                new Map<String, Object>{ 'key' => 'amt', 'label' => 'Amount', 'numeric' => true }
            },
            'rows' => new List<Object>{
                new Map<String, Object>{ 'stage' => 'Prospecting', 'amt' => 1000 },
                new Map<String, Object>{ 'stage' => 'Closed Won', 'amt' => 5000 }
            },
            'totals' => new Map<String, Object>{ 'amt' => 6000 },
            'rowCount' => 2
        });
        insert new Dashboard_Component_Run__c(
            Dashboard_Run__c = run.Id,
            Dashboard_Component__c = c.Id,
            Status__c = 'Complete',
            Row_Count__c = 2,
            Result_JSON__c = resultJson
        );
        return d;
    }

    @isTest
    static void summarizeDashboardLivePathReturnsNarrative() {
        enableAnthropic('Anthropic_API');
        Dashboard__c d = dashboardWithRunData('AI Live');
        Test.setMock(HttpCalloutMock.class, new AnthropicMock(
            200, '{"content":[{"type":"text","text":"<p>Closed Won leads at 5000.</p>"}]}'
        ));

        Test.startTest();
        CR_AIService.AISummary s = CR_AIService.summarizeDashboard(d.Id);
        Test.stopTest();

        System.assertEquals(false, s.isStub, 'Live path must not be flagged as a stub.');
        System.assert(s.body.contains('Closed Won leads at 5000'), 'Body should carry the model text. Got: ' + s.body);
    }

    @isTest
    static void summarizeDashboardFallsBackToStubWithoutNamedCredential() {
        enableAnthropic(null);
        Dashboard__c d = new Dashboard__c(
            Name = 'AI NoNC',
            Developer_Name__c = 'AI_NoNC_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;

        Test.startTest();
        CR_AIService.AISummary s = CR_AIService.summarizeDashboard(d.Id);
        Test.stopTest();

        System.assertEquals(true, s.isStub, 'With AI on but no Named Credential, fall back to the J1 sample.');
    }

    @isTest
    static void summarizeDashboardWithoutRunDataAsksToRunFirst() {
        enableAnthropic('Anthropic_API');
        Dashboard__c d = new Dashboard__c(
            Name = 'AI NoRun',
            Developer_Name__c = 'AI_NoRun_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;

        Test.startTest();
        CR_AIService.AISummary s = CR_AIService.summarizeDashboard(d.Id);
        Test.stopTest();

        System.assertEquals(false, s.isStub, 'No-data response is informational, not a stub.');
        System.assert(s.body.toLowerCase().contains('run the dashboard'),
            'Should prompt the user to run the dashboard first. Got: ' + s.body);
    }

    @isTest
    static void summarizeDashboardSurfacesProviderError() {
        enableAnthropic('Anthropic_API');
        Dashboard__c d = dashboardWithRunData('AI Err');
        Test.setMock(HttpCalloutMock.class, new AnthropicMock(
            401, '{"error":{"message":"invalid x-api-key"}}'
        ));

        Boolean threw = false;
        Test.startTest();
        try {
            CR_AIService.summarizeDashboard(d.Id);
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'A non-2xx provider response should surface as an error.');
    }
}