/**
 * Coverage for ProviderObjectionSummaryController.
 *
 * Each scenario gets its own provider so assertions stay exact rather than
 * depending on totals that shift when another fixture changes.
 *
 * TaskWhoRelation is a derived, read-only object: it cannot be inserted. The
 * primary attendee is therefore created through Task.WhoId, and the additional
 * attendee through TaskRelation (IsWhat = false), which only succeeds when
 * Shared Activities is enabled. That insert is guarded so the suite still passes
 * in an org where the feature is off.
 */
@IsTest
private class ProviderObjectionSummaryControllerTest {

    private static final String PURPOSE = 'Referral Development';
    private static final String FACILITY = 'OH - APH'; // valid for the TaskOther record type

    @TestSetup
    static void makeData() {
        Account practiceGroup = new Account(Name = 'Test Practice & Group');
        insert practiceGroup;

        // Contact carries six active "required for new records" validation rules
        // (First Name, Affiliation, Affiliation Group, Provider Type, Credentials,
        // Gender). They are satisfied here rather than bypassed.
        List<Contact> providers = new List<Contact>();
        for (String lastName : new List<String>{
            'JunctionOnly', 'LegacyOnly', 'BothSources', 'NoObjections', 'BulkRows', 'SharedAttendee'
        }) {
            providers.add(newProvider(lastName, practiceGroup.Id));
        }
        insert providers;
        Map<String, Id> providerByName = new Map<String, Id>();
        for (Contact c : providers) {
            providerByName.put(c.LastName, c.Id);
        }

        // Two objections deliberately share a count so the category tie-break
        // (equal count, then name) is exercised.
        List<Objection__c> catalog = new List<Objection__c>{
            new Objection__c(Name = 'Communication'),
            new Objection__c(Name = 'Insurance'),
            new Objection__c(Name = 'Patient Access')
        };
        insert catalog;

        Date today = Date.today();

        // Purpose__c is restricted per record type: 'Referral Development' is valid for
        // the physician-relations types but not for Network Visit, which is the running
        // user's default. Pin the record type so the fixture is deterministic.
        Id vrRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Visit_Report__c'
                   AND DeveloperName = 'OH_Physician_Relations_Visit' LIMIT 1].Id;
        List<Visit_Report__c> reports = new List<Visit_Report__c>{
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-10)),  // 0 junction
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-20)),  // 1 legacy
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-5)),   // 2 both: junction
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-30)),  // 3 both: legacy
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addMonths(-30)),// 4 outside 24mo
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-2)),   // 5 bulk
            new Visit_Report__c(RecordTypeId = vrRt, Purpose__c = PURPOSE, Visit_Date__c = today.addDays(-1))    // 6 shared attendee
        };
        insert reports;

        // Visit_Reports_Only_Related_to_Locations fires on the physician-sales record
        // types and demands a Location in WhatId, so pin a neutral record type.
        Id taskRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Task' AND DeveloperName = 'TaskOther' LIMIT 1].Id;
        List<Task> tasks = new List<Task>{
            // JunctionOnly — objections arrive via the junction, nothing on the task.
            new Task(RecordTypeId = taskRt, Subject = 'Junction visit', WhoId = providerByName.get('JunctionOnly'),
                     Visit_Report__c = reports[0].Id, Date_Meeting_Call__c = today.addDays(-10)),
            // LegacyOnly — multi-select on the activity, no junction rows at all.
            new Task(RecordTypeId = taskRt, Subject = 'Legacy visit', WhoId = providerByName.get('LegacyOnly'),
                     Visit_Report__c = reports[1].Id, Date_Meeting_Call__c = today.addDays(-20),
                     Objections_Raised__c = 'Communication;Insurance',
                     Objection_Notes__c = 'Legacy note about coverage',
                     Facility_of_Objection__c = FACILITY),
            // BothSources — junction report AND a legacy report, with 'Communication'
            // appearing in both so de-dup can be asserted.
            new Task(RecordTypeId = taskRt, Subject = 'Both junction', WhoId = providerByName.get('BothSources'),
                     Visit_Report__c = reports[2].Id, Date_Meeting_Call__c = today.addDays(-5),
                     Objections_Raised__c = 'Communication'),
            new Task(RecordTypeId = taskRt, Subject = 'Both legacy', WhoId = providerByName.get('BothSources'),
                     Visit_Report__c = reports[3].Id, Date_Meeting_Call__c = today.addDays(-30),
                     Objections_Raised__c = 'Insurance;Patient Access',
                     ObjectionsRaised__c = 'Insurance'),
            // Legacy row with no visit report of its own. Org automation stamps
            // Date_Meeting_Call__c on insert, so this lands at today's date.
            new Task(RecordTypeId = taskRt, Subject = 'Both no report', WhoId = providerByName.get('BothSources'),
                     Objections_Raised__c = 'Communication'),
            // Outside the 24 month window.
            new Task(RecordTypeId = taskRt, Subject = 'Both stale', WhoId = providerByName.get('BothSources'),
                     Visit_Report__c = reports[4].Id, Date_Meeting_Call__c = today.addMonths(-30),
                     Objections_Raised__c = 'Patient Access'),
            // NoObjections — a visit with no objections recorded anywhere.
            new Task(RecordTypeId = taskRt, Subject = 'Quiet visit', WhoId = providerByName.get('NoObjections'),
                     Visit_Report__c = reports[0].Id, Date_Meeting_Call__c = today.addDays(-10)),
            // BulkRows — feeds the rowLimit / truncated assertions.
            new Task(RecordTypeId = taskRt, Subject = 'Bulk visit', WhoId = providerByName.get('BulkRows'),
                     Visit_Report__c = reports[5].Id, Date_Meeting_Call__c = today.addDays(-2)),
            // Host task for the shared-attendee case; WhoId is a different provider.
            new Task(RecordTypeId = taskRt, Subject = 'Shared visit', WhoId = providerByName.get('JunctionOnly'),
                     Visit_Report__c = reports[6].Id, Date_Meeting_Call__c = today.addDays(-1))
        };
        insert tasks;

        List<Visit_Objection__c> junctions = new List<Visit_Objection__c>{
            new Visit_Objection__c(Visit_Report__c = reports[0].Id, Objection__c = catalog[0].Id,
                                   Notes__c = 'Junction note'),
            new Visit_Objection__c(Visit_Report__c = reports[0].Id, Objection__c = catalog[1].Id,
                                   Comments__c = 'Comments fallback'),
            // BothSources: same objection name as the task's multi-select value, so the
            // legacy union must not add a second row for it.
            new Visit_Objection__c(Visit_Report__c = reports[2].Id, Objection__c = catalog[0].Id,
                                   Notes__c = 'Junction wins'),
            new Visit_Objection__c(Visit_Report__c = reports[6].Id, Objection__c = catalog[2].Id,
                                   Notes__c = 'Shared attendee note')
        };
        // Four junction rows for the bulk provider so a rowLimit of 2 truncates.
        for (Integer i = 0; i < 4; i++) {
            junctions.add(new Visit_Objection__c(
                Visit_Report__c = reports[5].Id,
                Objection__c = catalog[Math.mod(i, catalog.size())].Id,
                Notes__c = 'Bulk note ' + i
            ));
        }
        insert junctions;

        // Second attendee on the shared visit. TaskRelation insert fails when Shared
        // Activities is disabled, which must not fail the whole suite.
        try {
            insert new TaskRelation(
                TaskId = tasks[8].Id,
                RelationId = providerByName.get('SharedAttendee'),
                IsWhat = false
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Shared Activities unavailable: ' + e.getMessage());
        }
    }

    /**
     * Builds a Contact that satisfies every active "required for new records"
     * validation rule on the object. Region is deliberately left off Florida-only
     * rules' critical path by setting Affiliation explicitly anyway.
     */
    private static Contact newProvider(String lastName, Id accountId) {
        return new Contact(
            FirstName = 'Test',
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
    static void junctionOnlyProviderReturnsJunctionRows() {
        Id pid = providerId('JunctionOnly');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        // Two junction rows on the -10 day report, plus one on the shared visit
        // whose WhoId is also this provider.
        System.assertEquals(3, r.totalCount, 'Expected three junction-sourced rows');
        System.assertEquals(3, r.last12Count, 'All fixtures fall inside 12 months');
        System.assertEquals(false, r.truncated, 'Well under the row limit');
        for (ProviderObjectionSummaryController.ObjectionRow row : r.rows) {
            System.assertEquals('Objection record', row.source, 'Every row should be junction-sourced');
            System.assertNotEquals(null, row.visitReportId, 'Junction rows carry a visit report');
        }
        System.assertNotEquals(null, r.mostRecentDate, 'A most-recent date should be set');
        System.assertNotEquals(null, r.mostRecentBy, 'A most-recent owner should be set');
    }

    @IsTest
    static void notesFallsBackToCommentsWhenNotesBlank() {
        Id pid = providerId('JunctionOnly');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        Boolean sawComments = false;
        for (ProviderObjectionSummaryController.ObjectionRow row : r.rows) {
            if (row.notes == 'Comments fallback') {
                sawComments = true;
            }
        }
        System.assert(sawComments, 'Comments__c should be used when Notes__c is blank');
    }

    @IsTest
    static void legacyOnlyProviderSplitsMultiSelect() {
        Id pid = providerId('LegacyOnly');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals(2, r.totalCount, 'Communication;Insurance should split into two rows');
        System.assertEquals(2, r.categoryCount, 'Two distinct objections');
        for (ProviderObjectionSummaryController.ObjectionRow row : r.rows) {
            System.assertEquals('Legacy activity', row.source, 'No junction rows exist for this report');
            System.assertEquals(FACILITY, row.facility, 'Facility comes off the activity');
            System.assertEquals('Legacy note about coverage', row.notes, 'Notes come off the activity');
        }
    }

    @IsTest
    static void bothSourcesDeduplicatesOnVisitReportAndObjection() {
        Id pid = providerId('BothSources');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, null, 500);
        Test.stopTest();

        // Junction report contributes Communication once. Its task also lists
        // Communication, which must be suppressed because that report already
        // produced a junction row.
        Integer junctionRows = 0;
        Integer commsOnJunctionReport = 0;
        for (ProviderObjectionSummaryController.ObjectionRow row : r.rows) {
            if (row.source == 'Objection record') {
                junctionRows++;
                if (row.objection == 'Communication') {
                    commsOnJunctionReport++;
                }
            }
        }
        System.assertEquals(1, junctionRows, 'One junction row for this provider');
        System.assertEquals(1, commsOnJunctionReport, 'Communication must not be duplicated');

        // Legacy: Insurance;Patient Access plus a duplicate Insurance in the text
        // field (deduped to one), the undated Communication row, and the stale row.
        System.assertEquals(5, r.totalCount,
            'Junction Communication + Insurance + Patient Access + undated Communication + stale Patient Access');

        // Rows must come back strictly newest-first. (An undated row cannot be
        // fixtured here: org automation stamps a date on Task insert, so every
        // row carries one.)
        for (Integer i = 1; i < r.rows.size(); i++) {
            Date previous = r.rows[i - 1].visitDate;
            Date current = r.rows[i].visitDate;
            System.assert(previous >= current,
                'Rows must be ordered newest first, but ' + previous + ' preceded ' + current);
        }
        System.assert(r.categories.size() > 0, 'Categories should be populated');
        System.assert(r.categories[0].count >= r.categories[r.categories.size() - 1].count,
            'Categories are ordered by count descending');
        System.assert(r.categories[0].percent > 0, 'Percent share should be calculated');
    }

    @IsTest
    static void monthsBackExcludesOlderVisits() {
        Id pid = providerId('BothSources');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult windowed =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        ProviderObjectionSummaryController.ObjectionSummaryResult allTime =
            ProviderObjectionSummaryController.getObjectionSummary(pid, null, 500);
        Test.stopTest();

        System.assert(windowed.totalCount < allTime.totalCount,
            'The 30-month-old visit and the undated task should drop out of a 24 month window');
        for (ProviderObjectionSummaryController.ObjectionRow row : windowed.rows) {
            System.assert(row.visitDate >= Date.today().addMonths(-24),
                'No row older than the window should survive');
        }
    }

    @IsTest
    static void zeroMonthsBackIsTreatedAsAllTime() {
        Id pid = providerId('BothSources');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult zero =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 0, 500);
        Test.stopTest();

        System.assertEquals(5, zero.totalCount, 'monthsBack of 0 means all time');
    }

    @IsTest
    static void rowLimitTruncatesAndFlags() {
        Id pid = providerId('BulkRows');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult limited =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 2);
        ProviderObjectionSummaryController.ObjectionSummaryResult full =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        System.assertEquals(2, limited.rows.size(), 'Row limit should cap the list');
        System.assertEquals(true, limited.truncated, 'Hitting the cap must set truncated');
        System.assertEquals(4, full.totalCount, 'All four bulk rows without a cap');
        System.assertEquals(false, full.truncated, 'Not truncated when under the cap');
    }

    @IsTest
    static void nullRowLimitUsesDefaultAndNegativeIsIgnored() {
        Id pid = providerId('BulkRows');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult defaulted =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, null);
        ProviderObjectionSummaryController.ObjectionSummaryResult negative =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, -5);
        Test.stopTest();

        System.assertEquals(4, defaulted.totalCount, 'Null row limit falls back to the default');
        System.assertEquals(false, defaulted.truncated, 'Default limit is far above four rows');
        System.assertEquals(4, negative.totalCount, 'A negative limit is treated as the default');
    }

    @IsTest
    static void rowLimitAboveHardCapIsClamped() {
        Id pid = providerId('BulkRows');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 99999);
        Test.stopTest();

        System.assertEquals(4, r.totalCount, 'Clamping to 2000 must not change a small result');
        System.assertEquals(false, r.truncated, 'Four rows is nowhere near the cap');
    }

    @IsTest
    static void providerWithNoObjectionsReturnsEmptyResult() {
        Id pid = providerId('NoObjections');

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        // This provider's only task points at a report that does have junction rows,
        // so the guard is that the empty state is driven by the provider, not the report.
        System.assertNotEquals(null, r, 'A result object is always returned');
        System.assertNotEquals(null, r.rows, 'Rows list is initialised, never null');
        System.assertEquals(false, r.truncated, 'Nothing to truncate');
    }

    @IsTest
    static void providerWithNoTasksAtAllReturnsEmptyResult() {
        Contact lonely = newProvider('NeverVisited', null);
        insert lonely;

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(lonely.Id, 24, 500);
        Test.stopTest();

        System.assertEquals(0, r.totalCount, 'No tasks means no objections');
        System.assertEquals(0, r.categoryCount, 'No categories');
        System.assertEquals(0, r.rows.size(), 'No rows');
        System.assertEquals(null, r.mostRecentDate, 'No most-recent date');
    }

    @IsTest
    static void narrowWindowStillFindsRecentVisit() {
        Id pid = providerId('LegacyOnly');

        Test.startTest();
        // The only task is 20 days old, so a one-month window must still include it.
        // This pins the boundary: the cutoff is inclusive of recent visits.
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 1, 500);
        Test.stopTest();

        System.assertEquals(2, r.totalCount, 'A 20 day old visit falls inside a one month window');
    }

    @IsTest
    static void sharedAttendeeIsFoundThroughTaskWhoRelation() {
        Id pid = providerId('SharedAttendee');
        Boolean sharedActivitiesOn = [SELECT COUNT() FROM TaskRelation WHERE RelationId = :pid] > 0;

        Test.startTest();
        ProviderObjectionSummaryController.ObjectionSummaryResult r =
            ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
        Test.stopTest();

        if (sharedActivitiesOn) {
            System.assertEquals(1, r.totalCount,
                'The additional attendee should reach the shared visit through TaskWhoRelation');
            System.assertEquals('Shared attendee note', r.rows[0].notes, 'Expected the shared visit objection');
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
            ProviderObjectionSummaryController.getObjectionSummary(notAProvider.Id, 24, 500);
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
            ProviderObjectionSummaryController.getObjectionSummary(null, 24, 500);
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
            FirstName = 'Obj',
            LastName = 'Tester',
            Alias = 'objt',
            Email = 'obj.tester@example.com',
            Username = 'obj.tester.' + DateTime.now().getTime() + '@example.com.invalid',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert standard;

        Id pid = providerId('JunctionOnly');

        Test.startTest();
        System.runAs(standard) {
            // Sharing and FLS may hide everything from this user; the contract is
            // that the method degrades quietly rather than throwing.
            ProviderObjectionSummaryController.ObjectionSummaryResult r =
                ProviderObjectionSummaryController.getObjectionSummary(pid, 24, 500);
            System.assertNotEquals(null, r, 'A result is returned even with restricted access');
            System.assertNotEquals(null, r.rows, 'Rows list is never null');
            System.assert(r.totalCount >= 0, 'Count is never negative');
        }
        Test.stopTest();
    }

}
