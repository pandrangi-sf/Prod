@isTest
private class CR_HomeTileService_Test {

    // Standard user WITH the Custom_Reporting_Admin perm set (grants the
    // Manage_Home_Tiles custom permission). Setup DML isolated in a runAs block.
    private static User adminUser() {
        User u = baseUser('crtileadm');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    // Standard user with no Vital Reports perm sets — neither admin nor manager.
    private static User plainUser() {
        return baseUser('crtileusr');
    }

    private static User baseUser(String aliasSeed) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crtl',
                Email = aliasSeed + '@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'TileTester',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = aliasSeed + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    @isTest
    static void getTiles_excludesInactive_andShapes() {
        insert new List<CR_Launchpad_Tile__c>{
            new CR_Launchpad_Tile__c(Name = 'Active Tile', Target_Tab_API_Name__c = 'Custom_Report_Viewer',
                Icon_Name__c = 'standard:report', Audience__c = 'Both', Is_Active__c = true, Display_Order__c = 10),
            new CR_Launchpad_Tile__c(Name = 'Inactive Tile', Target_Tab_API_Name__c = 'Custom_Report_Viewer',
                Icon_Name__c = 'standard:report', Audience__c = 'Both', Is_Active__c = false, Display_Order__c = 20)
        };
        Test.startTest();
        List<CR_HomeTileService.HomeTile> tiles = CR_HomeTileService.getTilesForCurrentUser();
        Test.stopTest();

        System.assertNotEquals(null, tiles, 'service must return a non-null list');
        for (CR_HomeTileService.HomeTile t : tiles) {
            System.assertNotEquals(null, t.label, 'every tile needs a label');
            System.assertNotEquals(null, t.colorScheme, 'colorScheme defaults when blank');
            System.assertNotEquals('Inactive Tile', t.label, 'inactive tiles must never be returned');
        }
    }

    @isTest
    static void adminCanCrudTiles() {
        User admin = adminUser();
        Test.startTest();
        System.runAs(admin) {
            System.assertEquals(true, CR_HomeTileService.canManageTiles(), 'admin holds Manage_Home_Tiles');
            System.assert(!CR_HomeTileService.listAvailableTabs().isEmpty(), 'tab options should resolve');

            String payload = JSON.serialize(new Map<String, Object>{
                'label' => 'My Tile',
                'description' => 'desc',
                'iconName' => 'standard:custom',
                'target' => 'Custom_Report_Viewer',
                'audience' => 'Admin',
                'colorScheme' => 'blue',
                'displayOrder' => 90,
                'isActive' => true
            });
            Id tileId = CR_HomeTileService.saveTile(payload);
            System.assertNotEquals(null, tileId, 'save returns the new id');

            List<CR_HomeTileService.AdminTile> all = CR_HomeTileService.listAllTiles();
            Boolean found = false;
            for (CR_HomeTileService.AdminTile a : all) {
                if (a.id == tileId) {
                    found = true;
                    System.assertEquals('My Tile', a.label);
                    System.assertEquals('Admin', a.audience);
                }
            }
            System.assert(found, 'new tile appears in listAllTiles');

            // Update
            CR_HomeTileService.saveTile(JSON.serialize(new Map<String, Object>{
                'id' => tileId, 'label' => 'Renamed Tile', 'audience' => 'Both', 'isActive' => false
            }));
            CR_Launchpad_Tile__c reloaded = [SELECT Name, Audience__c, Is_Active__c FROM CR_Launchpad_Tile__c WHERE Id = :tileId];
            System.assertEquals('Renamed Tile', reloaded.Name);
            System.assertEquals(false, reloaded.Is_Active__c);

            // Delete
            CR_HomeTileService.deleteTile(tileId);
            System.assertEquals(0, [SELECT COUNT() FROM CR_Launchpad_Tile__c WHERE Id = :tileId]);
        }
        Test.stopTest();
    }

    @isTest
    static void nonManagerIsBlocked() {
        User plain = plainUser();
        Test.startTest();
        System.runAs(plain) {
            System.assertEquals(false, CR_HomeTileService.canManageTiles(), 'plain user lacks Manage_Home_Tiles');
            Boolean threw = false;
            try {
                CR_HomeTileService.saveTile(JSON.serialize(new Map<String, Object>{ 'label' => 'Nope' }));
            } catch (Exception e) {
                threw = true;
            }
            System.assert(threw, 'saveTile must be blocked without Manage_Home_Tiles');
        }
        Test.stopTest();
    }

    @isTest
    static void seedFromCatalog_isIdempotent() {
        Test.startTest();
        Integer first = CR_HomeTileService.seedFromCatalog();
        Integer second = CR_HomeTileService.seedFromCatalog();
        Test.stopTest();
        // Runs in system context; count reflects the deployed CR_Home_Tile__mdt
        // catalog (may be 0 in a scratch org that strips custom metadata).
        System.assert(first >= 0, 'seed returns a non-negative count');
        System.assertEquals(first, second, 'second run upserts the same set, not duplicates');
        if (first > 0) {
            System.assertEquals(first, [SELECT COUNT() FROM CR_Launchpad_Tile__c],
                'no duplicate rows created on re-seed');
        }
    }

    @isTest
    static void constants_areExpectedValues() {
        System.assertEquals('Vital_Reports_Admin_View', CR_HomeTileService.ADMIN_PERMISSION_API_NAME);
        System.assertEquals('Manage_Home_Tiles', CR_HomeTileService.MANAGE_PERMISSION_API_NAME);
        System.assertEquals('slate', CR_HomeTileService.DEFAULT_COLOR);
    }
}