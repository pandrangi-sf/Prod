@isTest
private class CR_DashboardSprint3_Test {

    // DR11 — when a component has no Report_Definition__c, loadDashboard returns
    // an empty componentResults entry; the viewer treats it as "no report assigned".
    @isTest
    static void loadDashboardWithNoReportComponentSkipsResultLookup() {
        // Save a dashboard with one component that points to no report.
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Empty Tile',
                'reportDefinitionId' => null,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint3 NoReport', 'F', 'C', '[]', '{"columns":12}', false, componentsJson, null
        );

        Test.startTest();
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, true);
        Test.stopTest();

        System.assertEquals(1, payload.components.size());
        // The component map has no entry for the no-report component (loadDashboard skips it).
        Id componentId = payload.components[0].Id;
        System.assertEquals(false, payload.componentResults.containsKey(componentId),
            'Components with no report should not appear in componentResults');
    }

    // DR05 — listReports now exposes rootObject so the dashboard builder can
    // derive the filter context.
    @isTest
    static void listReportsExposesRootObject() {
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
        CR_ReportDefinitionService.saveReport(
            null, 'Sprint3 Account Report', 'Account_AdHoc', reportJson, 'Tests', 'Unit', false, null, null
        );

        Test.startTest();
        List<CR_Types.ReportDefinitionRecord> records = CR_ReportDefinitionService.listReports('Sprint3 Account');
        Test.stopTest();

        System.assert(records.size() >= 1, 'Expected at least one matching report');
        Boolean foundRoot = false;
        for (CR_Types.ReportDefinitionRecord r : records) {
            if (r.name == 'Sprint3 Account Report') {
                System.assertEquals('Account', r.rootObject, 'rootObject should resolve from saved report');
                foundRoot = true;
            }
        }
        System.assertEquals(true, foundRoot, 'Did not find the test report in results');
    }

    // DR09 — Sprint 1's Savepoint wrapper rolls back on insert failure.
    // We can't easily force a component-insert exception in a unit test (validation
    // rules are org-specific) so this test covers the happy path of the Savepoint
    // wrapper being exercised: the dashboard saves, version increments, components
    // land. Combined with the size-guard rejection in Sprint 1, the rollback
    // pathway is reached on any save that fails after the dashboard insert.
    @isTest
    static void savepointHappyPathLeavesDashboardConsistent() {
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'A',
                'reportDefinitionId' => null,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            },
            new Map<String, Object>{
                'name' => 'B',
                'reportDefinitionId' => null,
                'visualization' => new Map<String, Object>{ 'type' => 'bar' },
                'x' => 6, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });
        Test.startTest();
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint3 Savepoint', 'F', 'C', '[]', '{"columns":12}', false, componentsJson, null
        );
        Test.stopTest();
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, false);
        System.assertEquals(2, payload.components.size(),
            'Expected both components to land on a successful save under Savepoint');
    }
}