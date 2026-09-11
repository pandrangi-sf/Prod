public with sharing class CR_UnzonedTargetFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Date snapshotDate;
    private Datetime sinceDate;

    // Pre-computed once in start(): the set of Provider Ids that DO have at least
    // one active, non-DNU ProviderLocation whose Location is also a ZonedLocation.
    // The execute() phase then emits a fact row for any Target whose provider is
    // NOT in this set -- the anti-join from the original PRM view.
    private Set<Id> zonedCoveredProviderIds = new Set<Id>();

    public CR_UnzonedTargetFactBatch() {
        this(Date.today());
    }

    public CR_UnzonedTargetFactBatch(Date snapshotDate) {
        this(snapshotDate, null);
    }

    public CR_UnzonedTargetFactBatch(Date snapshotDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        // Load the set of zoned Location Ids first. Then collect Provider Ids
        // that have at least one active, non-DNU ProviderLocation pointing at one
        // of those zoned Locations.
        Set<Id> zonedLocationIds = new Set<Id>();
        for (ZonedLocation__c zl : [SELECT Location__c FROM ZonedLocation__c WHERE Location__c != null]) {
            zonedLocationIds.add(zl.Location__c);
        }
        if (!zonedLocationIds.isEmpty()) {
            for (ProviderLocation__c pl : [
                SELECT Provider__c FROM ProviderLocation__c
                WHERE Location__c IN :zonedLocationIds
                  AND Active__c = true
                  AND DNU__c = false
                  AND Provider__c != null
            ]) {
                zonedCoveredProviderIds.add(pl.Provider__c);
            }
        }

        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Name, Region__c, Territory_Name__c, Owner_Name__c,
                    Target_Provider__c, Target_Provider__r.Name, Sub_Region__c, Rank__c,
                    Target_Last_Visit__c, Last_Visit_Group__c, Days_Since_Last_Visit__c,
                    Visits_Last_90_Days__c, Target_Specialty__c, Target_Affiliation__c,
                    Target_Practice__c, Target_NPI__c, CreatedBy.Name, CreatedDate
                FROM Target__c
                WHERE Target_Provider__c != null AND LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, Region__c, Territory_Name__c, Owner_Name__c,
                Target_Provider__c, Target_Provider__r.Name, Sub_Region__c, Rank__c,
                Target_Last_Visit__c, Last_Visit_Group__c, Days_Since_Last_Visit__c,
                Visits_Last_90_Days__c, Target_Specialty__c, Target_Affiliation__c,
                Target_Practice__c, Target_NPI__c, CreatedBy.Name, CreatedDate
            FROM Target__c
            WHERE Target_Provider__c != null
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<Fact_UnzonedTarget__c> facts = new List<Fact_UnzonedTarget__c>();
        for (SObject row : scope) {
            Target__c t = (Target__c) row;
            // Anti-join: skip Targets whose provider has zoned coverage.
            if (zonedCoveredProviderIds.contains(t.Target_Provider__c)) continue;

            Fact_UnzonedTarget__c f = new Fact_UnzonedTarget__c();
            f.Source_Key__c = String.valueOf(t.Id);
            f.Name = (t.Name == null ? String.valueOf(t.Id) : t.Name).left(80);
            f.Target_Id__c = t.Id;
            f.Target_Name__c = t.Name;
            f.Region__c = t.Region__c;
            f.Territory_Name__c = t.Territory_Name__c;
            f.Owner_Name__c = t.Owner_Name__c;
            f.Target_Provider_Id__c = t.Target_Provider__c;
            f.Target_Provider_Name__c = t.Target_Provider__r == null ? null : t.Target_Provider__r.Name;
            f.Sub_Region__c = t.Sub_Region__c;
            f.Rank__c = t.Rank__c;
            f.Last_Visit_Date__c = t.Target_Last_Visit__c;
            f.Last_Visit_Group__c = t.Last_Visit_Group__c;
            f.Days_Since_Last_Visit__c = t.Days_Since_Last_Visit__c;
            f.Visits_Last_90_Days__c = t.Visits_Last_90_Days__c;
            f.Target_Specialty__c = t.Target_Specialty__c;
            f.Target_Affiliation__c = t.Target_Affiliation__c;
            f.Target_Practice__c = t.Target_Practice__c;
            f.Target_NPI__c = t.Target_NPI__c;
            f.Created_By__c = t.CreatedBy == null ? null : t.CreatedBy.Name;
            f.Created_Date__c = t.CreatedDate;
            f.Snapshot_Date__c = snapshotDate;
            facts.add(f);
        }
        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_UnzonedTarget__c.Fields.Source_Key__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
        // Incremental runs (sinceDate set) only add/update recently-changed records;
        // skip the full-refresh stale-row cleanup so it can't delete facts outside
        // this narrow incremental window.
        if (sinceDate != null) return;
        Date runDate = snapshotDate;
        List<Fact_UnzonedTarget__c> stale = [
            SELECT Id FROM Fact_UnzonedTarget__c
            WHERE Snapshot_Date__c < :runDate OR Snapshot_Date__c = null
            LIMIT 10000
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
            if (stale.size() >= 10000) {
                System.debug(LoggingLevel.WARN, 'CR_UnzonedTargetFactBatch: stale-row cleanup hit the 10000 LIMIT — additional stale rows likely remain. Chain a follow-up cleanup batch.');
            }
        }
    }
}