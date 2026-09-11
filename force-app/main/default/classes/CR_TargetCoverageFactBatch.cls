public with sharing class CR_TargetCoverageFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Date snapshotDate;
    private Datetime sinceDate;

    public CR_TargetCoverageFactBatch() {
        this(Date.today());
    }

    public CR_TargetCoverageFactBatch(Date snapshotDate) {
        this(snapshotDate, null);
    }

    public CR_TargetCoverageFactBatch(Date snapshotDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Name, Owner_Name__c, Target_NPI__c, Rank__c,
                    Target_Specialty__c, Target_Practice__c,
                    Target_Provider__c, Target_Provider__r.Name,
                    Territory__c, Territory_Name__c
                FROM Target__c
                WHERE Target_Provider__c != null AND LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, Owner_Name__c, Target_NPI__c, Rank__c,
                Target_Specialty__c, Target_Practice__c,
                Target_Provider__c, Target_Provider__r.Name,
                Territory__c, Territory_Name__c
            FROM Target__c
            WHERE Target_Provider__c != null
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Set<Id> territoryIds = new Set<Id>();
        Set<Id> providerIds = new Set<Id>();
        for (SObject row : scope) {
            Target__c t = (Target__c) row;
            if (t.Territory__c != null) territoryIds.add(t.Territory__c);
            if (t.Target_Provider__c != null) providerIds.add(t.Target_Provider__c);
        }

        // Territory record types for region derivation.
        Map<Id, String> territoryRecordTypeById = new Map<Id, String>();
        if (!territoryIds.isEmpty()) {
            for (Territory__c terr : [
                SELECT Id, RecordType.Name FROM Territory__c WHERE Id IN :territoryIds
            ]) {
                territoryRecordTypeById.put(terr.Id, terr.RecordType == null ? null : terr.RecordType.Name);
            }
        }

        // Provider basics for full-name + link.
        Map<Id, Contact> providerById = new Map<Id, Contact>();
        if (!providerIds.isEmpty()) {
            providerById = new Map<Id, Contact>([
                SELECT Id, FirstName, LastName FROM Contact WHERE Id IN :providerIds
            ]);
        }

        // Active, non-DNU ProviderLocations for these providers.
        Map<Id, List<ProviderLocation__c>> plByProvider = new Map<Id, List<ProviderLocation__c>>();
        Set<Id> locationIds = new Set<Id>();
        if (!providerIds.isEmpty()) {
            for (ProviderLocation__c pl : [
                SELECT Id, Provider__c, Location__c
                FROM ProviderLocation__c
                WHERE Provider__c IN :providerIds
                  AND Active__c = true
                  AND DNU__c = false
            ]) {
                if (!plByProvider.containsKey(pl.Provider__c)) {
                    plByProvider.put(pl.Provider__c, new List<ProviderLocation__c>());
                }
                plByProvider.get(pl.Provider__c).add(pl);
                if (pl.Location__c != null) locationIds.add(pl.Location__c);
            }
        }

        // Non-DNU Locations.
        Map<Id, Location__c> locationById = new Map<Id, Location__c>();
        if (!locationIds.isEmpty()) {
            for (Location__c loc : [
                SELECT Id, Name, Address__Street__s, Address__City__s,
                    Address__StateCode__s, Address__PostalCode__s, Alabama_Sub_Region__c
                FROM Location__c
                WHERE Id IN :locationIds AND DNU__c = false
            ]) {
                locationById.put(loc.Id, loc);
            }
        }

        String orgInstanceUrl = URL.getOrgDomainUrl().toExternalForm();

        List<Fact_TargetCoverage__c> facts = new List<Fact_TargetCoverage__c>();
        for (SObject row : scope) {
            Target__c t = (Target__c) row;
            String region = deriveRegion(territoryRecordTypeById.get(t.Territory__c));
            Contact provider = providerById.get(t.Target_Provider__c);
            String providerFullName = provider == null ? null : ((provider.FirstName == null ? '' : provider.FirstName) + ' ' + (provider.LastName == null ? '' : provider.LastName)).trim();
            String providerLink = orgInstanceUrl + '/' + t.Target_Provider__c;

            List<ProviderLocation__c> pls = plByProvider.get(t.Target_Provider__c);
            // LEFT-join semantics: if no active provider-location, still emit one row with null location fields.
            if (pls == null || pls.isEmpty()) {
                facts.add(buildFact(t, region, provider, providerFullName, providerLink, null, null));
                continue;
            }
            for (ProviderLocation__c pl : pls) {
                Location__c loc = pl.Location__c == null ? null : locationById.get(pl.Location__c);
                facts.add(buildFact(t, region, provider, providerFullName, providerLink, pl, loc));
            }
        }

        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_TargetCoverage__c.Fields.Source_Key__c, false);
        }
    }

    private Fact_TargetCoverage__c buildFact(Target__c t, String region, Contact provider, String providerFullName, String providerLink, ProviderLocation__c pl, Location__c loc) {
        Fact_TargetCoverage__c f = new Fact_TargetCoverage__c();
        String locKey = (loc == null ? 'noLocation' : String.valueOf(loc.Id));
        f.Source_Key__c = String.valueOf(t.Id) + ':' + locKey;
        f.Name = (t.Name == null ? String.valueOf(t.Id) : t.Name).left(80);
        f.Target_Id__c = t.Id;
        f.Target_Name__c = t.Target_Provider__r == null ? null : t.Target_Provider__r.Name;
        f.Territory_Name__c = t.Territory_Name__c;
        f.Region__c = region;
        f.PRM__c = t.Owner_Name__c;
        f.Provider_NPI__c = t.Target_NPI__c;
        f.Provider_Id__c = t.Target_Provider__c;
        f.Provider_Full_Name__c = providerFullName;
        f.Provider_Link__c = providerLink;
        f.Rank__c = t.Rank__c;
        f.Primary_Specialty__c = t.Target_Specialty__c;
        f.Practice_Group_Name__c = t.Target_Practice__c;
        if (loc != null) {
            f.Location_Id__c = loc.Id;
            f.Location_Name__c = loc.Name;
            f.Location_Address__c = (String) loc.get('Address__Street__s');
            f.City__c = (String) loc.get('Address__City__s');
            f.State__c = (String) loc.get('Address__StateCode__s');
            String zip = (String) loc.get('Address__PostalCode__s');
            f.Zip__c = String.isBlank(zip) ? null : zip.left(5);
            f.Alabama_Sub_Region__c = loc.Alabama_Sub_Region__c;
        }
        f.Snapshot_Date__c = snapshotDate;
        return f;
    }

    public void finish(Database.BatchableContext context) {
        // Incremental runs (sinceDate set) only add/update recently-changed records;
        // skip the full-refresh stale-row cleanup so it can't delete facts outside
        // this narrow incremental window.
        if (sinceDate != null) return;
        Date runDate = snapshotDate;
        List<Fact_TargetCoverage__c> stale = [
            SELECT Id FROM Fact_TargetCoverage__c
            WHERE Snapshot_Date__c < :runDate OR Snapshot_Date__c = null
            LIMIT 10000
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
            if (stale.size() >= 10000) {
                System.debug(LoggingLevel.WARN, 'CR_TargetCoverageFactBatch: stale-row cleanup hit the 10000 LIMIT — additional stale rows likely remain. Chain a follow-up cleanup batch.');
            }
        }
    }

    private static String deriveRegion(String recordTypeName) {
        if (String.isBlank(recordTypeName)) return 'Other';
        if (recordTypeName.startsWith('PRM AL')) return 'Alabama';
        if (recordTypeName.startsWith('PRM FL')) return 'Florida';
        return 'Other';
    }
}