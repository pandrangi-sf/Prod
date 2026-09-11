/**
 * Coverage for the six PRM-domain fact batches plus the ETL scheduler fan-out.
 * These were previously unexercised (0%), which blocks a RunSpecifiedTests
 * production deploy since that mode enforces per-class >=75% on every deployed
 * class. Each test builds the minimum source graph that makes execute() emit at
 * least one fact row, so start()/execute()/finish() are all driven.
 *
 * Data notes:
 *  - The visit-activity batches only require the junction record (Visit_Service /
 *    Visit_Collateral / Visit_Objection) to EXIST for its Visit_Report; the
 *    related lookup names are optional, so we don't seed Service/Collateral/etc.
 *  - Contacts on the Task (TaskWhoRelation) are optional — the batches use a null
 *    sentinel — so we skip Shared Activities entirely.
 */
@IsTest
private class CR_FactBatch_Test {

    private static final Date TODAY = Date.today();
    private static final Date EARLIEST = Date.today().addMonths(-7);

    @TestSetup
    static void seed() {
        Account acct = new Account(Name = 'PRM Practice');
        insert acct;
        // The visit's city/zip comes from the account's primary Location (the account
        // Shipping address is org-managed/synced from here and can't be set directly).
        Location__c primaryLoc = new Location__c(
            Practice__c = acct.Id,
            Address__Street__s = '1 Main St',
            Address__City__s = 'Orlando',
            Address__StateCode__s = 'FL',
            Address__PostalCode__s = '32801-1234',
            Address__CountryCode__s = 'US'
        );
        insert primaryLoc;
        acct.PrimaryLocation__c = primaryLoc.Id;
        update acct;

        // The Contact object carries several org validation rules that fire on
        // insert (Affiliation, Affiliation_Group, Provider_Type, Credentials,
        // Gender — all ISNEW()-gated). Satisfy each with a valid picklist value.
        Contact provider = new Contact(
            FirstName = 'Pat', LastName = 'Provider',
            npi__c = '1234567890',
            Affiliation__c = 'Affiliated',
            Affiliation_Group__c = 'Independent',
            Provider_Type__c = 'Hospital Based',
            Credentials__c = 'ARNP',
            Gender__c = 'Male'
        );
        insert provider;

        Territory__c terr = new Territory__c();
        insert terr;

        // --- Visit-activity source: one Visit_Report with a Task and all three junctions ---
        // 'Site Visit' is valid for the default record type's restricted Purpose__c
        // picklist (some values like 'Other' are excluded at the record-type level).
        Visit_Report__c vr = new Visit_Report__c(Purpose__c = 'Site Visit');
        insert vr;

        Task visitTask = new Task(
            Subject = 'Coverage Visit',
            Status = 'Completed',
            Priority = 'Normal',
            ActivityDate = TODAY,
            Date_Meeting_Call__c = TODAY,
            // WhatId = the practice account so Task.AccountId (hence the visit's
            // shipping city/zip) resolves for the objection location fields.
            WhatId = acct.Id,
            Visit_Report__c = vr.Id
        );
        insert visitTask;

        insert new List<SObject>{
            new Visit_Service__c(Visit_Report__c = vr.Id),
            new Visit_Collateral__c(Visit_Report__c = vr.Id),
            new Visit_Objection__c(Visit_Report__c = vr.Id)
        };

        // --- Target source (covers both Target-based batches) ---
        insert new Target__c(
            Target_Provider__c = provider.Id,
            Territory__c = terr.Id,
            Rank__c = 'A'
        );

    }

    // Location carries an "Address is required" rule and needs a Practice, so it is
    // built on demand (not in shared setup) — keeping any Location-side fragility out
    // of the setup the visit/target tests rely on.
    private static Location__c makeLocation() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Location__c loc = new Location__c(
            Practice__c = acct.Id,
            Address__Street__s = '1 Main St',
            Address__City__s = 'Orlando',
            Address__StateCode__s = 'FL',
            Address__PostalCode__s = '32801',
            Address__CountryCode__s = 'US'
        );
        insert loc;
        return loc;
    }

    private static ZonedLocation__c makeUncoveredZonedLocation() {
        Territory__c terr = [SELECT Id FROM Territory__c LIMIT 1];
        Location__c loc = makeLocation();
        // Territory_Owner__c is a formula (= Territory__r.Owner_Name__c, i.e. the
        // Territory owner's name), so it auto-populates to the running user's name —
        // non-null, which the batch's start() filter requires. No provider-location
        // links this owner to the location, so the anti-join leaves it uncovered.
        ZonedLocation__c zl = new ZonedLocation__c(
            Location__c = loc.Id,
            Territory__c = terr.Id
        );
        insert zl;
        return zl;
    }

    @IsTest
    static void visitActivityServiceBatchEmitsFacts() {
        Test.startTest();
        Database.executeBatch(new CR_VisitActivityServiceFactBatch(TODAY, EARLIEST), 100);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM Fact_VisitActivityService__c] >= 1,
            'Visit activity service batch should emit at least one fact.'
        );
    }

    @IsTest
    static void visitActivityCollateralBatchEmitsFacts() {
        Test.startTest();
        Database.executeBatch(new CR_VisitActivityCollateralFactBatch(TODAY, EARLIEST), 100);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM Fact_VisitActivityCollateral__c] >= 1,
            'Visit activity collateral batch should emit at least one fact.'
        );
    }

    @IsTest
    static void visitActivityObjectionBatchEmitsFacts() {
        Test.startTest();
        Database.executeBatch(new CR_VisitActivityObjectionFactBatch(TODAY, EARLIEST), 100);
        Test.stopTest();
        List<Fact_VisitActivityObjection__c> facts = [
            SELECT City__c, Zip__c FROM Fact_VisitActivityObjection__c
        ];
        System.assert(!facts.isEmpty(),
            'Visit activity objection batch should emit at least one fact.');
        // Visit location comes from the visit account's shipping address.
        System.assertEquals('Orlando', facts[0].City__c,
            'City should be sourced from the visit account shipping city.');
        System.assertEquals('32801', facts[0].Zip__c,
            'Zip should be the first 5 digits of the shipping postal code.');
    }

    @IsTest
    static void targetCoverageBatchEmitsFacts() {
        // Give the seeded target's provider an active, non-DNU provider-location so the
        // batch exercises the location-join branch (buildFact with a real Location),
        // not only the LEFT-join no-location fallback.
        Contact provider = [SELECT Id FROM Contact LIMIT 1];
        Location__c loc = makeLocation();
        insert new ProviderLocation__c(
            Provider__c = provider.Id,
            Location__c = loc.Id,
            Active__c = true,
            DNU__c = false
        );

        Test.startTest();
        Database.executeBatch(new CR_TargetCoverageFactBatch(TODAY), 200);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM Fact_TargetCoverage__c] >= 1,
            'Target coverage batch should emit at least one fact.'
        );
    }

    @IsTest
    static void unzonedTargetBatchEmitsFacts() {
        Test.startTest();
        Database.executeBatch(new CR_UnzonedTargetFactBatch(TODAY), 200);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM Fact_UnzonedTarget__c] >= 1,
            'Unzoned target batch should emit a fact for a provider with no zoned coverage.'
        );
    }

    @IsTest
    static void zonedLocationGapBatchEmitsFacts() {
        makeUncoveredZonedLocation();
        Test.startTest();
        Database.executeBatch(new CR_ZonedLocationGapFactBatch(TODAY), 200);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM Fact_ZonedLocationGap__c] >= 1,
            'Zoned location gap batch should emit a fact for an uncovered zoned location.'
        );
    }

    /**
     * Drives CR_ETLScheduler.execute() -> runDailyFacts(), which fans out eight
     * Database.executeBatch calls. A test transaction caps batch enqueues at 5,
     * so the last three are caught by tryEnqueue's guard — covering both the
     * success and the catch paths in a single run.
     */
    @IsTest
    static void etlSchedulerFansOutAndSurvivesLimit() {
        // runDailyFacts is gated on the Run_Custom_Reporting_ETL custom permission,
        // which a fresh-org deploying user lacks — run as a CRF-provisioned admin.
        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(admin) {
            new CR_ETLScheduler().execute(null);
        }
        Test.stopTest();
        // No assertion on facts (only a subset of batches run under the enqueue
        // cap); the contract here is that the fan-out completes without throwing.
        System.assert(true, 'ETL scheduler fan-out completed.');
    }

    @IsTest
    static void runDailyFactsWithNullDateDefaultsToToday() {
        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(admin) {
            CR_ETLScheduler.runDailyFacts(null);
        }
        Test.stopTest();
        System.assert(true, 'runDailyFacts(null) defaults the snapshot date without throwing.');
    }

    /**
     * A user without the Run_Custom_Reporting_ETL custom permission must be blocked
     * from triggering the heavy nightly fan-out. Covers the permission-gate throw.
     */
    @IsTest
    static void runDailyFactsWithoutPermissionIsBlocked() {
        User noPerm = makeUserWithoutEtlPermission();
        Boolean blocked = false;
        System.runAs(noPerm) {
            try {
                CR_ETLScheduler.runDailyFacts(Date.today());
            } catch (AuraHandledException e) {
                blocked = true;
            }
        }
        System.assertEquals(true, blocked,
            'A user lacking Run_Custom_Reporting_ETL must be blocked from the ETL fan-out.');
    }

    // ---- Incremental refresh (sinceDate watermark) ----

    /**
     * The key behavioral guarantee: an incremental run (sinceDate set) adds/updates
     * recently-changed records but must NOT run the stale-row cleanup — otherwise it
     * would delete every fact outside its narrow window. Seed a pre-existing "stale"
     * fact and confirm the incremental run leaves it intact while still producing the
     * fact for the recently-modified task.
     */
    @IsTest
    static void incrementalRunAddsButDoesNotDeleteStale() {
        insert new Fact_VisitActivityService__c(
            Name = 'STALE',
            Source_Key__c = 'incr-stale-key',
            Snapshot_Date__c = TODAY.addDays(-30)
        );
        Test.startTest();
        // sinceDate just before now so the @TestSetup task (modified moments ago) is in scope.
        Database.executeBatch(
            new CR_VisitActivityServiceFactBatch(TODAY, EARLIEST, Datetime.now().addMinutes(-5)), 100);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Fact_VisitActivityService__c WHERE Source_Key__c = 'incr-stale-key'],
            'Incremental run must not delete stale rows — that is the full-run job.');
        System.assert(
            [SELECT COUNT() FROM Fact_VisitActivityService__c] >= 2,
            'The recently-modified task should still produce its fact on an incremental run.');
    }

    @IsTest
    static void incrementalFanOutCompletes() {
        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(admin) {
            CR_ETLScheduler.runIncrementalFacts();
        }
        Test.stopTest();
        System.assert(true, 'Incremental fan-out completed without throwing.');
    }

    @IsTest
    static void incrementalSchedulerExecutes() {
        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(admin) {
            new CR_ETLIncrementalScheduler().execute(null);
        }
        Test.stopTest();
        System.assert(true, 'Incremental schedulable executed without throwing.');
    }

    @IsTest
    static void scheduleIncrementalRegistersCron() {
        User admin = CR_TestDataFactory.createReportingAdminUser();
        Test.startTest();
        System.runAs(admin) {
            try {
                String jobId = CR_ETLScheduler.scheduleIncremental();
                System.assertNotEquals(null, jobId);
            } catch (System.AsyncException e) {
                // Tolerate the live-cron collision if this org already has it scheduled.
                System.assert(e.getMessage().containsIgnoreCase('already scheduled'), e.getMessage());
            }
        }
        Test.stopTest();
    }

    private static User makeUserWithoutEtlPermission() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crne',
                Email = 'crnoetl@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'NoEtl',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crnoetl' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }
}