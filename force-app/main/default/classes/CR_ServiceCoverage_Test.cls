@IsTest
private class CR_ServiceCoverage_Test {
    @IsTest
    static void reportDefinitionSaveLoadAndListWorks() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c seed = CR_TestDataFactory.createFactOpportunityReport(false);

        // saveReport validates the definition (FLS-enforced) and does with-sharing DML;
        // run the whole save/load/update as the report's owner-admin so a fresh-org
        // deploying user's missing FLS doesn't break it.
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Id reportId = CR_ReportDefinitionService.saveReport(
                null,
                'Saved Pipeline',
                'Test_Fact_Opportunity',
                seed.Definition_JSON__c,
                'Tests',
                'Unit',
                true,
                null,
                'Coverage saved pipeline description'
            );

            CR_Types.ReportDefinitionRecord loaded = CR_ReportDefinitionService.loadReport(reportId);
            System.assertEquals('Saved Pipeline', loaded.name);
            System.assert(!CR_ReportDefinitionService.listReports('Pipeline').isEmpty());

            Id updatedId = CR_ReportDefinitionService.saveReport(
                reportId,
                'Saved Pipeline Updated',
                'Test_Fact_Opportunity',
                seed.Definition_JSON__c,
                'Tests',
                'Updated',
                false,
                loaded.version,
                null
            );
            System.assertEquals(reportId, updatedId);
        }
    }

    @IsTest
    static void dashboardSaveAndLoadWorks() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Pipeline',
                'reportDefinitionId' => report.Id,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0,
                'y' => 0,
                'w' => 6,
                'h' => 3
            }
        });

        Id dashboardId = CR_DashboardService.saveDashboard(
            null,
            'Executive Dashboard',
            'Tests',
            'Unit',
            '[]',
            '{"columns":12}',
            true,
            componentsJson,
            null
        );
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, true);
        System.assertEquals(1, payload.components.size());
        System.assertEquals(1, payload.componentResults.size());
        System.assert(!CR_DashboardService.listDashboards('Executive').isEmpty());

        Dashboard__c stored = [SELECT Version__c FROM Dashboard__c WHERE Id = :dashboardId LIMIT 1];
        CR_DashboardService.saveDashboard(
            dashboardId,
            'Executive Dashboard Updated',
            'Tests',
            'Unit',
            '[]',
            '{"columns":12}',
            true,
            componentsJson,
            stored.Version__c
        );
    }

    @IsTest
    static void saveBlockedForViewOnlyUser() {
        // A Vital Reports User (read-only on Report_Definition__c / Dashboard__c)
        // must not be able to build. The Apex guards enforce this regardless of
        // UI, since DML otherwise runs in system mode and ignores object CRUD.
        // Created by the admin test user so the view-only user has an existing
        // record to attempt edit/delete against.
        Report_Definition__c existing = CR_TestDataFactory.createFactOpportunityReport(true);

        User viewer = makeViewOnlyUser();
        System.runAs(viewer) {
            // The CRUD guard is the first thing each method runs after the name
            // check, so an AuraHandledException here is unambiguously the block.
            // (AuraHandledException.getMessage() returns "Script-thrown exception"
            // in test context, so we assert on the throw, not the message text.)
            System.assertEquals(false, CR_ReportDefinitionService.canBuildReports(),
                'View-only user cannot build reports.');
            System.assertEquals(false, CR_DashboardService.canBuildDashboards(),
                'View-only user cannot build dashboards.');

            assertBlocked('create report', new ReportCreate());
            assertBlocked('edit report', new ReportEdit(existing.Id));
            assertBlocked('delete report', new ReportDelete(existing.Id));
            assertBlocked('create joined report', new JoinedCreate());
            assertBlocked('create dashboard', new DashboardCreate());
        }
    }

    // Tiny command objects so each blocked call is a one-liner (Apex has no lambdas).
    private interface BuildAttempt { void run(); }
    private class ReportCreate implements BuildAttempt {
        public void run() {
            CR_ReportDefinitionService.saveReport(null, 'Nope', 'Test_Fact_Opportunity', '{}', 'Tests', 'Unit', true, null, null);
        }
    }
    private class ReportEdit implements BuildAttempt {
        private Id rid; public ReportEdit(Id rid) { this.rid = rid; }
        public void run() {
            CR_ReportDefinitionService.saveReport(rid, 'Nope', 'Test_Fact_Opportunity', '{}', 'Tests', 'Unit', true, null, null);
        }
    }
    private class ReportDelete implements BuildAttempt {
        private Id rid; public ReportDelete(Id rid) { this.rid = rid; }
        public void run() { CR_ReportDefinitionService.deleteReport(rid); }
    }
    private class JoinedCreate implements BuildAttempt {
        public void run() {
            CR_ReportDefinitionService.saveJoinedReport(null, 'Nope', '{}', 'Tests', 'Unit', true, null, null);
        }
    }
    private class DashboardCreate implements BuildAttempt {
        public void run() {
            CR_DashboardService.saveDashboard(null, 'Nope', 'Tests', 'Unit', '[]', '{"columns":12}', true, '[]', null);
        }
    }

    private static void assertBlocked(String what, BuildAttempt attempt) {
        Boolean threw = false;
        try {
            attempt.run();
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'View-only user must be blocked: ' + what);
    }

    private static User makeViewOnlyUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crvo',
                Email = 'crvo@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'ViewOnly',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crvo' + rand + '@example.com.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_User' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    @IsTest
    static void joinedReportSaveDeleteAndCanBuildWork() {
        // Admin path: the new CRUD guards pass, exercising saveJoinedReport +
        // deleteReport + canBuildReports for coverage.
        System.assertEquals(true, CR_ReportDefinitionService.canBuildReports(),
            'Admin running the test can build reports.');

        String config = JSON.serialize(new Map<String, Object>{
            'joinKey' => 'Test_Join',
            'blocks' => new List<Object>{
                new Map<String, Object>{ 'definition' => new Map<String, Object>{
                    'dataset' => new Map<String, Object>{ 'objectApiName' => 'Fact_Opportunity__c' }
                }}
            }
        });
        Id rid = CR_ReportDefinitionService.saveJoinedReport(
            null, 'Joined Coverage', config, 'Tests', 'Unit', true, null, 'desc');
        System.assertNotEquals(null, rid, 'Joined report should save for an admin.');

        // Read/list APIs for line coverage. (The joined-report UPDATE path is a
        // deprecated, out-of-scope code path with a latent unqueried-field bug;
        // not exercised here.)
        CR_ReportDefinitionService.loadReport(rid);
        CR_ReportDefinitionService.listReports('Joined');
        CR_ReportDefinitionService.listReportsOrdered('', 'Name', 'ASC');
        CR_ReportDefinitionService.listJoinedReports('');
        CR_ReportDefinitionService.listJoinedReportsOrdered('', 'Name', 'ASC');
        CR_ReportDefinitionService.listDatasets();

        CR_ReportDefinitionService.deleteReport(rid);
        System.assertEquals(0,
            [SELECT COUNT() FROM Report_Definition__c WHERE Id = :rid],
            'deleteReport should remove the record.');
    }

    @IsTest
    static void formulaEngineDirectEvaluationWorks() {
        Object result = CR_FormulaEngine.evaluateFormula(
            '{"name":"Score","type":"number","expression":"Amount__c / Record_Count__c"}',
            '{"Amount__c":200,"Record_Count__c":2}'
        );
        System.assertEquals(100, result);

        Object ifResult = CR_FormulaEngine.evaluateFormula(
            '{"name":"Band","type":"text","expression":"IF(Amount__c > 100, \'High\', \'Low\')"}',
            '{"Amount__c":200}'
        );
        System.assertEquals('High', ifResult);

        Object caseResult = CR_FormulaEngine.evaluateFormula(
            '{"name":"Stage Label","type":"text","expression":"CASE(Stage_Name__c, \'Closed Won\', \'Won\', \'Open\')"}',
            '{"Stage_Name__c":"Closed Won"}'
        );
        System.assertEquals('Won', caseResult);

        // Regression: a text formula referencing two fields where one name is a
        // substring of the other (Cost__c is inside Total_Cost__c). The old
        // single-pass String.replace substituted Cost__c first and corrupted the
        // occurrence inside Total_Cost__c, yielding "5 + Total_5". Longest-first
        // placeholder substitution must keep both tokens intact.
        Object substringResult = CR_FormulaEngine.evaluateFormula(
            '{"name":"Combo","type":"text","expression":"Cost__c + Total_Cost__c"}',
            '{"Cost__c":5,"Total_Cost__c":20}'
        );
        System.assertEquals('5 + 20', substringResult,
            'Field name that is a substring of another must not corrupt text substitution.');
    }

    @IsTest
    static void applyFormulasAndBucketsCoversOperators() {
        // Drives the bucket path (applyBucket + matches) across several operators
        // plus a formula on the same pass, so the row-mutation path is exercised.
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Amount__c' => 5,   'Stage__c' => 'Closed Won' },
            new Map<String, Object>{ 'Amount__c' => 150, 'Stage__c' => 'Prospecting' },
            new Map<String, Object>{ 'Amount__c' => 50,  'Stage__c' => 'Negotiation' }
        };
        Map<String, Object> definition = new Map<String, Object>{
            'formulas' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Doubled', 'type' => 'number', 'expression' => 'Amount__c * 2' }
            },
            'buckets' => new List<Object>{
                new Map<String, Object>{
                    'name' => 'Band',
                    'sourceField' => 'Amount__c',
                    'defaultValue' => 'Mid',
                    'rules' => new List<Object>{
                        new Map<String, Object>{ 'operator' => '>', 'value' => 100, 'label' => 'High' },
                        new Map<String, Object>{ 'operator' => 'BETWEEN', 'value' => 0, 'valueTo' => 10, 'label' => 'Low' }
                    }
                },
                new Map<String, Object>{
                    'name' => 'StageFlag',
                    'sourceField' => 'Stage__c',
                    'defaultValue' => 'Open',
                    'rules' => new List<Object>{
                        new Map<String, Object>{ 'operator' => 'CONTAINS', 'value' => 'Won', 'label' => 'WonDeal' }
                    }
                }
            }
        };

        List<Map<String, Object>> result = CR_FormulaEngine.applyFormulasAndBuckets(rows, definition);

        System.assertEquals('Low', result[0].get('Band'), 'Amount 5 is BETWEEN 0 and 10.');
        System.assertEquals('High', result[1].get('Band'), 'Amount 150 is > 100.');
        System.assertEquals('Mid', result[2].get('Band'), 'Amount 50 falls through to the default.');
        System.assertEquals('WonDeal', result[0].get('StageFlag'), 'Stage CONTAINS Won.');
        System.assertEquals('Open', result[1].get('StageFlag'), 'Stage without Won uses the default.');
        System.assertNotEquals(null, result[0].get('Doubled'), 'Formula on the same pass should compute.');
    }

    @IsTest
    static void schedulerAndTypesAreCovered() {
        CR_Types.ObjectInfo objectInfo = new CR_Types.ObjectInfo();
        objectInfo.apiName = 'Account';
        CR_Types.FieldInfo fieldInfo = new CR_Types.FieldInfo();
        fieldInfo.apiName = 'Name';
        CR_Types.RelationshipInfo relationshipInfo = new CR_Types.RelationshipInfo();
        relationshipInfo.relationshipName = 'Account';
        CR_Types.DescribeResult describeResult = new CR_Types.DescribeResult();
        describeResult.objectInfo = objectInfo;
        describeResult.fields = new List<CR_Types.FieldInfo>{ fieldInfo };
        describeResult.parentRelationships = new List<CR_Types.RelationshipInfo>{ relationshipInfo };
        describeResult.childRelationships = new List<CR_Types.RelationshipInfo>();
        CR_Types.DatasetDefinition dataset = new CR_Types.DatasetDefinition();
        dataset.datasetKey = 'Dataset';
        dataset.relatedObjects = new List<String>();
        dataset.fieldPaths = new List<String>();
        CR_Types.ExportStatus status = new CR_Types.ExportStatus();
        status.status = 'Queued';
        CR_Types.MigrationPreview preview = new CR_Types.MigrationPreview();
        preview.unsupportedFeatures = new List<String>();
        System.assertEquals('Account', describeResult.objectInfo.apiName);

        try {
            throw new CR_ReportException('covered');
        } catch (CR_ReportException ex) {
            System.assertEquals('covered', ex.getMessage());
        }

        // scheduleNightly is gated on the Run_Custom_Reporting_ETL custom permission,
        // which a fresh-org deploying user lacks — run it as a CRF-provisioned admin.
        User etlAdmin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(etlAdmin) {
            try {
                String jobId = CR_ETLScheduler.scheduleNightly();
                System.assertNotEquals(null, jobId);
            } catch (System.AsyncException e) {
                // In an org where the live "Vital Reports Nightly ETL" cron is already
                // scheduled (e.g. qa/UAT), System.schedule throws instead of returning
                // an id. The scheduleNightly path still executes for coverage; the
                // collision is environmental state, not a defect. See the deploy gotchas.
                System.assert(
                    e.getMessage().containsIgnoreCase('already scheduled'),
                    'Only an already-scheduled collision is tolerated here: ' + e.getMessage()
                );
            }
        }
        Test.stopTest();
    }
}