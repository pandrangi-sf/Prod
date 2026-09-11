public with sharing class CR_ETLScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        runDailyFacts(Date.today());
    }

    @AuraEnabled
    public static void runDailyFacts(Date snapshotDate) {
        // Heavy operation: only users with the Run_Custom_Reporting_ETL custom permission
        // can trigger the nightly batch fan-out. Schedulable.execute() (the cron path)
        // bypasses this since it runs as the user who scheduled it (typically an admin).
        if (!FeatureManagement.checkPermission('Run_Custom_Reporting_ETL')) {
            throw new AuraHandledException('You do not have permission to run the Vital Reports ETL.');
        }
        Date effectiveDate = snapshotDate == null ? Date.today() : snapshotDate;
        Date earliest = effectiveDate.addMonths(-CR_VisitActivityServiceFactBatch.DEFAULT_LOOKBACK_MONTHS);
        // Each batch enqueue is wrapped so a single flex-queue limit failure
        // doesn't block the rest of the nightly run.
        tryEnqueue('CR_OpportunityFactBatch', new CR_OpportunityFactBatch(effectiveDate), 200);
        tryEnqueue('CR_CaseFactBatch', new CR_CaseFactBatch(effectiveDate), 200);
        // PRM-style fan-out facts. Smaller batch size because each Task can fan out to N children x M contacts.
        tryEnqueue('CR_VisitActivityServiceFactBatch', new CR_VisitActivityServiceFactBatch(effectiveDate, earliest), 100);
        tryEnqueue('CR_VisitActivityCollateralFactBatch', new CR_VisitActivityCollateralFactBatch(effectiveDate, earliest), 100);
        tryEnqueue('CR_VisitActivityObjectionFactBatch', new CR_VisitActivityObjectionFactBatch(effectiveDate, earliest), 100);
        tryEnqueue('CR_TargetCoverageFactBatch', new CR_TargetCoverageFactBatch(effectiveDate), 200);
        tryEnqueue('CR_UnzonedTargetFactBatch', new CR_UnzonedTargetFactBatch(effectiveDate), 200);
        tryEnqueue('CR_ZonedLocationGapFactBatch', new CR_ZonedLocationGapFactBatch(effectiveDate), 200);
    }

    private static void tryEnqueue(String name, Database.Batchable<SObject> job, Integer scope) {
        try {
            Database.executeBatch(job, scope);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'CR_ETLScheduler: failed to enqueue ' + name + ': ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static String scheduleNightly() {
        if (!FeatureManagement.checkPermission('Run_Custom_Reporting_ETL')) {
            throw new AuraHandledException('You do not have permission to schedule the Vital Reports ETL.');
        }
        return System.schedule('Vital Reports Nightly ETL', '0 0 2 * * ?', new CR_ETLScheduler());
    }

    // Incremental refresh: reprocess only source records modified in the recent
    // window (via each batch's sinceDate watermark), so newly created/edited
    // records surface in Fact-based reports within minutes instead of next nightly.
    // Batch finish() skips stale-row cleanup when sinceDate is set, so this only
    // adds/updates — deletions stay a full-nightly responsibility.
    @AuraEnabled
    public static void runIncrementalFacts() {
        if (!FeatureManagement.checkPermission('Run_Custom_Reporting_ETL')) {
            throw new AuraHandledException('You do not have permission to run the Vital Reports ETL.');
        }
        Date snap = Date.today();
        Date earliest = snap.addMonths(-CR_VisitActivityServiceFactBatch.DEFAULT_LOOKBACK_MONTHS);
        // Lookback wider than the ~30-min cadence tolerates a missed/slow cycle;
        // Source_Key upserts make the overlap idempotent.
        Datetime since = Datetime.now().addMinutes(-90);
        tryEnqueue('CR_OpportunityFactBatch', new CR_OpportunityFactBatch(snap, since), 200);
        tryEnqueue('CR_CaseFactBatch', new CR_CaseFactBatch(snap, since), 200);
        tryEnqueue('CR_VisitActivityServiceFactBatch', new CR_VisitActivityServiceFactBatch(snap, earliest, since), 100);
        tryEnqueue('CR_VisitActivityCollateralFactBatch', new CR_VisitActivityCollateralFactBatch(snap, earliest, since), 100);
        tryEnqueue('CR_VisitActivityObjectionFactBatch', new CR_VisitActivityObjectionFactBatch(snap, earliest, since), 100);
        tryEnqueue('CR_TargetCoverageFactBatch', new CR_TargetCoverageFactBatch(snap, since), 200);
        tryEnqueue('CR_UnzonedTargetFactBatch', new CR_UnzonedTargetFactBatch(snap, since), 200);
        tryEnqueue('CR_ZonedLocationGapFactBatch', new CR_ZonedLocationGapFactBatch(snap, since), 200);
    }

    @AuraEnabled
    public static String scheduleIncremental() {
        if (!FeatureManagement.checkPermission('Run_Custom_Reporting_ETL')) {
            throw new AuraHandledException('You do not have permission to schedule the Vital Reports ETL.');
        }
        // Salesforce scheduled-Apex cron requires integer minutes (no lists/steps),
        // so a 30-minute cadence needs two jobs — one firing at :00, one at :30.
        String jobId = System.schedule('Vital Reports Incremental ETL (top of hour)', '0 0 * * * ?', new CR_ETLIncrementalScheduler());
        System.schedule('Vital Reports Incremental ETL (half past)', '0 30 * * * ?', new CR_ETLIncrementalScheduler());
        return jobId;
    }
}