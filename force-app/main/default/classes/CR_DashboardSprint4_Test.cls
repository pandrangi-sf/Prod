@isTest
private class CR_DashboardSprint4_Test {

    private static String oneComponentJson() {
        return JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Sprint4 Tile',
                'reportDefinitionId' => null,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });
    }

    @isTest
    static void deleteDashboardRemovesParentAndChildren() {
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Delete Source', 'F', 'C', '[]', '{"columns":12}', false, oneComponentJson(), null
        );
        System.assertEquals(1, [SELECT COUNT() FROM Dashboard_Component__c WHERE Dashboard__c = :dashboardId]);

        Test.startTest();
        CR_DashboardService.deleteDashboard(dashboardId);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Dashboard__c WHERE Id = :dashboardId]);
        System.assertEquals(0, [SELECT COUNT() FROM Dashboard_Component__c WHERE Dashboard__c = :dashboardId],
            'Master-detail cascade should remove child components');
    }

    @isTest
    static void deleteDashboardRejectsNullId() {
        Boolean threw = false;
        try {
            CR_DashboardService.deleteDashboard(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null id should throw');
    }

    @isTest
    static void deleteDashboardRejectsMissingId() {
        // Synthesise a non-existent Dashboard__c id (000000000000000) by inserting and deleting.
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Delete Probe', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        delete [SELECT Id FROM Dashboard__c WHERE Id = :dashboardId];

        Boolean threw = false;
        try {
            CR_DashboardService.deleteDashboard(dashboardId);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing id should throw');
    }

    @isTest
    static void cloneDashboardCopiesParentAndChildren() {
        Id sourceId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Clone Source', 'Folder', 'Cat', '[]', '{"columns":12}', true, oneComponentJson(), null
        );

        Test.startTest();
        Id cloneId = CR_DashboardService.cloneDashboard(sourceId, 'Sprint4 Clone Copy');
        Test.stopTest();

        System.assertNotEquals(sourceId, cloneId, 'Clone should be a new record');
        Dashboard__c clone = [
            SELECT Id, Name, Folder__c, Category__c, Is_Public__c, Version__c
            FROM Dashboard__c WHERE Id = :cloneId
        ];
        System.assertEquals('Sprint4 Clone Copy', clone.Name);
        System.assertEquals('Folder', clone.Folder__c);
        System.assertEquals('Cat', clone.Category__c);
        System.assertEquals(true, clone.Is_Public__c);
        System.assertEquals(1, clone.Version__c, 'Cloned dashboard starts at version 1');
        System.assertEquals(1, [SELECT COUNT() FROM Dashboard_Component__c WHERE Dashboard__c = :cloneId],
            'Clone should copy each child component');

        // Source still intact
        System.assertEquals(1, [SELECT COUNT() FROM Dashboard_Component__c WHERE Dashboard__c = :sourceId]);
    }

    @isTest
    static void cloneDashboardRejectsDuplicateName() {
        Id sourceId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Clone Dup Src', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        // Pre-create a dashboard with the target name.
        CR_DashboardService.saveDashboard(
            null, 'Sprint4 Clone Dup Target', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );

        Boolean threw = false;
        try {
            CR_DashboardService.cloneDashboard(sourceId, 'Sprint4 Clone Dup Target');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Duplicate name should throw');
    }

    @isTest
    static void cloneDashboardRejectsBlankName() {
        Id sourceId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Clone Blank Src', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        Boolean threw = false;
        try {
            CR_DashboardService.cloneDashboard(sourceId, '   ');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank name should throw');
    }

    @isTest
    static void cloneDashboardRejectsNullSource() {
        Boolean threw = false;
        try {
            CR_DashboardService.cloneDashboard(null, 'Whatever');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null source id should throw');
    }

    // Phase B: theme/palette/grid/runas round-trip through saveDashboardV2 and
    // back via loadDashboard. Confirms the new fields persist and re-hydrate.
    @isTest
    static void saveDashboardV2PersistsPropertiesFields() {
        Test.startTest();
        Id dashboardId = CR_DashboardService.saveDashboardV2(
            null, 'Sprint4 PropsRoundtrip', 'F', 'C', '[]', '{"columns":12}', false,
            '[]', null,
            'Dark', 'Watermelon', '9', 'Viewer', null, true
        );
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, false);
        Test.stopTest();

        System.assertEquals('Dark', payload.dashboard.Theme__c);
        System.assertEquals('Watermelon', payload.dashboard.Palette__c);
        System.assertEquals('9', payload.dashboard.Grid_Size__c);
        System.assertEquals('Viewer', payload.dashboard.Run_As_Mode__c);
        System.assertEquals(true, payload.dashboard.Allow_Viewer_Run_As_Choice__c);
    }

    // Phase B: legacy saveDashboard (no theme/palette args) still works after
    // the v2 split. Picklist defaults (Light / Aurora / 12 / Me) auto-populate
    // on the platform side because the field metadata declares them, so legacy
    // saves end up with sensible values without the client having to know.
    @isTest
    static void legacySaveDashboardStillWorks() {
        Test.startTest();
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 LegacySave', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        Test.stopTest();

        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, false);
        System.assertEquals('Sprint4 LegacySave', payload.dashboard.Name);
        System.assertEquals('Light', payload.dashboard.Theme__c, 'Theme__c picklist default applies');
        System.assertEquals('Aurora', payload.dashboard.Palette__c, 'Palette__c picklist default applies');
        System.assertEquals('12', payload.dashboard.Grid_Size__c, 'Grid_Size__c picklist default applies');
        System.assertEquals('Me', payload.dashboard.Run_As_Mode__c, 'Run_As_Mode__c picklist default applies');
        System.assertEquals(false, payload.dashboard.Allow_Viewer_Run_As_Choice__c, 'AllowViewerRunAsChoice defaults to false');
    }

    // Phase I: listFolders returns distinct non-blank Folder__c values from
    // existing dashboards, sorted, used by the New Dashboard Wizard combobox.
    @isTest
    static void listFoldersReturnsDistinctNonBlankValues() {
        Id d1 = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Folder Test 1', 'Sales',     'C', '[]', '{"columns":12}', false, '[]', null
        );
        Id d2 = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Folder Test 2', 'Marketing', 'C', '[]', '{"columns":12}', false, '[]', null
        );
        // Same folder as d1 — should appear only once in the distinct list.
        Id d3 = CR_DashboardService.saveDashboard(
            null, 'Sprint4 Folder Test 3', 'Sales',     'C', '[]', '{"columns":12}', false, '[]', null
        );

        Test.startTest();
        List<String> folders = CR_DashboardService.listFolders();
        Test.stopTest();

        Set<String> unique = new Set<String>(folders);
        System.assertEquals(folders.size(), unique.size(),
            'listFolders should return distinct values');
        System.assert(unique.contains('Sales'), 'Sales should appear in folder list');
        System.assert(unique.contains('Marketing'), 'Marketing should appear in folder list');
    }

    // Phase I: dashboardNameExists is a cheap preflight for the wizard.
    @isTest
    static void dashboardNameExistsBehavior() {
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint4 NameExists', 'F', 'C', '[]', '{"columns":12}', false, '[]', null
        );

        Test.startTest();
        Boolean exists  = CR_DashboardService.dashboardNameExists('Sprint4 NameExists');
        Boolean missing = CR_DashboardService.dashboardNameExists('Sprint4 Definitely Not Here');
        Boolean blank   = CR_DashboardService.dashboardNameExists('');
        Boolean nullName = CR_DashboardService.dashboardNameExists(null);
        Test.stopTest();

        System.assertEquals(true, exists,  'Existing name should return true');
        System.assertEquals(false, missing, 'Unknown name should return false');
        System.assertEquals(false, blank,   'Blank name should return false (not an error)');
        System.assertEquals(false, nullName,'Null name should return false (not an error)');
    }

    // Phase B: cloning a dashboard with theme/palette/runas set must copy
    // every Phase B field onto the clone.
    @isTest
    static void cloneDashboardCopiesPhaseBFields() {
        Id sourceId = CR_DashboardService.saveDashboardV2(
            null, 'Sprint4 PhaseB Source', 'F', 'C', '[]', '{"columns":12}', true,
            oneComponentJson(), null,
            'Dark', 'Ocean', '12', 'Me', null, false
        );

        Test.startTest();
        Id cloneId = CR_DashboardService.cloneDashboard(sourceId, 'Sprint4 PhaseB Clone');
        Test.stopTest();

        Dashboard__c clone = [
            SELECT Theme__c, Palette__c, Grid_Size__c, Run_As_Mode__c, Allow_Viewer_Run_As_Choice__c
            FROM Dashboard__c WHERE Id = :cloneId
        ];
        System.assertEquals('Dark', clone.Theme__c);
        System.assertEquals('Ocean', clone.Palette__c);
        System.assertEquals('12', clone.Grid_Size__c);
        System.assertEquals('Me', clone.Run_As_Mode__c);
    }
}