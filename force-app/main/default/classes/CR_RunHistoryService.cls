// Per-execution audit log for saved-report runs. CR_QueryEngine.runReportById
// calls logRun() at the tail of every execution (success or failure). Read APIs
// are surfaced through CR_HealthService for the Health Monitor tab.
//
// Why a separate service class:
//   - Keeps CR_QueryEngine focused on query construction and execution.
//   - Lets CR_QueryEngine_Test stay green without forcing every existing test
//     to assert on Report_Run__c rows.
//   - Makes the "fail-soft" contract explicit: a logging failure must never
//     break the underlying report — see the catch in logRun.
public with sharing class CR_RunHistoryService {

    // Truncate exception messages to fit the LongTextArea field. The number is
    // the field-level max minus a safety margin for the ellipsis.
    @TestVisible
    private static final Integer ERROR_MESSAGE_MAX_LEN = 995;

    public static void logRun(
        Id reportDefinitionId,
        Datetime runAt,
        Integer durationMs,
        Integer rowCount,
        Boolean aggregateResult,
        String errorMessage
    ) {
        try {
            Report_Run__c row = new Report_Run__c();
            row.Report_Definition__c = reportDefinitionId;
            row.Run_At__c = runAt == null ? System.now() : runAt;
            row.Duration_Ms__c = durationMs == null ? 0 : durationMs;
            row.Row_Count__c = rowCount == null ? 0 : rowCount;
            row.Aggregate_Result__c = aggregateResult == true;
            row.Status__c = String.isBlank(errorMessage) ? 'Success' : 'Failed';
            if (!String.isBlank(errorMessage)) {
                row.Error_Message__c = errorMessage.length() > ERROR_MESSAGE_MAX_LEN
                    ? errorMessage.substring(0, ERROR_MESSAGE_MAX_LEN) + '…'
                    : errorMessage;
            }
            if (Schema.SObjectType.Report_Run__c.isCreateable()) {
                insert row;
            }
        } catch (Exception ex) {
            // Fail-soft: logging is observability, not correctness. The caller's
            // result is what users see — don't let an audit-trail problem
            // surface as a "report failed" error.
            System.debug(LoggingLevel.WARN, 'CR_RunHistoryService.logRun suppressed: ' + ex.getMessage());
        }
    }

    public class SlowReport {
        @AuraEnabled public Id reportDefinitionId { get; set; }
        @AuraEnabled public String reportName { get; set; }
        @AuraEnabled public Decimal avgDurationMs { get; set; }
        @AuraEnabled public Decimal maxDurationMs { get; set; }
        @AuraEnabled public Integer runCount { get; set; }
        @AuraEnabled public Datetime lastRunAt { get; set; }
    }

    // Top-N reports by average duration over the last lookbackDays days.
    // Used by the Health Monitor tile; surfaces capacity-planning signal.
    @AuraEnabled(cacheable=true)
    public static List<SlowReport> getSlowReports(Integer lookbackDays, Integer maxResults) {
        Integer days = lookbackDays == null || lookbackDays <= 0 ? 7 : lookbackDays;
        Integer limitSize = maxResults == null || maxResults <= 0 ? 10 : Math.min(maxResults, 50);
        Datetime cutoff = System.now().addDays(-days);

        List<AggregateResult> rows = [
            SELECT Report_Definition__c rd,
                   AVG(Duration_Ms__c) avgMs,
                   MAX(Duration_Ms__c) maxMs,
                   COUNT(Id) runs,
                   MAX(Run_At__c) lastRun
            FROM Report_Run__c
            WHERE Run_At__c >= :cutoff
              AND Report_Definition__c != null
            GROUP BY Report_Definition__c
            ORDER BY AVG(Duration_Ms__c) DESC NULLS LAST
            LIMIT :limitSize
        ];

        if (rows.isEmpty()) return new List<SlowReport>();

        Set<Id> ids = new Set<Id>();
        for (AggregateResult r : rows) ids.add((Id) r.get('rd'));
        Map<Id, Report_Definition__c> nameById = new Map<Id, Report_Definition__c>(
            [SELECT Id, Name FROM Report_Definition__c WHERE Id IN :ids]
        );

        List<SlowReport> out = new List<SlowReport>();
        for (AggregateResult r : rows) {
            SlowReport s = new SlowReport();
            s.reportDefinitionId = (Id) r.get('rd');
            s.reportName = nameById.containsKey(s.reportDefinitionId)
                ? nameById.get(s.reportDefinitionId).Name : null;
            s.avgDurationMs = (Decimal) r.get('avgMs');
            s.maxDurationMs = (Decimal) r.get('maxMs');
            s.runCount = (Integer) r.get('runs');
            s.lastRunAt = (Datetime) r.get('lastRun');
            out.add(s);
        }
        return out;
    }
}