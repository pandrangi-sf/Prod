@isTest
private class CR_DashboardSprint1_Test {

    @isTest
    static void saveDashboardRejectsBlankName() {
        Test.startTest();
        try {
            CR_DashboardService.saveDashboard(
                null, '', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
            );
            System.assert(false, 'Expected AuraHandledException for blank name');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void saveDashboardInsertsAndIncrementsVersion() {
        Test.startTest();
        Id newId = CR_DashboardService.saveDashboard(
            null, 'Sprint1 Dash', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        System.assertNotEquals(null, newId);

        Dashboard__c stored = [SELECT Version__c FROM Dashboard__c WHERE Id = :newId LIMIT 1];
        System.assertEquals(1, stored.Version__c);

        // Update with matching version succeeds and increments.
        CR_DashboardService.saveDashboard(
            newId, 'Sprint1 Dash v2', 'F', 'C', '[]', '{"columns":12}', false, '[]', stored.Version__c
        );
        Dashboard__c afterUpdate = [SELECT Version__c FROM Dashboard__c WHERE Id = :newId LIMIT 1];
        System.assertEquals(2, afterUpdate.Version__c);
        Test.stopTest();
    }

    @isTest
    static void saveDashboardRejectsStaleVersion() {
        Id newId = CR_DashboardService.saveDashboard(
            null, 'Sprint1 Stale', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        Dashboard__c stored = [SELECT Version__c FROM Dashboard__c WHERE Id = :newId LIMIT 1];
        Decimal staleVersion = stored.Version__c - 5;

        Test.startTest();
        try {
            CR_DashboardService.saveDashboard(
                newId, 'Sprint1 Stale Updated', 'F', 'C', '[]', '{"columns":12}', false, '[]', staleVersion
            );
            System.assert(false, 'Expected AuraHandledException for stale version');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void saveDashboardRejectsDuplicateName() {
        Id firstId = CR_DashboardService.saveDashboard(
            null, 'Duplicate Dash', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        System.assertNotEquals(null, firstId);

        Test.startTest();
        try {
            CR_DashboardService.saveDashboard(
                null, 'Duplicate Dash', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
            );
            System.assert(false, 'Expected AuraHandledException for duplicate name');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void saveDashboardAllowsRenameToNewName() {
        Id existingId = CR_DashboardService.saveDashboard(
            null, 'Original Dash Name', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        Dashboard__c stored = [SELECT Version__c FROM Dashboard__c WHERE Id = :existingId LIMIT 1];

        // Renaming to a name not in use must succeed: the duplicate check excludes
        // the dashboard being updated from the conflict query.
        Test.startTest();
        CR_DashboardService.saveDashboard(
            existingId, 'Renamed Dash Title', 'F', 'C', '[]', '{"columns":12}', false, '[]', stored.Version__c
        );
        Test.stopTest();

        Dashboard__c reloaded = [SELECT Name FROM Dashboard__c WHERE Id = :existingId LIMIT 1];
        System.assertEquals('Renamed Dash Title', reloaded.Name);
    }

    @isTest
    static void saveDashboardSizeGuardRejectsOversizedFilterJson() {
        // Build a string longer than the 130000-char threshold.
        String huge = 'x'.repeat(130001);
        Test.startTest();
        try {
            CR_DashboardService.saveDashboard(
                null, 'Sprint1 Big', 'F', 'C', huge, '{"columns":12}', false, '[]', null
            );
            System.assert(false, 'Expected AuraHandledException for oversized filter JSON');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void validateJsonSizeAcceptsSmallStrings() {
        // Direct unit test of the @TestVisible helper.
        CR_DashboardService.validateJsonSize('Layout', '{"columns":12}');
        CR_DashboardService.validateJsonSize('Layout', null);
        CR_DashboardService.validateJsonSize('Layout', '');
        // No assertion needed: a thrown exception fails the test.
        System.assert(true);
    }

    @isTest
    static void loadDashboardRoundTrip() {
        Id dashId = CR_DashboardService.saveDashboard(
            null, 'Sprint1 Load', 'F', 'C', '[]', '{"columns":12}', true, '[]', null
        );
        Test.startTest();
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashId, false);
        Test.stopTest();
        System.assertEquals(dashId, payload.dashboard.Id);
        System.assertEquals('Sprint1 Load', payload.dashboard.Name);
        System.assertEquals(true, payload.dashboard.Is_Public__c);
        System.assertEquals(0, payload.components.size());
    }

    @isTest
    static void listDashboardsReturnsRecentlyInserted() {
        CR_DashboardService.saveDashboard(
            null, 'Sprint1 List Test', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        Test.startTest();
        List<Dashboard__c> results = CR_DashboardService.listDashboards('Sprint1 List');
        Test.stopTest();
        System.assert(results.size() >= 1);
    }
}