@isTest
private class CR_FolderService_Test {

    @isTest
    static void resolveReturnsNullForBlank() {
        System.assertEquals(null, CR_FolderService.resolveFolderId(null), 'null input -> null');
        System.assertEquals(null, CR_FolderService.resolveFolderId('   '), 'whitespace -> null');
    }

    @isTest
    static void resolveCreatesThenReusesFolder() {
        Id first = CR_FolderService.resolveFolderId('  Sales Ops  ');
        System.assertNotEquals(null, first, 'A folder Id should be returned.');
        CR_Folder__c f = [SELECT Name FROM CR_Folder__c WHERE Id = :first];
        System.assertEquals('Sales Ops', f.Name, 'Label should be trimmed before save.');

        Id second = CR_FolderService.resolveFolderId('Sales Ops');
        System.assertEquals(first, second, 'Same label must reuse the existing folder.');
        System.assertEquals(1,
            [SELECT COUNT() FROM CR_Folder__c WHERE Name = 'Sales Ops'],
            'Get-or-create must not create duplicates.');
    }

    @isTest
    static void resolveCapsNameAt80() {
        String longLabel = '';
        for (Integer i = 0; i < 120; i++) {
            longLabel += 'x';
        }
        Id id = CR_FolderService.resolveFolderId(longLabel);
        CR_Folder__c f = [SELECT Name FROM CR_Folder__c WHERE Id = :id];
        System.assertEquals(80, f.Name.length(), 'Folder name must be capped at 80 characters.');
    }

    // ---- Folders tab (crFolderManager) ----

    private static User makeUser(String profileName, String aliasSeed, Boolean asAdmin) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = aliasSeed,
                Email = aliasSeed + '@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'FolderTest',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = aliasSeed + rand + '@example.com.invalid'
            );
            insert u;
            if (asAdmin) {
                PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
                insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
            }
        }
        return u;
    }

    @isTest
    static void listFoldersAndContents() {
        CR_Folder__c folder = new CR_Folder__c(Name = 'Sales');
        insert folder;
        Report_Definition__c rpt = CR_TestDataFactory.createFactOpportunityReport(true);
        rpt.Folder_Ref__c = folder.Id;
        update rpt;

        Test.startTest();
        List<CR_FolderService.FolderSummary> folders = CR_FolderService.listFolders();
        CR_FolderService.FolderContents contents = CR_FolderService.getFolderContents(folder.Id);
        Test.stopTest();

        Boolean found = false;
        for (CR_FolderService.FolderSummary s : folders) {
            if (s.id == folder.Id) {
                found = true;
                System.assertEquals(1, s.reportCount, 'Folder should report one report inside.');
            }
        }
        System.assertEquals(true, found, 'The folder should appear in listFolders.');
        System.assertEquals(1, contents.reports.size(), 'getFolderContents should return the report.');
    }

    @isTest
    static void adminManagesMembers() {
        User admin = makeUser('System Administrator', 'crfadm', true);
        System.runAs(admin) {
            CR_Folder__c folder = new CR_Folder__c(Name = 'Engineering');
            insert folder;
            Id memId = CR_FolderService.addMember(JSON.serialize(new Map<String, Object>{
                'folderId' => folder.Id,
                'memberType' => 'User',
                'userId' => admin.Id,
                'accessLevel' => 'Edit'
            }));
            System.assertNotEquals(null, memId, 'addMember should return the membership Id.');

            List<CR_FolderService.MemberDto> members = CR_FolderService.listMembers(folder.Id);
            System.assertEquals(1, members.size(), 'One member should be listed.');
            System.assertEquals('Edit', members[0].accessLevel, 'Access level should round-trip.');
            System.assertEquals(true, CR_FolderService.canManageFolders(), 'Admin should be able to manage folders.');

            CR_FolderService.updateMemberAccess(memId, 'Read');
            System.assertEquals('Read',
                [SELECT Access_Level__c FROM CR_Folder_Membership__c WHERE Id = :memId].Access_Level__c,
                'Access level should update to Read.');

            CR_FolderService.removeMember(memId);
            System.assertEquals(0, CR_FolderService.listMembers(folder.Id).size(), 'Member should be removed.');
        }
    }

    @isTest
    static void searchPrincipalsFindsUsersAndGroups() {
        User admin = makeUser('System Administrator', 'crfsrch', true);
        Group g = new Group(Name = 'CRF Search Group', Type = 'Regular');
        insert g;
        System.runAs(admin) {
            Test.startTest();
            List<CR_FolderService.PrincipalDto> users =
                CR_FolderService.searchPrincipals('User', 'FolderTest');
            List<CR_FolderService.PrincipalDto> groups =
                CR_FolderService.searchPrincipals('Public Group', 'CRF Search');
            Test.stopTest();

            System.assertNotEquals(0, users.size(), 'User search should match the test user.');
            Boolean groupFound = false;
            for (CR_FolderService.PrincipalDto p : groups) {
                if (p.id == String.valueOf(g.Id)) {
                    groupFound = true;
                }
            }
            System.assertEquals(true, groupFound, 'Group search should return the public group.');
        }
    }

    @isTest
    static void searchPrincipalsRequiresPermission() {
        User noPerm = makeUser('Standard User', 'crfsnp', false);
        Boolean threw = false;
        System.runAs(noPerm) {
            try {
                CR_FolderService.searchPrincipals('User', 'x');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'searchPrincipals must reject callers without Manage_Report_Folders.');
    }

    @isTest
    static void memberMgmtRequiresPermission() {
        CR_Folder__c folder = new CR_Folder__c(Name = 'Locked');
        insert folder;
        User noPerm = makeUser('Standard User', 'crfnop', false);
        Boolean threw = false;
        System.runAs(noPerm) {
            System.assertEquals(false, CR_FolderService.canManageFolders(), 'Non-admin cannot manage folders.');
            try {
                CR_FolderService.addMember(JSON.serialize(new Map<String, Object>{
                    'folderId' => folder.Id, 'memberType' => 'User', 'userId' => noPerm.Id
                }));
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'addMember must reject callers without Manage_Report_Folders.');
    }
}