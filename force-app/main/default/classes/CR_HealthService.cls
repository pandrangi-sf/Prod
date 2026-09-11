// Read-only health monitor service for the framework's admin Health Monitor
// tab. All getters are @AuraEnabled(cacheable=true) so the LWC can use @wire.
// The one imperative method (scheduleNightlyETLIfMissing) is intentionally
// scoped to the single safe action discussed during Phase H scoping: it can
// only ADD the nightly cron if it's not already present. It can never modify
// an existing cron or run a batch immediately.
public with sharing class CR_HealthService {

    private static final String NIGHTLY_CRON_NAME = 'Vital Reports Nightly ETL';
    private static final String FRAMEWORK_CLASS_PREFIX = 'CR_';

    // ---- DTOs ----

    public class JobView {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String className { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer jobItemsProcessed { get; set; }
        @AuraEnabled public Integer totalJobItems { get; set; }
        @AuraEnabled public Integer numberOfErrors { get; set; }
        @AuraEnabled public String extendedStatus { get; set; }
        @AuraEnabled public Datetime completedDate { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
        @AuraEnabled public Boolean isFailed { get; set; }
    }

    public class CronView {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public String cronExpression { get; set; }
        @AuraEnabled public Datetime nextFireTime { get; set; }
        @AuraEnabled public Datetime previousFireTime { get; set; }
        @AuraEnabled public Boolean isFrameworkNightly { get; set; }
    }

    public class ErrorView {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String source { get; set; }  // 'Dashboard_Run__c' or 'Dashboard_Component_Run__c'
        @AuraEnabled public String dashboardName { get; set; }
        @AuraEnabled public String componentName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public Datetime occurredAt { get; set; }
    }

    public class HealthKpis {
        @AuraEnabled public Integer jobsFailedToday { get; set; }
        @AuraEnabled public Integer missingFrameworkCrons { get; set; }
        @AuraEnabled public Integer errorsLast24h { get; set; }
        @AuraEnabled public Boolean nightlyCronScheduled { get; set; }
    }

    public class FactCount {
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer todayCount { get; set; }
    }

    public class EtlSnapshot {
        @AuraEnabled public List<FactCount> factCounts { get; set; }
        @AuraEnabled public Integer totalToday { get; set; }
        @AuraEnabled public Integer storageUsedMB { get; set; }
        @AuraEnabled public Integer storageMaxMB { get; set; }
        @AuraEnabled public Decimal storagePercent { get; set; }
    }

    // Friendly labels for the 8 fact tables the nightly ETL writes to.
    private static final Map<String, String> FACT_TABLE_LABELS = new Map<String, String>{
        'Fact_Opportunity__c'              => 'Opportunities',
        'Fact_Case__c'                     => 'Cases',
        'Fact_VisitActivityService__c'     => 'Visit Services',
        'Fact_VisitActivityCollateral__c'  => 'Visit Collateral',
        'Fact_VisitActivityObjection__c'   => 'Visit Objections',
        'Fact_TargetCoverage__c'           => 'Target Coverage',
        'Fact_UnzonedTarget__c'            => 'Unzoned Targets',
        'Fact_ZonedLocationGap__c'         => 'Zoned Location Gaps'
    };

    // ---- Cacheable getters ----

    @AuraEnabled(cacheable=true)
    public static List<JobView> getFrameworkApexJobs(Integer hoursBack) {
        Integer h = hoursBack == null || hoursBack <= 0 ? 24 : hoursBack;
        Datetime since = Datetime.now().addHours(-h);
        // ApexClass.Name LIKE 'CR\\_%' would be ideal but SOQL doesn't escape
        // underscores; we filter post-query to keep things simple. Limit at
        // SOQL ensures we never read more than 200 rows.
        List<AsyncApexJob> rows = [
            SELECT Id, ApexClass.Name, Status, JobItemsProcessed, TotalJobItems,
                   NumberOfErrors, ExtendedStatus, CompletedDate, CreatedDate, JobType
            FROM AsyncApexJob
            WHERE CreatedDate >= :since
              AND JobType IN ('BatchApex', 'ScheduledApex', 'Queueable')
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        List<JobView> views = new List<JobView>();
        for (AsyncApexJob j : rows) {
            JobView v = toJobView(j);
            if (v != null) views.add(v);
        }
        return views;
    }

    // Extracted so tests can synthesize an AsyncApexJob via JSON.deserialize
    // and verify the mapping/filter logic without needing real async jobs.
    @TestVisible
    private static JobView toJobView(AsyncApexJob j) {
        String className = j.ApexClass == null ? '' : j.ApexClass.Name;
        if (String.isBlank(className) || !className.startsWith(FRAMEWORK_CLASS_PREFIX)) {
            return null;
        }
        JobView v = new JobView();
        v.id = j.Id;
        v.className = className;
        v.status = j.Status;
        v.jobItemsProcessed = j.JobItemsProcessed;
        v.totalJobItems = j.TotalJobItems;
        v.numberOfErrors = j.NumberOfErrors;
        v.extendedStatus = j.ExtendedStatus;
        v.completedDate = j.CompletedDate;
        v.createdDate = j.CreatedDate;
        v.isFailed = j.Status == 'Failed' || (j.NumberOfErrors != null && j.NumberOfErrors > 0);
        return v;
    }

    @AuraEnabled(cacheable=true)
    public static List<CronView> getScheduledCrons() {
        List<CronView> views = new List<CronView>();
        for (CronTrigger ct : [
            SELECT Id, CronJobDetail.Name, State, CronExpression, NextFireTime, PreviousFireTime
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'Vital Reports%'
               OR CronJobDetail.Name LIKE 'CR_%'
            ORDER BY NextFireTime ASC
            LIMIT 50
        ]) {
            views.add(toCronView(ct));
        }
        return views;
    }

    @TestVisible
    private static CronView toCronView(CronTrigger ct) {
        CronView v = new CronView();
        v.id = ct.Id;
        v.name = ct.CronJobDetail == null ? '(unnamed)' : ct.CronJobDetail.Name;
        v.state = ct.State;
        v.cronExpression = ct.CronExpression;
        v.nextFireTime = ct.NextFireTime;
        v.previousFireTime = ct.PreviousFireTime;
        v.isFrameworkNightly = v.name == NIGHTLY_CRON_NAME;
        return v;
    }

    @TestVisible
    private static Boolean isJobFailed(AsyncApexJob j) {
        return j != null
            && (j.Status == 'Failed'
                || (j.NumberOfErrors != null && j.NumberOfErrors > 0));
    }

    @AuraEnabled(cacheable=true)
    public static List<ErrorView> getRecentErrors(Integer daysBack) {
        Integer d = daysBack == null || daysBack <= 0 ? 7 : daysBack;
        Datetime since = Datetime.now().addDays(-d);
        List<ErrorView> views = new List<ErrorView>();

        // Source 1: Dashboard_Run__c with Status = Failed
        for (Dashboard_Run__c run : [
            SELECT Id, Status__c, Message__c, Completed_At__c, Dashboard__r.Name
            FROM Dashboard_Run__c
            WHERE Status__c = 'Failed' AND CreatedDate >= :since
            ORDER BY CreatedDate DESC
            LIMIT 50
        ]) {
            ErrorView v = new ErrorView();
            v.id = run.Id;
            v.source = 'Dashboard_Run__c';
            v.dashboardName = run.Dashboard__r == null ? '(no dashboard)' : run.Dashboard__r.Name;
            v.componentName = null;
            v.status = run.Status__c;
            v.message = run.Message__c;
            v.occurredAt = run.Completed_At__c;
            views.add(v);
        }

        // Source 2: Dashboard_Component_Run__c with Status = Failed or Message present
        for (Dashboard_Component_Run__c crun : [
            SELECT Id, Status__c, Message__c, Completed_At__c,
                   Dashboard_Component__r.Name,
                   Dashboard_Component__r.Dashboard__r.Name
            FROM Dashboard_Component_Run__c
            WHERE Status__c = 'Failed' AND CreatedDate >= :since
            ORDER BY CreatedDate DESC
            LIMIT 50
        ]) {
            ErrorView v = new ErrorView();
            v.id = crun.Id;
            v.source = 'Dashboard_Component_Run__c';
            v.dashboardName = (crun.Dashboard_Component__r == null
                || crun.Dashboard_Component__r.Dashboard__r == null)
                ? '(no dashboard)' : crun.Dashboard_Component__r.Dashboard__r.Name;
            v.componentName = crun.Dashboard_Component__r == null
                ? '(no component)' : crun.Dashboard_Component__r.Name;
            v.status = crun.Status__c;
            v.message = crun.Message__c;
            v.occurredAt = crun.Completed_At__c;
            views.add(v);
        }
        return views;
    }

    @AuraEnabled(cacheable=true)
    public static HealthKpis getHealthKpis() {
        HealthKpis kpis = new HealthKpis();
        Datetime startOfToday = Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));

        // Jobs failed today: count async Apex jobs created today, framework-prefixed,
        // with Status = Failed or NumberOfErrors > 0.
        Integer failed = 0;
        for (AsyncApexJob j : [
            SELECT Id, ApexClass.Name, Status, NumberOfErrors
            FROM AsyncApexJob
            WHERE CreatedDate >= :startOfToday
              AND JobType IN ('BatchApex', 'ScheduledApex', 'Queueable')
            LIMIT 500
        ]) {
            String n = j.ApexClass == null ? '' : j.ApexClass.Name;
            if (!n.startsWith(FRAMEWORK_CLASS_PREFIX)) continue;
            Boolean isFailed = j.Status == 'Failed' || (j.NumberOfErrors != null && j.NumberOfErrors > 0);
            if (isFailed) failed++;
        }
        kpis.jobsFailedToday = failed;

        // Is the nightly ETL cron registered?
        Integer cronCount = [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name = :NIGHTLY_CRON_NAME
        ];
        kpis.nightlyCronScheduled = cronCount > 0;
        kpis.missingFrameworkCrons = cronCount > 0 ? 0 : 1;

        // Errors in the last 24 hours (Dashboard_Run + Dashboard_Component_Run, Failed status)
        Datetime since = Datetime.now().addHours(-24);
        Integer drFailed = [
            SELECT COUNT() FROM Dashboard_Run__c
            WHERE Status__c = 'Failed' AND CreatedDate >= :since
        ];
        Integer dcrFailed = [
            SELECT COUNT() FROM Dashboard_Component_Run__c
            WHERE Status__c = 'Failed' AND CreatedDate >= :since
        ];
        kpis.errorsLast24h = drFailed + dcrFailed;

        return kpis;
    }

    // Per-fact row counts for TODAY's Snapshot_Date__c plus the org's
    // data-storage usage. The nightly ETL stamps every fact row with
    // Snapshot_Date__c = the run date, so this gives admins a quick "did
    // tonight's run produce data?" plus headroom against the org's storage cap.
    @AuraEnabled(cacheable=true)
    public static EtlSnapshot getEtlSnapshot() {
        EtlSnapshot snap = new EtlSnapshot();
        snap.factCounts = new List<FactCount>();
        snap.totalToday = 0;

        for (String apiName : FACT_TABLE_LABELS.keySet()) {
            FactCount fc = new FactCount();
            fc.objectApiName = apiName;
            fc.label = FACT_TABLE_LABELS.get(apiName);
            fc.todayCount = 0;
            // Dynamic COUNT() per fact table. Wrapped because a missing object
            // or FLS denial on Snapshot_Date__c should degrade to zero rather
            // than fail the whole snapshot view.
            try {
                String q = 'SELECT COUNT() FROM ' + apiName + ' WHERE Snapshot_Date__c = TODAY';
                fc.todayCount = Database.countQuery(q);
            } catch (Exception ex) {
                fc.todayCount = 0;
            }
            snap.factCounts.add(fc);
            snap.totalToday += fc.todayCount;
        }

        // Data storage from OrgLimits — no SOQL cost, returns the same numbers
        // surfaced in Setup → Company Information → Used Data Space.
        Map<String, System.OrgLimit> limits = OrgLimits.getMap();
        System.OrgLimit dsl = limits.get('DataStorageMB');
        if (dsl != null) {
            snap.storageUsedMB = dsl.getValue();
            snap.storageMaxMB = dsl.getLimit();
            if (snap.storageMaxMB != null && snap.storageMaxMB > 0) {
                Decimal pct = (Decimal.valueOf(snap.storageUsedMB) / Decimal.valueOf(snap.storageMaxMB)) * 100;
                snap.storagePercent = pct.setScale(1);
            }
        }
        return snap;
    }

    // ---- The single imperative action ----

    // Adds the nightly ETL cron IFF it's not already registered. Idempotent —
    // double-clicks throw at the System.schedule call (which we catch silently)
    // because the framework reserves the canonical name. Cannot modify an
    // existing cron and cannot run any batch immediately; the actual run only
    // happens when the cron fires at 2 AM.
    @AuraEnabled
    public static String scheduleNightlyETLIfMissing() {
        if (!FeatureManagement.checkPermission('Run_Custom_Reporting_ETL')) {
            throw new AuraHandledException(
                'You do not have permission to schedule the Vital Reports ETL.'
            );
        }
        Integer existing = [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name = :NIGHTLY_CRON_NAME
        ];
        if (existing > 0) {
            // Idempotent no-op. Returning null tells the LWC "already scheduled".
            return null;
        }
        try {
            return CR_ETLScheduler.scheduleNightly();
        } catch (Exception ex) {
            // Defensive: if System.schedule raced and threw because someone else
            // just scheduled it, treat as already-done rather than surfacing
            // a scary error to the admin.
            String msg = ex.getMessage() == null ? '' : ex.getMessage();
            if (msg.contains('already scheduled')
                || msg.contains('AsyncException')
                || msg.contains('duplicate value')) {
                return null;
            }
            throw new AuraHandledException(
                'Could not schedule the nightly ETL: ' + msg
            );
        }
    }
}