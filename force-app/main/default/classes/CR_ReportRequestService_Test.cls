@isTest
private class CR_ReportRequestService_Test {

    private static final String DATASET_JSON =
        '{"objectApiName":"Account","primaryObject":"Account","mode":"live",' +
        '"datasetKey":"Account","fieldPaths":["Name"],"fieldLabels":{"Name":"Account Name"}}';

    private static String requestPayload() {
        return JSON.serialize(new Map<String, Object>{
            'reportTitle' => 'Accounts by Industry',
            'requestedObject' => 'Account',
            'datasetKey' => 'Account',
            'datasetJson' => DATASET_JSON,
            'filtersJson' => '[{"field":"Type","operator":"=","value":"Customer"}]',
            'fieldsSummary' => 'Account Name',
            'description' => 'Need a list of accounts.',
            'priority' => 'High'
        });
    }

    // Admin user holding Custom_Reporting_Admin (grants Manage_Report_Requests + is a
    // notification target). Setup DML isolated in runAs to avoid mixed-DML.
    private static User adminUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crrq', Email = 'crreqadmin@example.com.invalid',
                EmailEncodingKey = 'UTF-8', LastName = 'ReqAdmin', LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US', ProfileId = p.Id, TimeZoneSidKey = 'America/New_York',
                Username = 'crreqadmin' + rand + '@example.com.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    private static User plainUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crrqu', Email = 'crrequser@example.com.invalid',
                EmailEncodingKey = 'UTF-8', LastName = 'ReqUser', LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US', ProfileId = p.Id, TimeZoneSidKey = 'America/New_York',
                Username = 'crrequser' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    @isTest
    static void submitAndListMine() {
        Test.startTest();
        Id reqId = CR_ReportRequestService.submitRequest(requestPayload());
        Test.stopTest();

        System.assertNotEquals(null, reqId, 'Submit should return the new request Id.');
        List<CR_ReportRequestService.RequestDto> mine = CR_ReportRequestService.listMyRequests();
        System.assertEquals(1, mine.size(), 'The requester should see their own request.');
        System.assertEquals('New', mine[0].status, 'A new request starts as New.');
        System.assertEquals('High', mine[0].priority, 'Priority should round-trip.');
    }

    @isTest
    static void submitRejectsEmpty() {
        Boolean threw = false;
        try {
            CR_ReportRequestService.submitRequest(JSON.serialize(new Map<String, Object>{ 'reportTitle' => 'x' }));
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A request with no object should be rejected.');
    }

    @isTest
    static void adminListBuildAndComplete() {
        Id reqId = CR_ReportRequestService.submitRequest(requestPayload());
        User admin = adminUser();
        System.runAs(admin) {
            List<CR_ReportRequestService.RequestDto> all = CR_ReportRequestService.listAllRequests();
            System.assert(!all.isEmpty(), 'Admin should see all requests.');

            Test.startTest();
            Id reportId = CR_ReportRequestService.buildFromRequest(reqId);
            Test.stopTest();
            System.assertNotEquals(null, reportId, 'Build-from-request should create a draft report.');

            CR_Report_Request__c after = [
                SELECT Status__c, Resulting_Report__c FROM CR_Report_Request__c WHERE Id = :reqId
            ];
            System.assertEquals('In Progress', after.Status__c, 'Building flips the request to In Progress.');
            System.assertEquals(reportId, after.Resulting_Report__c, 'The draft report should be linked.');

            Report_Definition__c rd = [
                SELECT Root_Object__c, Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportId
            ];
            System.assertEquals('Account', rd.Root_Object__c, 'Draft root object comes from the dataset.');
            System.assert(rd.Definition_JSON__c.contains('"fields"'), 'Draft carries an assembled definition.');

            // Idempotent: building again returns the same report.
            System.assertEquals(reportId, CR_ReportRequestService.buildFromRequest(reqId),
                'Building an already-built request returns the existing draft.');

            CR_ReportRequestService.updateStatus(reqId, 'Completed', 'Built and shared.');
            System.assertEquals('Completed',
                [SELECT Status__c FROM CR_Report_Request__c WHERE Id = :reqId].Status__c,
                'Status should be Completed.');
        }
    }

    @isTest
    static void rejectAndLink() {
        Id reqId = CR_ReportRequestService.submitRequest(requestPayload());
        User admin = adminUser();
        System.runAs(admin) {
            CR_ReportRequestService.updateStatus(reqId, 'Rejected', 'Out of scope.');
            CR_Report_Request__c r = [SELECT Status__c, Admin_Notes__c FROM CR_Report_Request__c WHERE Id = :reqId];
            System.assertEquals('Rejected', r.Status__c, 'Status should be Rejected.');
            System.assertEquals('Out of scope.', r.Admin_Notes__c, 'Admin notes should persist.');
        }
    }

    @isTest
    static void manageGateBlocksNonAdmin() {
        Id reqId = CR_ReportRequestService.submitRequest(requestPayload());
        User u = plainUser();
        System.runAs(u) {
            Boolean listThrew = false, statusThrew = false, buildThrew = false;
            try { CR_ReportRequestService.listAllRequests(); } catch (AuraHandledException e) { listThrew = true; }
            try { CR_ReportRequestService.updateStatus(reqId, 'Completed', null); } catch (AuraHandledException e) { statusThrew = true; }
            try { CR_ReportRequestService.buildFromRequest(reqId); } catch (AuraHandledException e) { buildThrew = true; }
            System.assertEquals(true, listThrew, 'listAllRequests must require Manage_Report_Requests.');
            System.assertEquals(true, statusThrew, 'updateStatus must require Manage_Report_Requests.');
            System.assertEquals(true, buildThrew, 'buildFromRequest must require Manage_Report_Requests.');
        }
    }
}