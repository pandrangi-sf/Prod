@isTest
private class CR_SubscriptionService_Test {

    private static CR_Subscription__c newSub(Id reportId, String freq) {
        return new CR_Subscription__c(
            Report_Definition__c = reportId,
            Frequency__c = freq,
            Hour_Of_Day__c = 6,
            Day_Of_Week__c = 'Monday',
            Day_Of_Month__c = 1,
            Include_HTML_Table__c = true,
            Include_CSV_Attachment__c = true,
            Max_Inline_Rows__c = 50,
            Send_If_Empty__c = false,
            Active__c = true
        );
    }

    private static Report_Definition__c broadcastReport() {
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        report.Broadcast_Safe__c = true;
        update report;
        return report;
    }

    private static void addRecipient(Id subscriptionId) {
        insert new CR_Subscription_Recipient__c(
            Subscription__c = subscriptionId,
            User__c = UserInfo.getUserId()
        );
    }

    // A minimal user guaranteed NOT to hold Manage_Report_Subscriptions, so the
    // permission-gate negative tests are robust even when the running user (e.g.
    // a real admin in the org) already has the custom permission. Setup-object
    // DML is isolated in a runAs block to avoid mixed-DML errors.
    private static User userWithoutPermission() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crnop',
                Email = 'crnoperm@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'NoPerm',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crnoperm' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    @isTest
    static void computeNextRunDailyRollsToTomorrowWhenPast() {
        CR_Subscription__c sub = new CR_Subscription__c(Frequency__c = 'Daily', Hour_Of_Day__c = 6);
        Datetime fromTime = Datetime.newInstance(Date.newInstance(2026, 5, 28), Time.newInstance(8, 0, 0, 0));
        Datetime next = CR_SubscriptionService.computeNextRun(sub, fromTime);
        System.assertEquals(Date.newInstance(2026, 5, 29), next.date(), 'Past the daily hour should roll to tomorrow.');
        System.assertEquals(6, next.hour(), 'Hour should be preserved.');
    }

    @isTest
    static void computeNextRunWeeklyAndMonthly() {
        Datetime fromTime = Datetime.now();

        CR_Subscription__c weekly = new CR_Subscription__c(Frequency__c = 'Weekly', Day_Of_Week__c = 'Monday', Hour_Of_Day__c = 9);
        Datetime nextWeekly = CR_SubscriptionService.computeNextRun(weekly, fromTime);
        System.assert(nextWeekly > fromTime, 'Weekly next run must be in the future.');
        System.assertEquals('Monday', nextWeekly.format('EEEE'), 'Weekly must land on the chosen weekday.');

        CR_Subscription__c monthly = new CR_Subscription__c(Frequency__c = 'Monthly', Day_Of_Month__c = 15, Hour_Of_Day__c = 7);
        Datetime nextMonthly = CR_SubscriptionService.computeNextRun(monthly, fromTime);
        System.assert(nextMonthly > fromTime, 'Monthly next run must be in the future.');
        System.assertEquals(15, nextMonthly.day(), 'Monthly must land on the chosen day of month.');
    }

    @isTest
    static void computeNextRunMonthlyCapsAt28() {
        CR_Subscription__c monthly = new CR_Subscription__c(Frequency__c = 'Monthly', Day_Of_Month__c = 31, Hour_Of_Day__c = 7);
        Datetime next = CR_SubscriptionService.computeNextRun(monthly, Datetime.now());
        System.assertEquals(28, next.day(), 'Day of month should be capped at 28.');
    }

    @isTest
    static void dispatcherInitializesNextRun() {
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;
        System.assertEquals(null,
            [SELECT Next_Run_At__c FROM CR_Subscription__c WHERE Id = :sub.Id].Next_Run_At__c,
            'No trigger, so Next_Run_At is null until the dispatcher initializes it.');

        Test.startTest();
        CR_SubscriptionDispatcher.dispatchDue();
        Test.stopTest();

        System.assertNotEquals(null,
            [SELECT Next_Run_At__c FROM CR_Subscription__c WHERE Id = :sub.Id].Next_Run_At__c,
            'Dispatcher should initialize Next_Run_At for active subscriptions.');
    }

    @isTest
    static void dispatcherPicksDueAndAdvances() {
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;
        sub.Next_Run_At__c = Datetime.now().addMinutes(-5);
        update sub;
        Datetime before = [SELECT Next_Run_At__c FROM CR_Subscription__c WHERE Id = :sub.Id].Next_Run_At__c;

        Test.startTest();
        Integer dispatched = CR_SubscriptionDispatcher.dispatchDue();
        Test.stopTest();

        System.assertEquals(1, dispatched, 'The due subscription should be dispatched.');
        Datetime after = [SELECT Next_Run_At__c FROM CR_Subscription__c WHERE Id = :sub.Id].Next_Run_At__c;
        System.assert(after > before, 'Next_Run_At should advance past the due time so it is not re-picked.');
    }

    @isTest
    static void sendDeliversForBroadcastSafeReport() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = broadcastReport();
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;
        addRecipient(sub.Id);

        // The send runs an FLS-enforced report, so execute it as a provisioned admin.
        System.runAs(adminUser()) {
            Test.startTest();
            new CR_SubscriptionSendQueueable(sub.Id).execute(null);
            Test.stopTest();

            sub = [SELECT Last_Status__c, Last_Message__c FROM CR_Subscription__c WHERE Id = :sub.Id];
            // Email deliverability may be disabled in the running sandbox. The queueable
            // now reports the platform's actual verdict instead of a blanket 'Success',
            // so accept either a real delivery ('Success' + 'Sent to') or an honest
            // platform rejection ('Failed' + 'rejected by the platform'). Both prove the
            // pipeline ran past the Broadcast-Safe / recipient checks to the send itself.
            Boolean delivered = sub.Last_Status__c == 'Success'
                && sub.Last_Message__c != null && sub.Last_Message__c.contains('Sent to');
            Boolean platformRejected = sub.Last_Status__c == 'Failed'
                && sub.Last_Message__c != null && sub.Last_Message__c.contains('rejected by the platform');
            System.assert(delivered || platformRejected,
                'Broadcast-safe report with a recipient should attempt delivery. Status: '
                + sub.Last_Status__c + ' Msg: ' + sub.Last_Message__c);
        }
    }

    @isTest
    static void sendRefusesNonBroadcastReport() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true); // Broadcast_Safe defaults false
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;
        addRecipient(sub.Id);

        new CR_SubscriptionSendQueueable(sub.Id).execute(null);

        sub = [SELECT Last_Status__c FROM CR_Subscription__c WHERE Id = :sub.Id];
        System.assertEquals('Failed', sub.Last_Status__c, 'A report not marked Broadcast Safe must not be sent.');
    }

    @isTest
    static void sendSkipsWhenNoData() {
        Report_Definition__c report = broadcastReport(); // no fact rows inserted -> zero rows
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;
        addRecipient(sub.Id);

        System.runAs(adminUser()) {
            new CR_SubscriptionSendQueueable(sub.Id).execute(null);

            sub = [SELECT Last_Status__c FROM CR_Subscription__c WHERE Id = :sub.Id];
            System.assertEquals('No Data', sub.Last_Status__c, 'Empty result with Send If Empty off should be skipped.');
        }
    }

    @isTest
    static void sendFailsWithNoRecipients() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = broadcastReport();
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub; // no recipients

        new CR_SubscriptionSendQueueable(sub.Id).execute(null);

        sub = [SELECT Last_Status__c FROM CR_Subscription__c WHERE Id = :sub.Id];
        System.assertEquals('Failed', sub.Last_Status__c, 'A subscription with no recipients should fail.');
    }

    @isTest
    static void sendNowRequiresPermission() {
        User noPerm = userWithoutPermission();
        Report_Definition__c report = broadcastReport();
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        insert sub;

        Boolean threw = false;
        System.runAs(noPerm) {
            try {
                CR_SubscriptionService.sendNow(sub.Id);
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'sendNow must reject callers without Manage_Report_Subscriptions.');
    }

    @isTest
    static void scheduleHourlyRequiresPermission() {
        User noPerm = userWithoutPermission();
        Boolean threw = false;
        System.runAs(noPerm) {
            try {
                CR_SubscriptionDispatcher.scheduleHourly();
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'scheduleHourly must reject callers without Manage_Report_Subscriptions.');
    }

    // ---- Phase 1.5: dashboard targets + team/group recipients ----

    private static Dashboard__c broadcastDashboardWithComponent(Id reportId) {
        Dashboard__c d = new Dashboard__c(
            Name = 'Sub Dashboard',
            Developer_Name__c = 'Sub_Dashboard_' + String.valueOf(Crypto.getRandomInteger()),
            Broadcast_Safe__c = true
        );
        insert d;
        insert new Dashboard_Component__c(
            Name = 'Pipeline',
            Dashboard__c = d.Id,
            Report_Definition__c = reportId,
            Visualization_JSON__c = '{"type":"table"}',
            Position_X__c = 0,
            Position_Y__c = 0,
            Width__c = 6,
            Height__c = 3
        );
        return d;
    }

    @isTest
    static void sendDeliversDashboardSubscription() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = broadcastReport();
        Dashboard__c d = broadcastDashboardWithComponent(report.Id);
        CR_Subscription__c sub = new CR_Subscription__c(
            Dashboard__c = d.Id,
            Frequency__c = 'Daily',
            Hour_Of_Day__c = 6,
            Include_HTML_Table__c = true,
            Include_CSV_Attachment__c = true,
            Max_Inline_Rows__c = 50,
            Active__c = true
        );
        insert sub;
        addRecipient(sub.Id);

        System.runAs(adminUser()) {
            Test.startTest();
            new CR_SubscriptionSendQueueable(sub.Id).execute(null);
            Test.stopTest();

            sub = [SELECT Last_Status__c, Last_Message__c FROM CR_Subscription__c WHERE Id = :sub.Id];
            // See sendDeliversForBroadcastSafeReport: accept a real delivery or an honest
            // platform rejection when sandbox email deliverability is disabled.
            Boolean delivered = sub.Last_Status__c == 'Success'
                && sub.Last_Message__c != null && sub.Last_Message__c.contains('Sent to');
            Boolean platformRejected = sub.Last_Status__c == 'Failed'
                && sub.Last_Message__c != null && sub.Last_Message__c.contains('rejected by the platform');
            System.assert(delivered || platformRejected,
                'Broadcast-safe dashboard should attempt delivery. Status: '
                + sub.Last_Status__c + ' Msg: ' + sub.Last_Message__c);
        }
    }

    @isTest
    static void sendRefusesNonBroadcastDashboard() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = broadcastReport();
        Dashboard__c d = broadcastDashboardWithComponent(report.Id);
        d.Broadcast_Safe__c = false;
        update d;
        CR_Subscription__c sub = new CR_Subscription__c(
            Dashboard__c = d.Id, Frequency__c = 'Daily', Hour_Of_Day__c = 6, Active__c = true
        );
        insert sub;
        addRecipient(sub.Id);

        new CR_SubscriptionSendQueueable(sub.Id).execute(null);

        sub = [SELECT Last_Status__c FROM CR_Subscription__c WHERE Id = :sub.Id];
        System.assertEquals('Failed', sub.Last_Status__c, 'A dashboard not marked Broadcast Safe must not be sent.');
    }

    @isTest
    static void groupResolverExpandsPublicGroupToMemberEmails() {
        // Group + GroupMember are setup objects; committing them inside
        // System.runAs makes the membership visible to the later SOQL (otherwise
        // it isn't queryable in the same test transaction).
        Group g = new Group(Name = 'CR Sub Test Team', Type = 'Regular');
        User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(me) {
            insert g;
            insert new GroupMember(GroupId = g.Id, UserOrGroupId = UserInfo.getUserId());
        }

        List<CR_Subscription_Recipient__c> recips = new List<CR_Subscription_Recipient__c>{
            new CR_Subscription_Recipient__c(
                Recipient_Type__c = 'Public Group',
                Group_Id__c = g.Id,
                Group_Name__c = g.Name
            )
        };

        Test.startTest();
        List<String> emails = CR_GroupResolver.resolveEmails(recips);
        Test.stopTest();

        String myEmail = [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email;
        System.assert(emails.contains(myEmail), 'Group member email should be resolved. Got: ' + emails);
    }

    @isTest
    static void groupResolverHandlesEmailAndUserTypes() {
        List<CR_Subscription_Recipient__c> recips = new List<CR_Subscription_Recipient__c>{
            new CR_Subscription_Recipient__c(Recipient_Type__c = 'Email', Email__c = 'ext@example.com'),
            new CR_Subscription_Recipient__c(Recipient_Type__c = 'User', User__c = UserInfo.getUserId())
        };
        List<String> emails = CR_GroupResolver.resolveEmails(recips);
        System.assert(emails.contains('ext@example.com'), 'Raw email recipient should pass through.');
        System.assertEquals(true, emails.size() >= 1, 'Should resolve at least one address.');
    }

    // ---- Admin UI (crSubscriptionManager) Apex ----

    // A user holding the Manage_Report_Subscriptions custom permission (via the
    // Custom_Reporting_Admin permission set). Setup-object DML is isolated in a
    // runAs block so it doesn't collide with the test's non-setup DML.
    private static User adminUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crsub',
                Email = 'crsubadmin@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'SubAdmin',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crsubadmin' + rand + '@example.com.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    @isTest
    static void adminCanCrudSubscriptionAndRecipient() {
        User admin = adminUser();
        System.runAs(admin) {
            Report_Definition__c report = broadcastReport();

            Map<String, Object> subPayload = new Map<String, Object>{
                'reportDefinitionId' => report.Id,
                'frequency' => 'Daily',
                'hourOfDay' => 6,
                'active' => true,
                'includeHtmlTable' => true,
                'includeCsvAttachment' => true,
                'maxInlineRows' => 50,
                'sendIfEmpty' => false
            };
            Id subId = CR_SubscriptionService.upsertSubscription(JSON.serialize(subPayload));
            System.assertNotEquals(null, subId, 'Upsert should return the new subscription Id.');

            CR_Subscription__c saved = [SELECT Active__c, Next_Run_At__c FROM CR_Subscription__c WHERE Id = :subId];
            System.assertEquals(true, saved.Active__c, 'Subscription should be active.');
            System.assertNotEquals(null, saved.Next_Run_At__c, 'Active subscription should have a computed Next Run.');

            Id recId = CR_SubscriptionService.upsertRecipient(JSON.serialize(new Map<String, Object>{
                'subscriptionId' => subId,
                'recipientType' => 'User',
                'userId' => admin.Id
            }));
            System.assertNotEquals(null, recId, 'Recipient upsert should return an Id.');

            List<CR_SubscriptionService.SubscriptionSummary> subs = CR_SubscriptionService.listSubscriptions();
            System.assertEquals(1, subs.size(), 'One subscription should be listed.');
            System.assertEquals('Report', subs[0].assetType, 'Asset type should resolve to Report.');
            System.assertEquals(1, subs[0].recipientCount, 'Recipient count should reflect the added recipient.');

            CR_SubscriptionService.SubscriptionSummary one = CR_SubscriptionService.getSubscription(subId);
            System.assertEquals(subId, one.id, 'getSubscription should return the requested record.');

            List<CR_SubscriptionService.RecipientDto> recs = CR_SubscriptionService.listRecipients(subId);
            System.assertEquals(1, recs.size(), 'One recipient should be listed.');
            System.assertEquals('User', recs[0].recipientType, 'Recipient type should round-trip.');

            CR_SubscriptionService.deleteRecipient(recId);
            System.assertEquals(0, CR_SubscriptionService.listRecipients(subId).size(), 'Recipient should be deleted.');

            CR_SubscriptionService.deleteSubscription(subId);
            System.assertEquals(0, CR_SubscriptionService.listSubscriptions().size(), 'Subscription should be deleted.');
        }
    }

    @isTest
    static void upsertSubscriptionRejectsBothAssets() {
        User admin = adminUser();
        System.runAs(admin) {
            Report_Definition__c report = broadcastReport();
            Dashboard__c d = broadcastDashboardWithComponent(report.Id);
            Boolean threw = false;
            try {
                CR_SubscriptionService.upsertSubscription(JSON.serialize(new Map<String, Object>{
                    'reportDefinitionId' => report.Id,
                    'dashboardId' => d.Id,
                    'frequency' => 'Daily',
                    'hourOfDay' => 6,
                    'active' => true
                }));
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assertEquals(true, threw, 'Exactly_One_Asset validation should surface as an AuraHandledException.');
        }
    }

    @isTest
    static void listSubscribableAssetsReturnsBroadcastFlag() {
        Report_Definition__c report = broadcastReport();
        Test.startTest();
        List<CR_SubscriptionService.AssetOption> options = CR_SubscriptionService.listSubscribableAssets();
        Test.stopTest();
        Boolean foundReport = false;
        for (CR_SubscriptionService.AssetOption o : options) {
            if (o.id == report.Id) {
                foundReport = true;
                System.assertEquals('Report', o.assetType, 'Report asset type should be tagged.');
                System.assertEquals(true, o.broadcastSafe, 'Broadcast-safe flag should reflect the report.');
            }
        }
        System.assertEquals(true, foundReport, 'The broadcast-safe report should appear in the asset picker.');
    }

    @isTest
    static void adminMethodsRequirePermission() {
        User noPerm = userWithoutPermission();
        System.runAs(noPerm) {
            Boolean listThrew = false;
            try {
                CR_SubscriptionService.listSubscriptions();
            } catch (AuraHandledException e) {
                listThrew = true;
            }
            System.assertEquals(true, listThrew, 'listSubscriptions must reject callers without Manage_Report_Subscriptions.');

            Boolean upsertSubThrew = false;
            try {
                CR_SubscriptionService.upsertSubscription('{"frequency":"Daily"}');
            } catch (AuraHandledException e) {
                upsertSubThrew = true;
            }
            System.assertEquals(true, upsertSubThrew, 'upsertSubscription must reject callers without permission.');

            Boolean upsertRecThrew = false;
            try {
                CR_SubscriptionService.upsertRecipient('{"recipientType":"User"}');
            } catch (AuraHandledException e) {
                upsertRecThrew = true;
            }
            System.assertEquals(true, upsertRecThrew, 'upsertRecipient must reject callers without permission.');
        }
    }

    // ---- Filter-override hardening ----

    @isTest
    static void upsertSubscriptionRejectsBadFilterOverride() {
        User admin = adminUser();
        System.runAs(admin) {
            Report_Definition__c report = broadcastReport();
            Boolean threw = false;
            try {
                CR_SubscriptionService.upsertSubscription(JSON.serialize(new Map<String, Object>{
                    'reportDefinitionId' => report.Id,
                    'frequency' => 'Daily',
                    'hourOfDay' => 6,
                    'active' => true,
                    // Structurally valid but references a field that doesn't exist ->
                    // exercises the full (field-level) save-time validator.
                    'filterOverrideJson' => '[{"field":"Totally_Bogus_Field__c","operator":"=","value":"x"}]'
                }));
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assertEquals(true, threw, 'An invalid filter override must be rejected at save time.');
        }
    }

    @isTest
    static void sendFailsSoftOnMalformedFilterOverride() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = broadcastReport();
        CR_Subscription__c sub = newSub(report.Id, 'Daily');
        // Inserted directly (bypassing the service validator) to simulate an override
        // saved before validation existed. Missing "operator" used to NPE the send.
        sub.Filter_Override_JSON__c = '[{"field":"StageName","value":"x"}]';
        insert sub;
        addRecipient(sub.Id);

        Test.startTest();
        new CR_SubscriptionSendQueueable(sub.Id).execute(null);
        Test.stopTest();

        sub = [SELECT Last_Status__c, Last_Message__c FROM CR_Subscription__c WHERE Id = :sub.Id];
        System.assertEquals('Failed', sub.Last_Status__c, 'A malformed override must fail soft, not crash the job.');
        System.assert(sub.Last_Message__c != null && sub.Last_Message__c.contains('Invalid filter override'),
            'The failure message should name the invalid override. Got: ' + sub.Last_Message__c);
    }

    @isTest
    static void listRecipientsBackfillsGroupName() {
        Group g = new Group(Name = 'CR Backfill Team', Type = 'Regular');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert g;
        }
        User admin = adminUser();
        System.runAs(admin) {
            Report_Definition__c report = broadcastReport();
            CR_Subscription__c sub = newSub(report.Id, 'Daily');
            insert sub;
            // Recipient saved with only the Group Id (name not captured) — the bug scenario.
            insert new CR_Subscription_Recipient__c(
                Subscription__c = sub.Id, Recipient_Type__c = 'Public Group', Group_Id__c = g.Id
            );
            List<CR_SubscriptionService.RecipientDto> recs = CR_SubscriptionService.listRecipients(sub.Id);
            System.assertEquals(1, recs.size(), 'One recipient should be listed.');
            System.assertEquals('CR Backfill Team', recs[0].groupName,
                'Group name should be backfilled from the stored Group Id.');
        }
    }
}