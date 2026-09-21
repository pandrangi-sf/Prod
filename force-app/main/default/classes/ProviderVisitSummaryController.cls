/**
 * Read-only summary of the Visit Reports logged against a single Provider (Contact).
 *
 *   Contact <- TaskWhoRelation.RelationId -> Task -> Visit_Report__c
 *
 * There is no Contact or Account relationship on Visit_Report__c, so the Activity
 * is the only bridge between a provider and the visits they were part of.
 *
 * TWO capture patterns are unioned, because the org changed how visits are stored
 * partway through its history:
 *
 *   1. "Visit Report record" - Task.Visit_Report__c points at a Visit_Report__c.
 *      Alabama has always worked this way; Florida moved to it during 2025 and was
 *      fully converted by 2026.
 *
 *   2. "Activity only" - the Task IS the visit report. It carries a visit-report
 *      record type and the detail lives on the Activity itself (Subject, Description,
 *      Visit_Category__c, Audience__c, Date_Meeting_Call__c) with the site in WhatId.
 *      This covers Florida's pre-2025 history, which is the larger body of records.
 *
 * Reading only pattern 1 made every pre-cutover Florida provider look like they had
 * never been visited, which is why both are included.
 *
 * Rows are ONE PER VISIT, not per task: a visit report often carries several tasks
 * (one per attendee), and listing those raw would repeat the same visit.
 */
public with sharing class ProviderVisitSummaryController {

    private static final Integer DEFAULT_ROW_LIMIT = 500;
    private static final Integer MAX_ROW_LIMIT = 2000;
    // Defensive ceiling on the task scan before de-duplication.
    private static final Integer TASK_SCAN_LIMIT = 4000;

    private static final String SOURCE_RECORD = 'Visit Report record';
    private static final String SOURCE_ACTIVITY = 'Activity only';

    /**
     * Task record types that represent a visit when no Visit_Report__c exists.
     * Deliberately excludes Phone_Log, Internal_Meeting, Provider_Data_Changes and
     * Participating_Physician_Record_Only: those are not visit reports.
     */
    private static final Set<String> VISIT_RECORD_TYPES = new Set<String>{
        'VisitReportPhysicianSales',
        'Virtual_Visit_Physician_Sales',
        'VisitReportBusinessDevelopment'
    };

    /**
     * @param providerId  Contact id of the provider.
     * @param monthsBack  Rolling window in months. Null or 0 means all time.
     * @param rowLimit    Max visit rows to return. Null defaults to 500, capped at 2000.
     */
    @AuraEnabled(cacheable=true)
    public static VisitSummaryResult getVisitSummary(Id providerId, Integer monthsBack, Integer rowLimit) {
        if (providerId == null || providerId.getSObjectType() != Contact.SObjectType) {
            throw buildException('A valid Provider (Contact) record id is required.');
        }
        try {
            return build(providerId, resolveCutoff(monthsBack), resolveLimit(rowLimit));
        } catch (Exception e) {
            throw buildException('Unable to load the visit summary: ' + e.getMessage());
        }
    }

    private static VisitSummaryResult build(Id providerId, Date cutoff, Integer effectiveLimit) {
        VisitSummaryResult result = new VisitSummaryResult();

        // ---- Step 1: tasks this provider attended. ------------------------------
        Set<Id> taskIds = new Set<Id>();
        for (TaskWhoRelation twr : [
            SELECT TaskId FROM TaskWhoRelation WHERE RelationId = :providerId
        ]) {
            taskIds.add(twr.TaskId);
        }
        for (Task t : [SELECT Id FROM Task WHERE WhoId = :providerId]) {
            taskIds.add(t.Id);
        }
        if (taskIds.isEmpty()) {
            return result;
        }

        // ---- Step 2: the tasks, plus the visit report behind them where one exists.
        // Two static queries rather than one assembled by string concatenation. The
        // date filter spans all three possible date sources because a legacy task has
        // no visit report to take a date from.
        Boolean vrAccessible = Schema.SObjectType.Visit_Report__c.isAccessible();
        Boolean canReadVrNotes = vrAccessible
            && Schema.SObjectType.Visit_Report__c.fields.Notes__c.isAccessible();
        Boolean canReadVrSubject = vrAccessible
            && Schema.SObjectType.Visit_Report__c.fields.Subject__c.isAccessible();
        Set<String> visitRecordTypes = VISIT_RECORD_TYPES;

        List<Task> tasks;
        if (cutoff == null) {
            tasks = [
                SELECT Id, OwnerId, Subject, Description, ActivityDate, Date_Meeting_Call__c,
                       Visit_Type__c, Visit_Category__c, Visit_Purpose__c, Audience__c,
                       RecordType.DeveloperName, RecordType.Name, What.Name,
                       Visit_Report__c, Visit_Report__r.Name, Visit_Report__r.Visit_Date__c,
                       Visit_Report__r.Visit_Type__c, Visit_Report__r.Category__c,
                       Visit_Report__r.Purpose__c, Visit_Report__r.Audience__c,
                       Visit_Report__r.Subject__c, Visit_Report__r.Notes__c,
                       Visit_Report__r.RecordType.Name
                FROM Task
                WHERE Id IN :taskIds
                  AND (Visit_Report__c != NULL OR RecordType.DeveloperName IN :visitRecordTypes)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT :TASK_SCAN_LIMIT
            ];
        } else {
            tasks = [
                SELECT Id, OwnerId, Subject, Description, ActivityDate, Date_Meeting_Call__c,
                       Visit_Type__c, Visit_Category__c, Visit_Purpose__c, Audience__c,
                       RecordType.DeveloperName, RecordType.Name, What.Name,
                       Visit_Report__c, Visit_Report__r.Name, Visit_Report__r.Visit_Date__c,
                       Visit_Report__r.Visit_Type__c, Visit_Report__r.Category__c,
                       Visit_Report__r.Purpose__c, Visit_Report__r.Audience__c,
                       Visit_Report__r.Subject__c, Visit_Report__r.Notes__c,
                       Visit_Report__r.RecordType.Name
                FROM Task
                WHERE Id IN :taskIds
                  AND (Visit_Report__c != NULL OR RecordType.DeveloperName IN :visitRecordTypes)
                  AND (Visit_Report__r.Visit_Date__c >= :cutoff
                       OR Date_Meeting_Call__c >= :cutoff
                       OR ActivityDate >= :cutoff)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT :TASK_SCAN_LIMIT
            ];
        }
        if (tasks.isEmpty()) {
            return result;
        }

        // Owner.Name does not resolve on Task in this org (OwnerId is populated but
        // the polymorphic Owner relationship comes back null), so look names up here.
        Set<Id> ownerIds = new Set<Id>();
        for (Task t : tasks) {
            if (t.OwnerId != null) {
                ownerIds.add(t.OwnerId);
            }
        }
        Map<Id, String> ownerNames = new Map<Id, String>();
        if (!ownerIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :ownerIds]) {
                ownerNames.put(u.Id, u.Name);
            }
        }

        // ---- Collapse to one row per visit. -------------------------------------
        // The SOQL date clause above is a coarse pre-filter: it has to OR together
        // three date sources because a legacy task has no visit report to read a date
        // from. That lets an OLD linked visit through whenever its task carries a
        // recent date (org automation stamps Date_Meeting_Call__c on insert), so the
        // window is re-applied per row below against the row's own effective date.
        Map<String, VisitRow> rowsByKey = new Map<String, VisitRow>();
        for (Task t : tasks) {
            VisitRow row;

            if (t.Visit_Report__c != null && t.Visit_Report__r != null) {
                // Pattern 1: a real Visit Report record. Key on it so several
                // attendee tasks collapse into a single row.
                String key = 'VR:' + t.Visit_Report__c;
                if (rowsByKey.containsKey(key)) {
                    continue;
                }
                Visit_Report__c vr = t.Visit_Report__r;
                row = new VisitRow();
                row.id = key;
                row.visitDate = vr.Visit_Date__c;
                row.visitType = vr.Visit_Type__c;
                row.category = vr.Category__c;
                row.purpose = vr.Purpose__c;
                row.audience = vr.Audience__c;
                row.subject = canReadVrSubject ? vr.Subject__c : null;
                row.notes = canReadVrNotes ? vr.Notes__c : null;
                row.recordType = vr.RecordType == null ? null : vr.RecordType.Name;
                row.targetId = vr.Id;
                row.targetName = vr.Name;
                row.location = t.What == null ? null : t.What.Name;
                row.loggedBy = ownerNames.get(t.OwnerId);
                row.source = SOURCE_RECORD;
                if (withinWindow(row.visitDate, cutoff)) {
                    rowsByKey.put(key, row);
                }
            } else if (t.RecordType != null && VISIT_RECORD_TYPES.contains(t.RecordType.DeveloperName)) {
                // Pattern 2: the task itself is the visit. Detail lives on the Activity.
                String key = 'TASK:' + t.Id;
                if (rowsByKey.containsKey(key)) {
                    continue;
                }
                row = new VisitRow();
                row.id = key;
                row.visitDate = t.Date_Meeting_Call__c != null ? t.Date_Meeting_Call__c : t.ActivityDate;
                row.visitType = t.Visit_Type__c;
                row.category = t.Visit_Category__c;
                row.purpose = t.Visit_Purpose__c;
                row.audience = t.Audience__c;
                row.subject = t.Subject;
                // Description holds the structured visit write-up on legacy records.
                row.notes = t.Description;
                row.recordType = t.RecordType.Name;
                row.targetId = t.Id;
                row.targetName = 'Open activity';
                row.location = t.What == null ? null : t.What.Name;
                row.loggedBy = ownerNames.get(t.OwnerId);
                row.source = SOURCE_ACTIVITY;
                if (withinWindow(row.visitDate, cutoff)) {
                    rowsByKey.put(key, row);
                }
            }
        }

        List<VisitRow> rows = rowsByKey.values();
        if (rows.isEmpty()) {
            return result;
        }
        rows.sort();

        if (rows.size() > effectiveLimit) {
            List<VisitRow> trimmed = new List<VisitRow>();
            for (Integer i = 0; i < effectiveLimit; i++) {
                trimmed.add(rows[i]);
            }
            rows = trimmed;
            result.truncated = true;
        }

        result.rows = rows;
        result.totalCount = rows.size();

        Date twelveMonthsAgo = Date.today().addMonths(-12);
        Map<String, Integer> countsByPurpose = new Map<String, Integer>();
        for (VisitRow row : rows) {
            if (row.visitDate != null && row.visitDate >= twelveMonthsAgo) {
                result.last12Count++;
            }
            if (row.source == SOURCE_ACTIVITY) {
                result.activityOnlyCount++;
            }
            // Legacy rows usually have no Purpose, so fall back to Category. Without
            // this the breakdown collapses into a single "(No purpose)" bar.
            String purpose = row.purpose;
            if (String.isBlank(purpose)) {
                purpose = row.category;
            }
            if (String.isBlank(purpose)) {
                purpose = '(Not specified)';
            }
            Integer current = countsByPurpose.get(purpose);
            countsByPurpose.put(purpose, current == null ? 1 : current + 1);
        }

        for (VisitRow row : rows) {
            if (row.visitDate != null) {
                result.mostRecentDate = row.visitDate;
                result.mostRecentBy = row.loggedBy;
                break;
            }
        }
        List<CategoryCount> purposes = new List<CategoryCount>();
        for (String name : countsByPurpose.keySet()) {
            CategoryCount cc = new CategoryCount();
            cc.name = name;
            cc.count = countsByPurpose.get(name);
            cc.percent = result.totalCount == 0
                ? 0
                : ((Decimal) cc.count / result.totalCount * 100).setScale(1);
            purposes.add(cc);
        }
        purposes.sort();
        result.purposes = purposes;
        result.purposeCount = purposes.size();

        return result;
    }

    /** All-time when there is no cutoff; undated rows are excluded from a window. */
    private static Boolean withinWindow(Date visitDate, Date cutoff) {
        if (cutoff == null) {
            return true;
        }
        return visitDate != null && visitDate >= cutoff;
    }

    private static Integer resolveLimit(Integer rowLimit) {
        if (rowLimit == null || rowLimit <= 0) {
            return DEFAULT_ROW_LIMIT;
        }
        return Math.min(rowLimit, MAX_ROW_LIMIT);
    }

    private static Date resolveCutoff(Integer monthsBack) {
        if (monthsBack == null || monthsBack <= 0) {
            return null;
        }
        return Date.today().addMonths(-monthsBack);
    }

    private static AuraHandledException buildException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // ---------------------------------------------------------------- wrappers

    public class VisitSummaryResult {
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer last12Count = 0;
        @AuraEnabled public Integer purposeCount = 0;
        /** How many rows came from the legacy activity-only pattern. */
        @AuraEnabled public Integer activityOnlyCount = 0;
        @AuraEnabled public Date mostRecentDate;
        @AuraEnabled public String mostRecentBy;
        @AuraEnabled public List<CategoryCount> purposes = new List<CategoryCount>();
        @AuraEnabled public List<VisitRow> rows = new List<VisitRow>();
        @AuraEnabled public Boolean truncated = false;
    }

    public class CategoryCount implements Comparable {
        @AuraEnabled public String name;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal percent;

        public Integer compareTo(Object other) {
            CategoryCount that = (CategoryCount) other;
            if (this.count == that.count) {
                return this.name == null ? 0 : this.name.compareTo(that.name);
            }
            return that.count - this.count;
        }
    }

    /** Sorts by visit date descending, undated rows last. */
    public class VisitRow implements Comparable {
        @AuraEnabled public String id;
        @AuraEnabled public Date visitDate;
        @AuraEnabled public String subject;
        @AuraEnabled public String visitType;
        @AuraEnabled public String category;
        @AuraEnabled public String purpose;
        @AuraEnabled public String audience;
        @AuraEnabled public String notes;
        @AuraEnabled public String location;
        /** Record to open: the Visit Report when there is one, otherwise the Task. */
        @AuraEnabled public Id targetId;
        @AuraEnabled public String targetName;
        @AuraEnabled public String loggedBy;
        @AuraEnabled public String recordType;
        @AuraEnabled public String source;

        public Integer compareTo(Object other) {
            VisitRow that = (VisitRow) other;
            if (this.visitDate == null && that.visitDate == null) {
                return 0;
            }
            if (this.visitDate == null) {
                return 1;
            }
            if (that.visitDate == null) {
                return -1;
            }
            if (this.visitDate == that.visitDate) {
                return 0;
            }
            return this.visitDate > that.visitDate ? -1 : 1;
        }
    }
}
