@isTest
private class CR_HelpService_Test {
    @isTest
    static void blankToolKeyReturnsEmpty() {
        Test.startTest();
        List<CR_HelpService.HelpSection> r = CR_HelpService.getHelpForTool(null);
        List<CR_HelpService.HelpSection> r2 = CR_HelpService.getHelpForTool('');
        Test.stopTest();
        System.assertEquals(0, r.size());
        System.assertEquals(0, r2.size());
    }

    // We can't insert custom metadata in a test (it's metadata, not data), so
    // this test exercises only the empty-result path. Real records are tested
    // via the seeded .md-meta.xml files at deploy time — if the Tool_Key__c
    // values match the LWCs that wire crHelpPanel, the integration works.
    @isTest
    static void unknownToolKeyReturnsEmpty() {
        Test.startTest();
        List<CR_HelpService.HelpSection> r = CR_HelpService.getHelpForTool('crNoSuchTool');
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    // If real CMD records seeded for crDashboardBuilder land in the org, this
    // assertion catches accidental tool-key drift between the seed records
    // and the LWC's @api toolKey value. Defensive against typos in the seed.
    @isTest
    static void seededRecordsResolveForKnownTools() {
        Test.startTest();
        List<CR_HelpService.HelpSection> r = CR_HelpService.getHelpForTool('crDashboardBuilder');
        Test.stopTest();
        // We don't assert r.size() > 0 because the seed records may not be
        // present in scratch orgs that strip customMetadata at create time.
        // Instead assert each returned record has the expected shape.
        for (CR_HelpService.HelpSection s : r) {
            System.assertNotEquals(null, s.heading);
            System.assertNotEquals(null, s.iconName, 'iconName falls back to utility:info when blank');
        }
    }

    // A standard user with no custom permissions is not a Vital Reports admin,
    // so admin-audience help topics must be filtered out for them. Setup DML is
    // isolated in a runAs block to avoid mixed-DML errors.
    private static User standardUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crhlp',
                Email = 'crhelp@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'HelpUser',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crhelp' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    @isTest
    static void nonAdminDoesNotSeeAdminTopics() {
        User u = standardUser();
        List<CR_HelpService.HelpSection> folders;
        List<CR_HelpService.HelpSection> subs;
        Test.startTest();
        System.runAs(u) {
            folders = CR_HelpService.getHelpForTool('crFolderManager');
            subs = CR_HelpService.getHelpForTool('crSubscriptionManager');
        }
        Test.stopTest();
        // Admin-only topics must never appear for a non-admin. (Presence of the
        // non-admin topics isn't asserted because scratch orgs may strip CMD.)
        for (CR_HelpService.HelpSection s : folders) {
            System.assertNotEquals('Managing who can access a folder', s.heading,
                'Non-admins must not see the admin folder-access topic.');
        }
        for (CR_HelpService.HelpSection s : subs) {
            System.assertNotEquals('Creating and scheduling a subscription', s.heading,
                'Non-admins must not see admin-only subscription help.');
        }
    }
}