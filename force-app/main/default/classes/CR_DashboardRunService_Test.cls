@IsTest
private class CR_DashboardRunService_Test {
    @IsTest
    static void asyncRunStoresBoundedComponentResults() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        Dashboard__c dashboard = createDashboard('Async Run Dashboard', '[]');
        insert new Dashboard_Component__c(
            Name = 'Pipeline',
            Dashboard__c = dashboard.Id,
            Report_Definition__c = report.Id,
            Visualization_JSON__c = '{"type":"table"}',
            Position_X__c = 0,
            Position_Y__c = 0,
            Width__c = 6,
            Height__c = 3
        );

        // The component run executes an FLS-enforced report; run it as a provisioned admin.
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            Id runId = CR_DashboardRunService.enqueueRun(dashboard.Id, false);
            Test.stopTest();

            Dashboard_Run__c run = [
                SELECT Status__c, Completed_Component_Count__c, Failed_Component_Count__c
                FROM Dashboard_Run__c
                WHERE Id = :runId
            ];
            System.assertEquals('Complete', run.Status__c);
            System.assertEquals(1, run.Completed_Component_Count__c);
            System.assertEquals(0, run.Failed_Component_Count__c);

            CR_DashboardRunService.RunPayload payload = CR_DashboardRunService.getRun(runId);
            System.assertEquals(1, payload.componentRuns.size());
            System.assertEquals(true, payload.componentResults.containsKey(payload.componentRuns[0].Id));
            System.assertNotEquals(null, payload.componentResults.get(payload.componentRuns[0].Id).rowCount);
            System.assert(payload.componentRuns[0].Result_JSON__c.length() <= 120000);
        }
    }

    @IsTest
    static void asyncRunRejectsTooManyComponents() {
        Dashboard__c dashboard = createDashboard('Too Many Components', '[]');
        List<Dashboard_Component__c> components = new List<Dashboard_Component__c>();
        for (Integer i = 0; i < 13; i++) {
            components.add(new Dashboard_Component__c(
                Name = 'Component ' + i,
                Dashboard__c = dashboard.Id,
                Visualization_JSON__c = '{"type":"table"}',
                Position_X__c = 0,
                Position_Y__c = i,
                Width__c = 6,
                Height__c = 3
            ));
        }
        insert components;

        Boolean threw = false;
        try {
            CR_DashboardRunService.enqueueRun(dashboard.Id, false);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Expected too many components to be rejected.');
    }

    @IsTest
    static void dashboardRunWithMissingReportFailsComponentOnly() {
        Dashboard__c dashboard = createDashboard('Missing Report Dashboard', '[]');
        insert new Dashboard_Component__c(
            Name = 'Unassigned',
            Dashboard__c = dashboard.Id,
            Visualization_JSON__c = '{"type":"table"}',
            Position_X__c = 0,
            Position_Y__c = 0,
            Width__c = 6,
            Height__c = 3
        );

        Test.startTest();
        Id runId = CR_DashboardRunService.enqueueRun(dashboard.Id, true);
        Test.stopTest();

        Dashboard_Run__c run = [
            SELECT Status__c, Failed_Component_Count__c, Is_Snapshot__c
            FROM Dashboard_Run__c
            WHERE Id = :runId
        ];
        System.assertEquals('Failed', run.Status__c);
        System.assertEquals(1, run.Failed_Component_Count__c);
        System.assertEquals(true, run.Is_Snapshot__c);
    }

    @IsTest
    static void listSnapshotsReturnsOnlySnapshotRuns() {
        Dashboard__c dashboard = createDashboard('Snapshot Listing Dashboard', '[]');

        insert new List<Dashboard_Run__c>{
            new Dashboard_Run__c(Dashboard__c = dashboard.Id, Status__c = 'Complete', Is_Snapshot__c = true),
            new Dashboard_Run__c(Dashboard__c = dashboard.Id, Status__c = 'Complete', Is_Snapshot__c = false),
            new Dashboard_Run__c(Dashboard__c = dashboard.Id, Status__c = 'Complete', Is_Snapshot__c = true)
        };

        List<Dashboard_Run__c> snapshots = CR_DashboardRunService.listSnapshots(dashboard.Id, 10);
        System.assertEquals(2, snapshots.size(), 'Only Is_Snapshot__c = true rows should be returned.');
        for (Dashboard_Run__c run : snapshots) {
            System.assertEquals(true, run.Is_Snapshot__c);
        }

        System.assertEquals(0, CR_DashboardRunService.listSnapshots(null, 10).size(),
            'Null dashboard id should short-circuit to an empty list.');
    }

    private static Dashboard__c createDashboard(String name, String filterJson) {
        Dashboard__c dashboard = new Dashboard__c(
            Name = name,
            Developer_Name__c = name.replaceAll('[^A-Za-z0-9]+', '_'),
            Folder__c = 'Tests',
            Category__c = 'Unit',
            Filter_JSON__c = filterJson,
            Layout_JSON__c = '{"columns":12}',
            Is_Public__c = true,
            Version__c = 1
        );
        insert dashboard;
        return dashboard;
    }
}