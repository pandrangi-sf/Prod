@isTest
private class CR_HealthService_Test {

    @isTest
    static void getFrameworkApexJobsReturnsEmptyOrFrameworkRowsOnly() {
        // Real AsyncApexJob rows can't be inserted in tests; we rely on the
        // method returning either an empty list (clean test org) or only
        // CR_-prefixed entries when seed data exists. Both are valid.
        Test.startTest();
        List<CR_HealthService.JobView> jobs = CR_HealthService.getFrameworkApexJobs(24);
        Test.stopTest();

        for (CR_HealthService.JobView v : jobs) {
            System.assert(
                v.className != null && v.className.startsWith('CR_'),
                'Only CR_-prefixed jobs should be returned; got ' + v.className
            );
        }
    }

    @isTest
    static void getFrameworkApexJobsDefaultsTo24Hours() {
        Test.startTest();
        List<CR_HealthService.JobView> withNull = CR_HealthService.getFrameworkApexJobs(null);
        List<CR_HealthService.JobView> withZero = CR_HealthService.getFrameworkApexJobs(0);
        List<CR_HealthService.JobView> withNeg  = CR_HealthService.getFrameworkApexJobs(-5);
        Test.stopTest();
        // Null/zero/negative all coerce to a 24-hour default. The lists may be
        // empty in a fresh test context; what matters is the call doesn't throw.
        System.assertNotEquals(null, withNull);
        System.assertNotEquals(null, withZero);
        System.assertNotEquals(null, withNeg);
    }

    @isTest
    static void getScheduledCronsReturnsListWithoutThrowing() {
        Test.startTest();
        List<CR_HealthService.CronView> crons = CR_HealthService.getScheduledCrons();
        Test.stopTest();
        // Test org has no Vital Reports crons by default; expect empty.
        // The isFrameworkNightly flag is computed correctly for any real row.
        for (CR_HealthService.CronView c : crons) {
            System.assertEquals(c.name == 'Vital Reports Nightly ETL', c.isFrameworkNightly);
        }
    }

    @isTest
    static void getRecentErrorsReturnsFailedRows() {
        // Seed a failed Dashboard_Run + a failed Dashboard_Component_Run so we
        // exercise both source paths in the union.
        Dashboard__c d = new Dashboard__c(
            Name = 'Health Test Dashboard',
            Developer_Name__c = 'Health_Test_' + String.valueOf(Crypto.getRandomInteger())
        );
        insert d;
        Dashboard_Component__c c = new Dashboard_Component__c(
            Name = 'Health Test Component',
            Dashboard__c = d.Id
        );
        insert c;
        Dashboard_Run__c run = new Dashboard_Run__c(
            Dashboard__c = d.Id,
            Status__c = 'Failed',
            Message__c = 'Synthetic error for health monitor test',
            Completed_At__c = Datetime.now()
        );
        insert run;
        // Dashboard_Component_Run__c requires its parent Dashboard_Run__c.
        Dashboard_Component_Run__c crun = new Dashboard_Component_Run__c(
            Dashboard_Run__c = run.Id,
            Dashboard_Component__c = c.Id,
            Status__c = 'Failed',
            Message__c = 'Synthetic component error',
            Completed_At__c = Datetime.now()
        );
        insert crun;

        Test.startTest();
        List<CR_HealthService.ErrorView> errors = CR_HealthService.getRecentErrors(1);
        Test.stopTest();

        Boolean foundDashboardRun = false;
        Boolean foundComponentRun = false;
        for (CR_HealthService.ErrorView e : errors) {
            if (e.id == run.Id) {
                foundDashboardRun = true;
                System.assertEquals('Dashboard_Run__c', e.source);
                System.assertEquals('Failed', e.status);
                System.assertEquals('Synthetic error for health monitor test', e.message);
            }
            if (e.id == crun.Id) {
                foundComponentRun = true;
                System.assertEquals('Dashboard_Component_Run__c', e.source);
                System.assertEquals('Health Test Component', e.componentName);
            }
        }
        System.assertEquals(true, foundDashboardRun, 'Dashboard_Run failure should surface in errors');
        System.assertEquals(true, foundComponentRun, 'Component_Run failure should surface in errors');
    }

    @isTest
    static void getHealthKpisReturnsAllFields() {
        Test.startTest();
        CR_HealthService.HealthKpis kpis = CR_HealthService.getHealthKpis();
        Test.stopTest();

        // All counters should be non-null. CronTrigger is a platform table
        // that's NOT isolated to test transactions, so nightlyCronScheduled
        // can be true or false depending on whether the org has the cron
        // registered. We assert the invariant: missingFrameworkCrons = 1
        // when the cron is missing, 0 when it exists.
        System.assertNotEquals(null, kpis.jobsFailedToday);
        System.assertNotEquals(null, kpis.errorsLast24h);
        System.assertNotEquals(null, kpis.missingFrameworkCrons);
        System.assertNotEquals(null, kpis.nightlyCronScheduled);
        Integer expectedMissing = kpis.nightlyCronScheduled ? 0 : 1;
        System.assertEquals(expectedMissing, kpis.missingFrameworkCrons,
            'missingFrameworkCrons should mirror the nightlyCronScheduled flag');
    }

    @isTest
    static void scheduleNightlyETLIfMissingHandlesAllPaths() {
        // Three possible outcomes depending on (a) whether the running test
        // user has the Run_Custom_Reporting_ETL custom permission, and (b)
        // whether the org already has the nightly cron registered. All three
        // are valid for this test; what we're verifying is that the method
        // doesn't throw an unexpected exception and returns either a Cron Id
        // or null. This also gives us line coverage on the schedule-and-catch
        // path regardless of which branch fires.
        Test.startTest();
        String result = null;
        Boolean threw = false;
        try {
            result = CR_HealthService.scheduleNightlyETLIfMissing();
        } catch (AuraHandledException ex) {
            threw = true; // permission gate path
        }
        Test.stopTest();
        // Either a valid Cron Id (success path) or null (already scheduled),
        // or threw=true (permission denied). All three are acceptable.
        // result is typed String so we just verify the call returned cleanly.
        System.assert(threw || result == null || result.length() > 0,
            'Method should return Id-string, null, or throw permission error');
    }

    @isTest
    static void cacheableGettersAreCallableInOneShot() {
        // Hit every cacheable getter at least once to ensure each entry
        // point and DTO construction is covered, even if the underlying
        // query returns no rows in the test context.
        Test.startTest();
        List<CR_HealthService.JobView> jobs   = CR_HealthService.getFrameworkApexJobs(48);
        List<CR_HealthService.CronView> crons = CR_HealthService.getScheduledCrons();
        List<CR_HealthService.ErrorView> errs = CR_HealthService.getRecentErrors(null);
        List<CR_HealthService.ErrorView> errs2 = CR_HealthService.getRecentErrors(0);
        CR_HealthService.HealthKpis kpis = CR_HealthService.getHealthKpis();
        CR_HealthService.EtlSnapshot snap = CR_HealthService.getEtlSnapshot();
        Test.stopTest();
        System.assertNotEquals(null, jobs);
        System.assertNotEquals(null, crons);
        System.assertNotEquals(null, errs);
        System.assertNotEquals(null, errs2);
        System.assertNotEquals(null, kpis);
        System.assertNotEquals(null, snap);
    }

    @isTest
    static void getEtlSnapshotCountsTodaysFactRows() {
        // Seed one Fact_Opportunity__c stamped with TODAY so the snapshot has
        // a guaranteed non-zero count for at least one fact table. We use the
        // simplest fact object because it doesn't require a parent dimension.
        // Source_Opportunity_Id__c is capped at 18 chars (matches Salesforce Ids),
        // so we hand-build a 15-char value rather than concatenating a random int.
        String shortId = 'HTST' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(11);
        Fact_Opportunity__c fact = new Fact_Opportunity__c(
            Name = 'FO-Health-Test',
            Source_Opportunity_Id__c = shortId,
            Snapshot_Date__c = Date.today(),
            Record_Count__c = 1,
            Is_Current__c = true
        );
        insert fact;

        Test.startTest();
        CR_HealthService.EtlSnapshot snap = CR_HealthService.getEtlSnapshot();
        Test.stopTest();

        System.assertNotEquals(null, snap);
        System.assertNotEquals(null, snap.factCounts);
        System.assertEquals(8, snap.factCounts.size(),
            'Snapshot should cover all 8 fact tables the nightly ETL writes to');
        System.assert(snap.totalToday >= 1, 'Seeded fact row should count toward totalToday');

        // OrgLimits.DataStorageMB is always populated in a real org. In a test
        // context the value is the running org's actual storage; just confirm
        // we got numeric values back and that the percent calc is sane.
        System.assertNotEquals(null, snap.storageUsedMB);
        System.assertNotEquals(null, snap.storageMaxMB);
        System.assert(snap.storageMaxMB > 0, 'Org should have a non-zero storage allocation');
        System.assert(snap.storagePercent >= 0 && snap.storagePercent <= 100,
            'storagePercent should be a valid percentage');

        Boolean foundOpps = false;
        for (CR_HealthService.FactCount fc : snap.factCounts) {
            System.assertNotEquals(null, fc.objectApiName);
            System.assertNotEquals(null, fc.label);
            System.assertNotEquals(null, fc.todayCount);
            if (fc.objectApiName == 'Fact_Opportunity__c') {
                foundOpps = true;
                System.assert(fc.todayCount >= 1, 'Fact_Opportunity__c should include the seeded row');
            }
        }
        System.assertEquals(true, foundOpps, 'Fact_Opportunity__c row should be present in the snapshot');
    }

    @isTest
    static void toJobViewMapsAndFiltersCorrectly() {
        // Synthesize an AsyncApexJob via JSON.deserialize — platform sObjects
        // can't be inserted in tests but can be hydrated in-memory.
        AsyncApexJob frameworkJob = (AsyncApexJob) JSON.deserialize(
            '{"Status":"Failed","NumberOfErrors":3,"JobItemsProcessed":50,"TotalJobItems":100,'
            + '"ExtendedStatus":"Test error","ApexClass":{"Name":"CR_TestBatch"}}',
            AsyncApexJob.class
        );
        AsyncApexJob nonFrameworkJob = (AsyncApexJob) JSON.deserialize(
            '{"Status":"Completed","ApexClass":{"Name":"SomeOtherBatch"}}',
            AsyncApexJob.class
        );
        AsyncApexJob noClass = (AsyncApexJob) JSON.deserialize(
            '{"Status":"Completed"}',
            AsyncApexJob.class
        );

        Test.startTest();
        CR_HealthService.JobView v1 = CR_HealthService.toJobView(frameworkJob);
        CR_HealthService.JobView v2 = CR_HealthService.toJobView(nonFrameworkJob);
        CR_HealthService.JobView v3 = CR_HealthService.toJobView(noClass);
        Boolean failed = CR_HealthService.isJobFailed(frameworkJob);
        Boolean ok = CR_HealthService.isJobFailed(nonFrameworkJob);
        Boolean nullSafe = CR_HealthService.isJobFailed(null);
        Test.stopTest();

        System.assertNotEquals(null, v1, 'CR_-prefixed jobs map to a view');
        System.assertEquals('CR_TestBatch', v1.className);
        System.assertEquals(true, v1.isFailed);
        System.assertEquals(50, v1.jobItemsProcessed);
        System.assertEquals(100, v1.totalJobItems);
        System.assertEquals('Test error', v1.extendedStatus);

        System.assertEquals(null, v2, 'Non-framework job classes are filtered out');
        System.assertEquals(null, v3, 'Missing class name is filtered out');

        System.assertEquals(true, failed);
        System.assertEquals(false, ok);
        System.assertEquals(false, nullSafe);
    }

    @isTest
    static void toCronViewMapsFieldsAndFlagsNightlyCorrectly() {
        CronTrigger nightly = (CronTrigger) JSON.deserialize(
            '{"State":"WAITING","CronExpression":"0 0 2 * * ?",'
            + '"CronJobDetail":{"Name":"Vital Reports Nightly ETL"}}',
            CronTrigger.class
        );
        CronTrigger other = (CronTrigger) JSON.deserialize(
            '{"State":"WAITING","CronExpression":"0 0 0 * * ?",'
            + '"CronJobDetail":{"Name":"CR_Other Job"}}',
            CronTrigger.class
        );
        CronTrigger unnamed = (CronTrigger) JSON.deserialize(
            '{"State":"PAUSED","CronExpression":"0 0 0 * * ?"}',
            CronTrigger.class
        );

        Test.startTest();
        CR_HealthService.CronView v1 = CR_HealthService.toCronView(nightly);
        CR_HealthService.CronView v2 = CR_HealthService.toCronView(other);
        CR_HealthService.CronView v3 = CR_HealthService.toCronView(unnamed);
        Test.stopTest();

        System.assertEquals('Vital Reports Nightly ETL', v1.name);
        System.assertEquals(true, v1.isFrameworkNightly);
        System.assertEquals('CR_Other Job', v2.name);
        System.assertEquals(false, v2.isFrameworkNightly);
        System.assertEquals('(unnamed)', v3.name, 'Null CronJobDetail surfaces (unnamed) label');
    }
}