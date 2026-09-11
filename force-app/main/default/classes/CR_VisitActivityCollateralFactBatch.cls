public with sharing class CR_VisitActivityCollateralFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    // Shared with the other PRM fan-out facts so Activities-with-X reports can't disagree
    // on range — see the note on the constant in CR_VisitActivityServiceFactBatch.
    private static final Integer DEFAULT_LOOKBACK_MONTHS =
        CR_VisitActivityServiceFactBatch.DEFAULT_LOOKBACK_MONTHS;

    private final Date snapshotDate;
    private final Date earliestMeetingDate;
    private Datetime sinceDate;

    public CR_VisitActivityCollateralFactBatch() {
        this(Date.today(), Date.today().addMonths(-DEFAULT_LOOKBACK_MONTHS));
    }

    public CR_VisitActivityCollateralFactBatch(Date snapshotDate, Date earliestMeetingDate) {
        this(snapshotDate, earliestMeetingDate, null);
    }

    public CR_VisitActivityCollateralFactBatch(Date snapshotDate, Date earliestMeetingDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.earliestMeetingDate = earliestMeetingDate == null
            ? Date.today().addMonths(-DEFAULT_LOOKBACK_MONTHS)
            : earliestMeetingDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        // Date filter applied post-SELECT in execute() because the running profile lacks
        // FLS on Date_Meeting_Call__c (silent zero-rows on SOQL filter). LastModifiedDate
        // is a system field with no FLS, so it's safe as the incremental-refresh cutoff.
        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Subject, RecordType.Name, Visit_Category__c,
                    Owner.Name, Owner.UserRole.Name,
                    Date_Meeting_Call__c, AccountId, Account.Name,
                    WhatId, What.Name,
                    Visit_Report__c, Visit_Report__r.Name,
                    CreatedDate, CreatedBy.Name
                FROM Task
                WHERE Visit_Report__c != null AND LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Subject, RecordType.Name, Visit_Category__c,
                Owner.Name, Owner.UserRole.Name,
                Date_Meeting_Call__c, AccountId, Account.Name,
                WhatId, What.Name,
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
            if (task.Date_Meeting_Call__c != null && task.Date_Meeting_Call__c < earliestMeetingDate) continue;
            taskIds.add(task.Id);
            if (task.Visit_Report__c != null) visitReportIds.add(task.Visit_Report__c);
        }
        if (taskIds.isEmpty()) return;

        Map<Id, List<Visit_Collateral__c>> collateralByVisitReport = new Map<Id, List<Visit_Collateral__c>>();
        for (Visit_Collateral__c vc : [
            SELECT Id, Visit_Report__c, Collateral__c, Collateral__r.Name
            FROM Visit_Collateral__c
            WHERE Visit_Report__c IN :visitReportIds
        ]) {
            if (!collateralByVisitReport.containsKey(vc.Visit_Report__c)) {
                collateralByVisitReport.put(vc.Visit_Report__c, new List<Visit_Collateral__c>());
            }
            collateralByVisitReport.get(vc.Visit_Report__c).add(vc);
        }

        Map<Id, List<TaskWhoRelation>> contactsByTask = new Map<Id, List<TaskWhoRelation>>();
        for (TaskWhoRelation twr : [
            SELECT Id, TaskId, RelationId, Relation.FirstName, Relation.LastName, Relation.Name
            FROM TaskWhoRelation
            WHERE TaskId IN :taskIds AND Type = 'Contact'
        ]) {
            if (!contactsByTask.containsKey(twr.TaskId)) {
                contactsByTask.put(twr.TaskId, new List<TaskWhoRelation>());
            }
            contactsByTask.get(twr.TaskId).add(twr);
        }

        List<Fact_VisitActivityCollateral__c> facts = new List<Fact_VisitActivityCollateral__c>();
        for (SObject row : scope) {
            Task task = (Task) row;
            List<Visit_Collateral__c> collaterals = collateralByVisitReport.get(task.Visit_Report__c);
            if (collaterals == null || collaterals.isEmpty()) continue;

            List<TaskWhoRelation> contacts = contactsByTask.get(task.Id);
            if (contacts == null || contacts.isEmpty()) {
                contacts = new List<TaskWhoRelation>{ null };
            }

            String region = deriveRegion(task.Owner == null || task.Owner.UserRole == null ? null : task.Owner.UserRole.Name);
            String assignedRole = task.Owner == null || task.Owner.UserRole == null ? null : task.Owner.UserRole.Name;
            String assignedTo = task.Owner == null ? null : task.Owner.Name;
            String practiceName = task.Account == null ? null : task.Account.Name;
            String relatedTo = task.What == null ? null : (String) task.What.get('Name');
            String visitReportNumber = task.Visit_Report__r == null ? null : task.Visit_Report__r.Name;
            String createdByName = task.CreatedBy == null ? null : task.CreatedBy.Name;
            String recordTypeName = task.RecordType == null ? null : task.RecordType.Name;

            for (Visit_Collateral__c vc : collaterals) {
                String collateralName = vc.Collateral__r == null ? null : vc.Collateral__r.Name;
                for (TaskWhoRelation twr : contacts) {
                    Fact_VisitActivityCollateral__c fact = new Fact_VisitActivityCollateral__c();
                    fact.Source_Key__c = task.Id + ':' + vc.Id + ':' + (twr == null ? 'noContact' : String.valueOf(twr.Id));
                    fact.Name = (task.Subject == null ? String.valueOf(task.Id) : task.Subject).left(80);
                    fact.Activity_Id__c = task.Id;
                    fact.Subject__c = task.Subject;
                    fact.Record_Type__c = recordTypeName;
                    fact.Visit_Category__c = task.Visit_Category__c;
                    fact.Assigned_To__c = assignedTo;
                    fact.Assigned_Role__c = assignedRole;
                    fact.Region__c = region;
                    fact.Date_Of_Meeting__c = task.Date_Meeting_Call__c;
                    fact.Practice_Group_Name__c = practiceName;
                    fact.Related_To__c = relatedTo;
                    fact.Visit_Report_Number__c = visitReportNumber;
                    fact.Activity_Created_Date__c = task.CreatedDate;
                    fact.Activity_Created_By__c = createdByName;
                    fact.Collateral__c = collateralName;
                    fact.Snapshot_Date__c = snapshotDate;
                    if (twr != null) {
                        fact.Provider_Id__c = twr.RelationId;
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
            Database.upsert(facts, Fact_VisitActivityCollateral__c.Fields.Source_Key__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
        // Incremental runs (sinceDate set) only add/update recently-changed records;
        // skip the full-refresh stale-row cleanup so it can't delete facts outside
        // this narrow incremental window.
        if (sinceDate != null) return;
        Date runDate = snapshotDate;
        List<Fact_VisitActivityCollateral__c> stale = [
            SELECT Id FROM Fact_VisitActivityCollateral__c
            WHERE Snapshot_Date__c < :runDate OR Snapshot_Date__c = null
            LIMIT 10000
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
            if (stale.size() >= 10000) {
                System.debug(LoggingLevel.WARN, 'CR_VisitActivityCollateralFactBatch: stale-row cleanup hit the 10000 LIMIT — additional stale rows likely remain. Chain a follow-up cleanup batch.');
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