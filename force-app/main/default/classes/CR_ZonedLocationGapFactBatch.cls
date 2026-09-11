public with sharing class CR_ZonedLocationGapFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Date snapshotDate;

    // Pre-computed in start(): set of "Owner|Location" composite keys for which a
    // Target exists with the same PRM (Owner) AND a provider with an active non-DNU
    // ProviderLocation pointing at that Location. The execute() phase emits a fact
    // row for any ZonedLocation NOT in this set -- the anti-join from the original
    // ZonedLocationsWithoutTargets PRM view.
    private Set<String> coveredOwnerLocationKeys = new Set<String>();
    private Map<Id, String> territoryRecordTypeById = new Map<Id, String>();

    private Datetime sinceDate;

    public CR_ZonedLocationGapFactBatch() {
        this(Date.today());
    }

    public CR_ZonedLocationGapFactBatch(Date snapshotDate) {
        this(snapshotDate, null);
    }

    public CR_ZonedLocationGapFactBatch(Date snapshotDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        // Build the covered (Owner, Location) set by joining ProviderLocation x Target.
        // Keyed on Owner_Name to match the PRM view's t."Owner" = zl."Owner" predicate.
        Map<Id, Set<String>> ownersByProvider = new Map<Id, Set<String>>();
        for (Target__c t : [
            SELECT Owner_Name__c, Target_Provider__c
            FROM Target__c
            WHERE Target_Provider__c != null AND Owner_Name__c != null
        ]) {
            if (!ownersByProvider.containsKey(t.Target_Provider__c)) {
                ownersByProvider.put(t.Target_Provider__c, new Set<String>());
            }
            ownersByProvider.get(t.Target_Provider__c).add(t.Owner_Name__c);
        }

        if (!ownersByProvider.isEmpty()) {
            Set<Id> providerIds = ownersByProvider.keySet();
            for (ProviderLocation__c pl : [
                SELECT Provider__c, Location__c
                FROM ProviderLocation__c
                WHERE Provider__c IN :providerIds
                  AND Active__c = true
                  AND DNU__c = false
                  AND Location__c != null
            ]) {
                Set<String> owners = ownersByProvider.get(pl.Provider__c);
                if (owners == null) continue;
                for (String owner : owners) {
                    coveredOwnerLocationKeys.add(owner + '|' + pl.Location__c);
                }
            }
        }

        // Pre-load Territory record types (small set) to derive State at row-build time.
        for (Territory__c terr : [SELECT Id, RecordType.Name FROM Territory__c]) {
            territoryRecordTypeById.put(terr.Id, terr.RecordType == null ? null : terr.RecordType.Name);
        }

        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Name, Territory_Owner__c, Territory__c, Location__c,
                    Location_Practice_Group__c, Location_Name_Text__c,
                    Zoned_Location_Zip__c, Zoned_Location_City__c,
                    Zone_Name__c, LastVisitDate__c, Last_Visit_Group__c,
                    Days_Since_Last_Visit__c, Visits_Last_90_Days__c
                FROM ZonedLocation__c
                WHERE Territory_Owner__c != null AND Location__c != null
                  AND LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, Territory_Owner__c, Territory__c, Location__c,
                Location_Practice_Group__c, Location_Name_Text__c,
                Zoned_Location_Zip__c, Zoned_Location_City__c,
                Zone_Name__c, LastVisitDate__c, Last_Visit_Group__c,
                Days_Since_Last_Visit__c, Visits_Last_90_Days__c
            FROM ZonedLocation__c
            WHERE Territory_Owner__c != null AND Location__c != null
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Set<Id> territoryIds = new Set<Id>();
        for (SObject row : scope) {
            ZonedLocation__c zl = (ZonedLocation__c) row;
            if (zl.Territory__c != null) territoryIds.add(zl.Territory__c);
        }

        Map<Id, String> territoryNameById = new Map<Id, String>();
        if (!territoryIds.isEmpty()) {
            for (Territory__c terr : [SELECT Id, Name FROM Territory__c WHERE Id IN :territoryIds]) {
                territoryNameById.put(terr.Id, terr.Name);
            }
        }

        // Distinct collapse: a single zoned location can appear multiple rows in source.
        Set<String> seenKeys = new Set<String>();
        List<Fact_ZonedLocationGap__c> facts = new List<Fact_ZonedLocationGap__c>();
        for (SObject row : scope) {
            ZonedLocation__c zl = (ZonedLocation__c) row;
            String key = zl.Territory_Owner__c + '|' + zl.Location__c;
            if (coveredOwnerLocationKeys.contains(key)) continue; // anti-join: skip if already covered

            // Distinct on (zoned location id) — drop duplicate rows up front.
            if (seenKeys.contains(zl.Id)) continue;
            seenKeys.add(zl.Id);

            String territoryName = zl.Territory__c == null ? null : territoryNameById.get(zl.Territory__c);
            String state = deriveState(territoryRecordTypeById.get(zl.Territory__c));

            Fact_ZonedLocationGap__c f = new Fact_ZonedLocationGap__c();
            f.Source_Key__c = String.valueOf(zl.Id);
            f.Name = (zl.Name == null ? String.valueOf(zl.Id) : zl.Name).left(80);
            f.ZonedLocation_Id__c = zl.Id;
            f.Owner_Name__c = zl.Territory_Owner__c;
            f.Territory_Name__c = territoryName;
            f.State__c = state;
            f.Location_Name_Text__c = zl.Location_Name_Text__c;
            f.Location_City__c = zl.Zoned_Location_City__c;
            f.Location_Zip__c = zl.Zoned_Location_Zip__c;
            f.Location_Practice_Group__c = zl.Location_Practice_Group__c;
            f.Zone_Name__c = zl.Zone_Name__c;
            f.Last_Visit_Date__c = zl.LastVisitDate__c;
            f.Last_Visit_Group__c = zl.Last_Visit_Group__c;
            f.Days_Since_Last_Visit__c = zl.Days_Since_Last_Visit__c;
            f.Visits_Last_90_Days__c = zl.Visits_Last_90_Days__c;
            f.Snapshot_Date__c = snapshotDate;
            facts.add(f);
        }
        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_ZonedLocationGap__c.Fields.Source_Key__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
        // Incremental runs (sinceDate set) only add/update recently-changed records;
        // skip the full-refresh stale-row cleanup so it can't delete facts outside
        // this narrow incremental window.
        if (sinceDate != null) return;
        Date runDate = snapshotDate;
        List<Fact_ZonedLocationGap__c> stale = [
            SELECT Id FROM Fact_ZonedLocationGap__c
            WHERE Snapshot_Date__c < :runDate OR Snapshot_Date__c = null
            LIMIT 10000
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
            if (stale.size() >= 10000) {
                System.debug(LoggingLevel.WARN, 'CR_ZonedLocationGapFactBatch: stale-row cleanup hit the 10000 LIMIT — additional stale rows likely remain. Chain a follow-up cleanup batch.');
            }
        }
    }

    private static String deriveState(String recordTypeName) {
        if (String.isBlank(recordTypeName)) return 'Unknown';
        if (recordTypeName.startsWith('PRM AL')) return 'Alabama';
        if (recordTypeName.startsWith('PRM FL')) return 'Florida';
        return 'Unknown';
    }
}