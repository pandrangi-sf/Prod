public with sharing class CR_VisitActivityServiceFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    // THE retention window for all three PRM fan-out facts — CR_ETLScheduler and the
    // Collateral/Objection batches read this constant, so change it here only.
    //
    // 18 months, not 7: fiscal-year reporting (FY starts Oct 1) needs the whole FY in the
    // fact table, and finish() prunes anything outside this window on every nightly full run.
    // 18 keeps the current FY complete through ~Q2 of the following FY. Costs little — activity
    // volume in the added months is roughly half the recent run rate.
    public static final Integer DEFAULT_LOOKBACK_MONTHS = 18;

    private final Date snapshotDate;
    private final Date earliestMeetingDate;
    // Optional incremental-refresh cutoff. LastModifiedDate is a system field
    // (no FLS), so it's safe to filter on here unlike Date_Meeting_Call__c.
    private Datetime sinceDate;

    public CR_VisitActivityServiceFactBatch() {
        this(Date.today(), Date.today().addMonths(-DEFAULT_LOOKBACK_MONTHS));
    }

    public CR_VisitActivityServiceFactBatch(Date snapshotDate, Date earliestMeetingDate) {
        this(snapshotDate, earliestMeetingDate, null);
    }

    public CR_VisitActivityServiceFactBatch(Date snapshotDate, Date earliestMeetingDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.earliestMeetingDate = earliestMeetingDate == null
            ? Date.today().addMonths(-DEFAULT_LOOKBACK_MONTHS)
            : earliestMeetingDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        // Note: we used to bound this by Date_Meeting_Call__c >= earliestMeetingDate, but the
        // running user's profile lacks FLS read on that field, which causes SOQL filter
        // predicates against it to silently match zero rows. The Visit_Report__c filter
        // alone is sufficient (~9990 source Tasks today). Date filtering moves to the post-
        // SELECT execute() phase below where Apex can compare the field value safely.
        Date scopeFloor = earliestMeetingDate;
        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Subject, RecordType.Name, Visit_Category__c, Audience__c,
                    Owner.Name, Owner.UserRole.Name,
                    Date_Meeting_Call__c, AccountId, Account.Name,
                    Visit_Report__c, Visit_Report__r.Name,
                    CreatedDate, CreatedBy.Name
                FROM Task
                WHERE Visit_Report__c != null AND LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Subject, RecordType.Name, Visit_Category__c, Audience__c,
                Owner.Name, Owner.UserRole.Name,
                Date_Meeting_Call__c, AccountId, Account.Name,
                Visit_Report__c, Visit_Report__r.Name,
                CreatedDate, CreatedBy.Name
            FROM Task
            WHERE Visit_Report__c != null
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Set<Id> taskIds = new Set<Id>();
        Set<Id> visitReportIds = new Set<Id>();
        for (SObject row : scope) {
            Task task = (Task) row;
            // Date scope filter applied post-SELECT (see start() comment).
            if (task.Date_Meeting_Call__c != null && task.Date_Meeting_Call__c < earliestMeetingDate) continue;
            taskIds.add(task.Id);
            if (task.Visit_Report__c != null) visitReportIds.add(task.Visit_Report__c);
        }
        if (taskIds.isEmpty()) return;

        // Visit_Service rows for the Visit_Reports linked to this chunk's Tasks.
        Map<Id, List<Visit_Service__c>> servicesByVisitReport = new Map<Id, List<Visit_Service__c>>();
        for (Visit_Service__c vs : [
            SELECT Id, Visit_Report__c, Service__c, Service__r.Name
            FROM Visit_Service__c
            WHERE Visit_Report__c IN :visitReportIds
        ]) {
            if (!servicesByVisitReport.containsKey(vs.Visit_Report__c)) {
                servicesByVisitReport.put(vs.Visit_Report__c, new List<Visit_Service__c>());
            }
            servicesByVisitReport.get(vs.Visit_Report__c).add(vs);
        }

        // Shared-activity contacts for this chunk's Tasks.
        Map<Id, List<TaskWhoRelation>> contactsByTask = new Map<Id, List<TaskWhoRelation>>();
        Set<Id> providerContactIds = new Set<Id>();
        for (TaskWhoRelation twr : [
            SELECT Id, TaskId, RelationId, Relation.FirstName, Relation.LastName, Relation.Name
            FROM TaskWhoRelation
            WHERE TaskId IN :taskIds AND Type = 'Contact'
        ]) {
            if (!contactsByTask.containsKey(twr.TaskId)) {
                contactsByTask.put(twr.TaskId, new List<TaskWhoRelation>());
            }
            contactsByTask.get(twr.TaskId).add(twr);
            if (twr.RelationId != null) providerContactIds.add(twr.RelationId);
        }

        // Provider NPI lives on the Contact, not on TaskWhoRelation's polymorphic Relation
        // (Name has no npi__c). Resolve it with a direct Contact query keyed by RelationId so
        // the fact carries NPI; Provider_Id__c is plain text and can't be joined at report time.
        Map<Id, String> npiByContactId = new Map<Id, String>();
        if (!providerContactIds.isEmpty()) {
            for (Contact provider : [SELECT Id, npi__c FROM Contact WHERE Id IN :providerContactIds]) {
                npiByContactId.put(provider.Id, provider.npi__c);
            }
        }

        List<Fact_VisitActivityService__c> facts = new List<Fact_VisitActivityService__c>();
        for (SObject row : scope) {
            Task task = (Task) row;
            List<Visit_Service__c> services = servicesByVisitReport.get(task.Visit_Report__c);
            // INNER-JOIN semantics on services: skip Tasks with no service rows (matches the PRM view).
            if (services == null || services.isEmpty()) continue;

            List<TaskWhoRelation> contacts = contactsByTask.get(task.Id);
            // LEFT-JOIN semantics on contacts: a Task with no related contact still produces rows
            // (with null Provider_* fields) for every service. Use a sentinel null entry to drive
            // the cartesian product cleanly.
            if (contacts == null || contacts.isEmpty()) {
                contacts = new List<TaskWhoRelation>{ null };
            }

            String region = deriveRegion(task.Owner == null ? null : task.Owner.UserRole == null ? null : task.Owner.UserRole.Name);
            String assignedRole = task.Owner == null || task.Owner.UserRole == null ? null : task.Owner.UserRole.Name;
            String assignedTo = task.Owner == null ? null : task.Owner.Name;
            String practiceName = task.Account == null ? null : task.Account.Name;
            String visitReportNumber = task.Visit_Report__r == null ? null : task.Visit_Report__r.Name;
            String createdByName = task.CreatedBy == null ? null : task.CreatedBy.Name;
            String recordTypeName = task.RecordType == null ? null : task.RecordType.Name;

            for (Visit_Service__c vs : services) {
                String serviceName = vs.Service__r == null ? null : vs.Service__r.Name;
                for (TaskWhoRelation twr : contacts) {
                    Fact_VisitActivityService__c fact = new Fact_VisitActivityService__c();
                    fact.Source_Key__c = task.Id + ':' + vs.Id + ':' + (twr == null ? 'noContact' : String.valueOf(twr.Id));
                    fact.Name = (task.Subject == null ? String.valueOf(task.Id) : task.Subject).left(80);
                    fact.Activity_Id__c = task.Id;
                    fact.Subject__c = task.Subject;
                    fact.Record_Type__c = recordTypeName;
                    fact.Visit_Category__c = task.Visit_Category__c;
                    fact.Audience__c = task.Audience__c;
                    fact.Assigned_To__c = assignedTo;
                    fact.Assigned_Role__c = assignedRole;
                    fact.Region__c = region;
                    fact.Date_Of_Meeting__c = task.Date_Meeting_Call__c;
                    fact.Practice_Group_Name__c = practiceName;
                    fact.Visit_Report_Number__c = visitReportNumber;
                    fact.Activity_Created_Date__c = task.CreatedDate;
                    fact.Activity_Created_By__c = createdByName;
                    fact.Service__c = serviceName;
                    fact.Snapshot_Date__c = snapshotDate;
                    if (twr != null) {
                        fact.Provider_Id__c = twr.RelationId;
                        fact.Provider_NPI__c = npiByContactId.get(twr.RelationId);
                        if (twr.Relation != null) {
                            fact.Provider_First_Name__c = (String) twr.Relation.get('FirstName');
                            fact.Provider_Last_Name__c = (String) twr.Relation.get('LastName');
                            fact.Provider_Full_Name__c = (String) twr.Relation.get('Name');
                        }
                    }
                    facts.add(fact);
                }
            }
        }

        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_VisitActivityService__c.Fields.Source_Key__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
        // Incremental runs (sinceDate set) only add/update recently-changed records;
        // stale-row cleanup is a full-refresh responsibility. Skipping it here avoids
        // deleting every fact outside this narrow incremental window.
        if (sinceDate != null) return;
        // Cleanup stale rows: anything not refreshed in this run.
        Date runDate = snapshotDate;
        List<Fact_VisitActivityService__c> stale = [
            SELECT Id FROM Fact_VisitActivityService__c
            WHERE Snapshot_Date__c < :runDate OR Snapshot_Date__c = null
            LIMIT 10000
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
            if (stale.size() >= 10000) {
                System.debug(LoggingLevel.WARN, 'CR_VisitActivityServiceFactBatch: stale-row cleanup hit the 10000 LIMIT — additional stale rows likely remain. Chain a follow-up cleanup batch.');
            }
        }
    }

    private static String deriveRegion(String roleName) {
        if (String.isBlank(roleName)) return 'Other';
        String lower = roleName.toLowerCase();
        if (lower.contains('alabama')) return 'Alabama';
        if (lower.contains('florida')) return 'Florida';
        return 'Other';
    }
}