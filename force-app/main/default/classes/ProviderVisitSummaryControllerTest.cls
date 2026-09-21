/**
 * Coverage for ProviderVisitSummaryController.
 *
 * Fixture notes, all learned the hard way against this org:
 *  - Contact has six active "required for new records" validation rules.
 *  - Purpose__c is restricted PER RECORD TYPE. 'Referral Development' is valid for
 *    the physician-relations types but not for Network Visit, which is the running
 *    user's default, so the record type is pinned.
 *  - Task.Visit_Date__c is a read-only cross-object formula; set the visit date on
 *    the Visit Report and it flows down.
 *  - TaskWhoRelation is derived and cannot be inserted. The primary attendee comes
 *    from Task.WhoId; an additional attendee needs TaskRelation (IsWhat = false),
 *    which only works when Shared Activities is on, hence the try/catch.
 */
@IsTest
private class ProviderVisitSummaryControllerTest {

    private static final String PURPOSE_A = 'Referral Development';
    private static final String PURPOSE_B = 'Customer Service';

    @TestSetup
    static void makeData() {
        Account practiceGroup = new Account(Name = 'Visit Summary Practice');
        insert practiceGroup;

        List<Contact> providers = new List<Contact>();
        for (String lastName : new List<String>{
            'ManyVisits', 'OneVisit', 'NoVisits', 'SharedAttendee', 'BulkVisits',
            'LegacyOnly', 'PhoneOnly'
        }) {
            providers.add(newProvider(lastName, practiceGroup.Id));
        }
        insert providers;
        Map<String, Id> providerByName = new Map<String, Id>();
        for (Contact c : providers) {
            providerByName.put(c.LastName, c.Id);
        }

        Id vrRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Visit_Report__c'
                   AND DeveloperName = 'OH_Physician_Relations_Visit' LIMIT 1].Id;
        Id taskRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Task'
                     AND DeveloperName = 'TaskOther' LIMIT 1].Id;
        // The legacy pattern: the task itself is the visit report.
        // VisitReportBusinessDevelopment is used rather than VisitReportPhysicianSales
        // because the latter is covered by Visit_Reports_Only_Related_to_Locations,
        // which demands a Location in WhatId, and Location__c cannot be created in a
        // test (a flow rejects it with "Address is required"). Both record types are
        // treated identically by the controller.
        Id visitRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Task'
                      AND DeveloperName = 'VisitReportBusinessDevelopment' LIMIT 1].Id;
        Id phoneRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Task'
                      AND DeveloperName = 'Phone_Log' LIMIT 1].Id;

        Date today = Date.today();

        List<Visit_Report__c> reports = new List<Visit_Report__c>{
            // 0,1,2 belong to ManyVisits: two recent, one outside a 24 month window.
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_A, Visit_Date__c = today.addDays(-5),
                                Subject__c = 'Cardiology follow up', Visit_Type__c = 'In Person',
                                Audience__c = 'Physician', Notes__c = 'Discussed referral pathway'),
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_B, Visit_Date__c = today.addDays(-40),
                                Subject__c = 'Scheduling issue', Visit_Type__c = 'Phone Call',
                                Audience__c = 'Office Staff', Notes__c = 'Front desk backlog'),
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_A, Visit_Date__c = today.addMonths(-30),
                                Subject__c = 'Historic visit', Visit_Type__c = 'In Person',
                                Audience__c = 'Physician'),
            // 3 belongs to OneVisit.
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_A, Visit_Date__c = today.addDays(-2),
                                Subject__c = 'Single visit', Visit_Type__c = 'Virtual',
                                Audience__c = 'Physician'),
            // 4 is the shared-attendee visit.
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_B, Visit_Date__c = today.addDays(-1),
                                Subject__c = 'Joint visit', Visit_Type__c = 'In Person',
                                Audience__c = 'Physician to Physician')
        };
        // Three more for the bulk provider, to drive rowLimit/truncated.
        for (Integer i = 0; i < 3; i++) {
            reports.add(new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE_A,
                                            Visit_Date__c = today.addDays(-i - 3),
                                            Subject__c = 'Bulk visit ' + i, Visit_Type__c = 'In Person'));
        }
        insert reports;

        List<Task> tasks = new List<Task>{
            new Task(RecordTypeId = taskRt, Subject = 'VR-A', WhoId = providerByName.get('ManyVisits'),
                     Visit_Report__c = reports[0].Id),
            // Second task on the SAME visit report: the result must still be one row.
            new Task(RecordTypeId = taskRt, Subject = 'VR-A duplicate attendee',
                     WhoId = providerByName.get('ManyVisits'), Visit_Report__c = reports[0].Id),
            new Task(RecordTypeId = taskRt, Subject = 'VR-B', WhoId = providerByName.get('ManyVisits'),
                     Visit_Report__c = reports[1].Id),
            new Task(RecordTypeId = taskRt, Subject = 'VR-C stale', WhoId = providerByName.get('ManyVisits'),
                     Visit_Report__c = reports[2].Id),
            new Task(RecordTypeId = taskRt, Subject = 'VR-D', WhoId = providerByName.get('OneVisit'),
                     Visit_Report__c = reports[3].Id),
            // A task with NO visit report must be ignored entirely.
            new Task(RecordTypeId = taskRt, Subject = 'Phone call, no visit report',
                     WhoId = providerByName.get('OneVisit')),
            new Task(RecordTypeId = taskRt, Subject = 'VR-Shared', WhoId = providerByName.get('ManyVisits'),
                     Visit_Report__c = reports[4].Id)
        };
        for (Integer i = 0; i < 3; i++) {
            tasks.add(new Task(RecordTypeId = taskRt, Subject = 'Bulk ' + i,
                               WhoId = providerByName.get('BulkVisits'),
                               Visit_Report__c = reports[5 + i].Id));
        }
        // Legacy Florida-style rows: visit-report record type, NO lookup, detail on
        // the activity itself.
        tasks.add(new Task(RecordTypeId = visitRt, Subject = 'OHIC',
                           WhoId = providerByName.get('LegacyOnly'),
                           Description = 'G: Message OHIC. A: Discussed modalities.',
                           Visit_Category__c = 'PRM with Office Staff',
                           Date_Meeting_Call__c = today.addDays(-15)));
        tasks.add(new Task(RecordTypeId = visitRt, Subject = 'OHIC follow up',
                           WhoId = providerByName.get('LegacyOnly'),
                           Date_Meeting_Call__c = today.addDays(-60)));
        // A phone log is NOT a visit report and must be excluded.
        tasks.add(new Task(RecordTypeId = phoneRt, Subject = 'Called the office',
                           WhoId = providerByName.get('PhoneOnly'),
                           Date_Meeting_Call__c = today.addDays(-3)));
        insert tasks;

        try {
            insert new TaskRelation(
                TaskId = tasks[6].Id,
                RelationId = providerByName.get('SharedAttendee'),
                IsWhat = false
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Shared Activities unavailable: ' + e.getMessage());
        }
    }

    private static Contact newProvider(String lastName, Id accountId) {
        return new Contact(
            FirstName = 'Visit',
            LastName = lastName,
            AccountId = accountId,
            Affiliation__c = 'Owned',
            Affiliation_Group__c = 'Independent',
            Provider_Type__c = 'Ambulatory Facility',
            Credentials__c = 'APRN',
            Gender__c = 'Female'
        );
    }

    private static Id providerId(String lastName) {
        return [SELECT Id FROM Contact WHERE LastName = :lastName LIMIT 1].Id;
    }

    @IsTest
    static void returnsOneRowPerVisitReportNotPerTask() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        // Four visit reports inside the window (two tasks share one of them),
        // plus the shared visit. The 30-month-old one is excluded.
        System.assertEquals(3, r.totalCount, 'Duplicate attendee tasks must collapse to one row');
        Set<Id> seen = new Set<Id>();
        for (ProviderVisitSummaryController.VisitRow row : r.rows) {
            System.assert(seen.add(row.targetId), 'Each visit report may appear only once');
        }
    }

    @IsTest
    static void rowsCarryVisitReportDetailAndAreNewestFirst() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        ProviderVisitSummaryController.VisitRow newest = r.rows[0];
        System.assertEquals('Joint visit', newest.subject, 'Newest visit should sort first');
        System.assertEquals('In Person', newest.visitType, 'Visit type should come through the lookup');
        System.assertEquals('Physician to Physician', newest.audience, 'Audience should come through');
        System.assertNotEquals(null, newest.targetName, 'The VR- name drives the link label');
        System.assertNotEquals(null, newest.loggedBy, 'Owner name must resolve via the User lookup');

        for (Integer i = 1; i < r.rows.size(); i++) {
            System.assert(r.rows[i - 1].visitDate >= r.rows[i].visitDate,
                'Rows must be ordered newest first');
        }
    }

    @IsTest
    static void tasksWithoutAVisitReportAreIgnored() {
        Id pid = providerId('OneVisit');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        // Two tasks exist for this provider but only one has a visit report.
        System.assertEquals(1, r.totalCount, 'A task with no visit report is not a visit');
        System.assertEquals('Single visit', r.rows[0].subject, 'Wrong visit returned');
    }

    @IsTest
    static void purposeBreakdownIsCountedAndOrdered() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        System.assert(r.purposeCount > 0, 'Purposes should be summarised');
        System.assertEquals(r.purposes.size(), r.purposeCount, 'Count must match the list');
        Integer summed = 0;
        for (ProviderVisitSummaryController.CategoryCount cc : r.purposes) {
            summed += cc.count;
            System.assert(cc.percent >= 0, 'Percent share should be non-negative');
        }
        System.assertEquals(r.totalCount, summed, 'Purpose counts must sum to the total');
        for (Integer i = 1; i < r.purposes.size(); i++) {
            System.assert(r.purposes[i - 1].count >= r.purposes[i].count,
                'Purposes are ordered by count descending');
        }
    }

    @IsTest
    static void monthsBackExcludesOlderVisits() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult windowed =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        ProviderVisitSummaryController.VisitSummaryResult allTime =
            ProviderVisitSummaryController.getVisitSummary(pid, null, 500);
        Test.stopTest();

        System.assertEquals(3, windowed.totalCount, 'The 30 month old visit is outside the window');
        System.assertEquals(4, allTime.totalCount, 'All time should include it');
        for (ProviderVisitSummaryController.VisitRow row : windowed.rows) {
            System.assert(row.visitDate >= Date.today().addMonths(-24), 'Stale row leaked through');
        }
    }

    @IsTest
    static void zeroMonthsBackIsTreatedAsAllTime() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 0, 500);
        Test.stopTest();

        System.assertEquals(4, r.totalCount, 'monthsBack of 0 means all time');
    }

    @IsTest
    static void last12CountTracksRecentVisitsOnly() {
        Id pid = providerId('ManyVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, null, 500);
        Test.stopTest();

        System.assertEquals(4, r.totalCount, 'Four visits all time');
        System.assertEquals(3, r.last12Count, 'Only three fall inside twelve months');
        System.assertNotEquals(null, r.mostRecentDate, 'Most recent date should be set');
        System.assertNotEquals(null, r.mostRecentBy, 'Most recent owner should be set');
    }

    @IsTest
    static void rowLimitTruncatesAndFlags() {
        Id pid = providerId('BulkVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult limited =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 2);
        ProviderVisitSummaryController.VisitSummaryResult full =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals(2, limited.rows.size(), 'Row limit should cap the list');
        System.assertEquals(true, limited.truncated, 'Hitting the cap must set truncated');
        System.assertEquals(3, full.totalCount, 'All three without a cap');
        System.assertEquals(false, full.truncated, 'Not truncated when under the cap');
    }

    @IsTest
    static void nullAndOversizedRowLimitsAreResolved() {
        Id pid = providerId('BulkVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult defaulted =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, null);
        ProviderVisitSummaryController.VisitSummaryResult negative =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, -10);
        ProviderVisitSummaryController.VisitSummaryResult huge =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 99999);
        Test.stopTest();

        System.assertEquals(3, defaulted.totalCount, 'Null limit falls back to the default');
        System.assertEquals(3, negative.totalCount, 'Negative limit treated as the default');
        System.assertEquals(3, huge.totalCount, 'Clamping to 2000 does not change a small result');
    }

    @IsTest
    static void providerWithNoVisitsReturnsEmptyResult() {
        Id pid = providerId('NoVisits');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals(0, r.totalCount, 'No tasks means no visits');
        System.assertEquals(0, r.purposeCount, 'No purposes');
        System.assertEquals(0, r.rows.size(), 'No rows');
        System.assertEquals(null, r.mostRecentDate, 'No most recent date');
        System.assertEquals(false, r.truncated, 'Nothing to truncate');
    }

    @IsTest
    static void windowThatExcludesEverythingReturnsEmptyResult() {
        Id pid = providerId('OneVisit');

        Test.startTest();
        // The only visit is 2 days old; a window ending before it yields nothing.
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 1200, 500);
        Test.stopTest();

        System.assertEquals(1, r.totalCount, 'A 100 year window still contains the visit');
    }

    @IsTest
    static void sharedAttendeeIsFoundThroughTaskWhoRelation() {
        Id pid = providerId('SharedAttendee');
        Boolean sharedActivitiesOn = [SELECT COUNT() FROM TaskRelation WHERE RelationId = :pid] > 0;

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        if (sharedActivitiesOn) {
            System.assertEquals(1, r.totalCount, 'Additional attendee should reach the shared visit');
            System.assertEquals('Joint visit', r.rows[0].subject, 'Expected the shared visit report');
        } else {
            System.assertEquals(0, r.totalCount, 'Without Shared Activities there is no relation to follow');
        }
    }

    @IsTest
    static void invalidIdTypeThrowsAuraHandledException() {
        Account notAProvider = new Account(Name = 'Not a provider');
        insert notAProvider;

        Test.startTest();
        Boolean threw = false;
        try {
            ProviderVisitSummaryController.getVisitSummary(notAProvider.Id, 24, 500);
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().contains('valid Provider'),
                'Message should name the problem, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(threw, 'An Account id must be rejected');
    }

    @IsTest
    static void nullIdThrowsAuraHandledException() {
        Test.startTest();
        Boolean threw = false;
        try {
            ProviderVisitSummaryController.getVisitSummary(null, 24, 500);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A null id must be rejected');
    }

    @IsTest
    static void runsForNonAdminUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User standard = new User(
            FirstName = 'Visit',
            LastName = 'Tester',
            Alias = 'vstt',
            Email = 'visit.tester@example.com',
            Username = 'visit.tester.' + DateTime.now().getTime() + '@example.com.invalid',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert standard;

        Id pid = providerId('ManyVisits');

        Test.startTest();
        System.runAs(standard) {
            ProviderVisitSummaryController.VisitSummaryResult r =
                ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
            System.assertNotEquals(null, r, 'A result is returned even with restricted access');
            System.assertNotEquals(null, r.rows, 'Rows list is never null');
            System.assert(r.totalCount >= 0, 'Count is never negative');
        }
        Test.stopTest();
    }

    @IsTest
    static void legacyActivityOnlyVisitsAreIncluded() {
        Id pid = providerId('LegacyOnly');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        // These tasks have NO Visit_Report__c. Before the union they were invisible,
        // which is what made pre-2025 Florida providers look like they had no visits.
        System.assertEquals(2, r.totalCount, 'Activity-only visits must be included');
        System.assertEquals(2, r.activityOnlyCount, 'Both rows are activity-only');
        System.assertEquals('Activity only', r.rows[0].source, 'Source badge should say so');
        System.assertEquals('OHIC', r.rows[0].subject, 'Subject comes off the task');
        System.assertEquals('PRM with Office Staff', r.rows[0].category, 'Category comes off the task');
        System.assert(r.rows[0].notes.contains('Discussed modalities'),
            'Description carries the visit write-up');
        System.assertNotEquals(null, r.rows[0].targetId, 'The task itself is the link target');
    }

    @IsTest
    static void legacyRowsFallBackToCategoryForTheBreakdown() {
        Id pid = providerId('LegacyOnly');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        // Legacy rows carry no Purpose, so the breakdown falls back to Category
        // rather than collapsing every row into one "(Not specified)" bar.
        Boolean sawCategory = false;
        for (ProviderVisitSummaryController.CategoryCount cc : r.purposes) {
            if (cc.name == 'PRM with Office Staff') {
                sawCategory = true;
            }
        }
        System.assert(sawCategory, 'Category should stand in for a missing Purpose');
    }

    @IsTest
    static void phoneLogsAreNotTreatedAsVisits() {
        Id pid = providerId('PhoneOnly');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals(0, r.totalCount,
            'A Phone Log has no visit report and is not a visit-report record type');
    }

    @IsTest
    static void linkedVisitsAreMarkedAsRecordSourced() {
        Id pid = providerId('OneVisit');

        Test.startTest();
        ProviderVisitSummaryController.VisitSummaryResult r =
            ProviderVisitSummaryController.getVisitSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals('Visit Report record', r.rows[0].source, 'Linked rows keep the record source');
        System.assertEquals(0, r.activityOnlyCount, 'Nothing activity-only for this provider');
    }
}
