@isTest
private class CR_FolderSharingService_Test {

    // A second user to share to (sharing to the record owner is rejected by the
    // platform). Setup DML isolated in runAs to avoid mixed-DML errors.
    private static User makeUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crfm',
                Email = 'crfoldermember@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'FolderMember',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crfoldermember' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    private static Report_Definition__c reportInFolder(Id folderId) {
        Report_Definition__c rpt = CR_TestDataFactory.createFactOpportunityReport(true);
        rpt.Folder_Ref__c = folderId;
        update rpt;
        return rpt;
    }

    private static Dashboard__c dashboardInFolder(Id folderId) {
        Dashboard__c d = new Dashboard__c(
            Name = 'Folder DB',
            Developer_Name__c = 'Folder_DB_' + Math.abs(Crypto.getRandomInteger()),
            Folder_Ref__c = folderId
        );
        insert d;
        return d;
    }

    private static Integer reportShareCount(Id reportId) {
        return [
            SELECT COUNT() FROM Report_Definition__Share
            WHERE ParentId = :reportId
            AND RowCause = 'Manual'
        ];
    }

    @isTest
    static void editMembershipSharesReportToMember() {
        User member = makeUser();
        CR_Folder__c folder = new CR_Folder__c(Name = 'Engineering');
        insert folder;
        Report_Definition__c rpt = reportInFolder(folder.Id);

        Test.startTest();
        insert new CR_Folder_Membership__c(
            Folder__c = folder.Id, Member_Type__c = 'User', User__c = member.Id, Access_Level__c = 'Edit'
        );
        Test.stopTest();

        List<Report_Definition__Share> shares = [
            SELECT UserOrGroupId, AccessLevel FROM Report_Definition__Share
            WHERE ParentId = :rpt.Id
            AND RowCause = 'Manual'
        ];
        System.assertEquals(1, shares.size(), 'An Edit membership should create exactly one folder share.');
        System.assertEquals(member.Id, shares[0].UserOrGroupId, 'Share should target the member.');
        System.assertEquals('Edit', shares[0].AccessLevel, 'Edit access should be granted.');
    }

    @isTest
    static void editMembershipSharesDashboardToMember() {
        User member = makeUser();
        CR_Folder__c folder = new CR_Folder__c(Name = 'Operations');
        insert folder;
        Dashboard__c d = dashboardInFolder(folder.Id);

        Test.startTest();
        insert new CR_Folder_Membership__c(
            Folder__c = folder.Id, Member_Type__c = 'User', User__c = member.Id, Access_Level__c = 'Edit'
        );
        Test.stopTest();

        List<Dashboard__Share> shares = [
            SELECT AccessLevel FROM Dashboard__Share
            WHERE ParentId = :d.Id
            AND RowCause = 'Manual'
        ];
        System.assertEquals(1, shares.size(), 'An Edit membership should create one dashboard folder share.');
        System.assertEquals('Edit', shares[0].AccessLevel, 'Edit access should be granted.');
    }

    @isTest
    static void membershipDeleteRemovesShares() {
        User member = makeUser();
        CR_Folder__c folder = new CR_Folder__c(Name = 'Finance');
        insert folder;
        Report_Definition__c rpt = reportInFolder(folder.Id);
        CR_Folder_Membership__c mem = new CR_Folder_Membership__c(
            Folder__c = folder.Id, Member_Type__c = 'User', User__c = member.Id, Access_Level__c = 'Edit'
        );
        insert mem;
        System.assertEquals(1, reportShareCount(rpt.Id), 'Precondition: a share should exist.');

        Test.startTest();
        delete mem;
        Test.stopTest();

        System.assertEquals(0, reportShareCount(rpt.Id), 'Deleting the membership should remove the folder share.');
    }

    @isTest
    static void recomputeAllRebuildsDriftedShares() {
        User member = makeUser();
        CR_Folder__c folder = new CR_Folder__c(Name = 'Marketing');
        insert folder;
        Report_Definition__c rpt = reportInFolder(folder.Id);
        insert new CR_Folder_Membership__c(
            Folder__c = folder.Id, Member_Type__c = 'User', User__c = member.Id, Access_Level__c = 'Edit'
        );
        // Simulate drift: wipe the managed shares directly.
        delete [
            SELECT Id FROM Report_Definition__Share
            WHERE ParentId = :rpt.Id
            AND RowCause = 'Manual'
        ];
        System.assertEquals(0, reportShareCount(rpt.Id), 'Precondition: shares wiped.');

        Test.startTest();
        CR_FolderSharingService.recomputeAll();
        Test.stopTest();

        System.assertEquals(1, reportShareCount(rpt.Id), 'recomputeAll should rebuild the missing share.');
    }
}