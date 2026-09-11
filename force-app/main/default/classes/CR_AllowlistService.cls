public with sharing class CR_AllowlistService {

    public class CandidateObject {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public Boolean custom;
        @AuraEnabled public Boolean inAllowlist;       // effective: T1∪T2∪T3I, − T3E
        @AuraEnabled public Boolean active;
        @AuraEnabled public String category;
        @AuraEnabled public Decimal displayOrder;
        @AuraEnabled public Id allowlistRecordId;
        // Phase 1 v2 — three-tier allowlist model.
        // source: 'Template' = comes from the Apex-computed default (read-only).
        //         'Manual'   = explicit org-level addition or suppression.
        //         null       = candidate not currently in the effective allowlist.
        @AuraEnabled public String source;
        // action: 'Include' / 'Exclude' / null (when source == null).
        @AuraEnabled public String action;
    }

    public class AllowlistEntry {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String apiName;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String category;
        @AuraEnabled public Decimal displayOrder;
        @AuraEnabled public String action;  // Phase 1 v2: 'Include' | 'Exclude'
    }

    // ---- TEMPLATE-DERIVED DEFAULT ALLOWLIST (Phase 1 v2) ----
    //
    // The framework's report templates and shipped datasets declare the objects
    // the framework needs to function. Those objects are *always* allowlisted —
    // admins do not need to seed an org for the framework to work. Per-org
    // additions (Action='Include') and suppressions (Action='Exclude') happen
    // through CR_Reportable_Object__c records (Tier 3) on top of this baseline.
    //
    // SOURCE OF TRUTH WARNING: this constant must stay in sync with the
    // `templates` array in `lwc/crReportBuilder/templates.js` and the
    // `customMetadata/CR_Dataset.*.md-meta.xml` files. When a new template or
    // dataset is added, append its primary + traversed objects here. Phase 1.5
    // is to move templates to a static resource so both sides read one file.

    // T1: primary objects directly referenced as `primaryObject` in templates
    // and as `SObject_API_Name__c` in CR_Dataset__mdt records.
    @TestVisible
    private static final Set<String> TEMPLATE_PRIMARY_OBJECTS = new Set<String>{
        // Standard objects with a template / dataset pointing at them:
        'Task',
        'Case',
        'Opportunity',
        // Custom Fact tables (one template each):
        'Fact_Opportunity__c',
        'Fact_Case__c',
        'Fact_TargetCoverage__c',
        'Fact_UnzonedTarget__c',
        'Fact_VisitActivityCollateral__c',
        'Fact_VisitActivityObjection__c',
        'Fact_VisitActivityService__c',
        'Fact_ZonedLocationGap__c'
    };

    // T2: objects reachable via 1-hop relationship traversal in template field
    // paths (e.g. `Task.Account.Name` → Account; `Task.Who.FirstName` → Contact,
    // Lead via the polymorphic Who lookup).
    @TestVisible
    private static final Set<String> TEMPLATE_TRAVERSED_OBJECTS = new Set<String>{
        'Account',
        'Contact',
        'Lead',
        'User',
        'RecordType',
        'Visit_Report__c'
    };

    @TestVisible
    private static final Set<String> DEFAULT_STANDARD_OBJECTS = new Set<String>{
        // Retained for autoPopulateDefaults() backward compatibility only.
        // New default lookup goes through computeDefaultAllowlist() above.
        'Account', 'Contact', 'Lead', 'Opportunity', 'OpportunityLineItem',
        'Case', 'CaseComment', 'Campaign', 'CampaignMember',
        'User', 'Activity', 'Task', 'Event', 'OpenActivity', 'ActivityHistory',
        'Product2', 'Pricebook2', 'PricebookEntry',
        'Order', 'OrderItem', 'Asset', 'Contract',
        'Quote', 'QuoteLineItem'
    };

    /**
     * Returns the union of TEMPLATE_PRIMARY_OBJECTS and TEMPLATE_TRAVERSED_OBJECTS.
     * This is the framework's portable default allowlist — every org gets it
     * for free, no seed step required. Cf. Phase_1_v2_Architecture.md §F.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> computeDefaultAllowlist() {
        Set<String> combined = new Set<String>();
        combined.addAll(TEMPLATE_PRIMARY_OBJECTS);
        combined.addAll(TEMPLATE_TRAVERSED_OBJECTS);
        List<String> ordered = new List<String>(combined);
        ordered.sort();
        return ordered;
    }

    @TestVisible
    private static final Set<String> NOISY_SUFFIXES = new Set<String>{
        '__History', '__Share', '__ChangeEvent', '__Feed', '__Tag'
    };

    @AuraEnabled
    public static List<CandidateObject> listAllCandidates() {
        Map<String, CR_Reportable_Object__c> existing = mapAllowlistByApiName();
        // Lowercase the template defaults once so the per-iteration lookup is
        // case-insensitive. Salesforce's Schema.getGlobalDescribe().keySet()
        // returns keys in lowercase, but our constants are proper-case API
        // names — without normalization, templateDefaults.contains('task')
        // returns false for the 'Task' constant.
        Set<String> templateDefaultsLower = new Set<String>();
        for (String s : computeDefaultAllowlist()) templateDefaultsLower.add(s.toLowerCase());
        List<CandidateObject> results = new List<CandidateObject>();
        // Hoist getGlobalDescribe() out of the loop — calling it per-object is O(N^2) on
        // the org's full schema and routinely exceeds the 10s CPU limit.
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        // Hard cap to keep the loop within Apex CPU limits in large managed-package orgs.
        Integer processed = 0;
        Integer maxProcess = 5000;
        for (String apiName : globalDescribe.keySet()) {
            if (processed++ >= maxProcess) break;
            Schema.SObjectType sobj = globalDescribe.get(apiName);
            Schema.DescribeSObjectResult d = sobj.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!d.isQueryable() || !d.isAccessible()) continue;
            // d.getName() returns the canonical proper-case API name; use it
            // instead of the lowercase iteration key so downstream consumers
            // (LWC, existing-row lookups) see the case they expect.
            String canonical = d.getName();
            CandidateObject c = new CandidateObject();
            c.apiName = canonical;
            c.label = d.getLabel();
            c.custom = d.isCustom();
            CR_Reportable_Object__c existingRow = existing.get(canonical);
            if (existingRow == null) {
                // Back-compat: prior data may have stored API names in
                // lowercase. Fall back to a case-folded lookup.
                for (String k : existing.keySet()) {
                    if (k != null && k.equalsIgnoreCase(canonical)) {
                        existingRow = existing.get(k);
                        break;
                    }
                }
            }
            Boolean isTemplate = templateDefaultsLower.contains(canonical.toLowerCase());
            if (existingRow != null) {
                String act = existingRow.Action__c;
                if (String.isBlank(act)) act = 'Include'; // back-compat for rows created before Action__c
                c.action = act;
                c.active = existingRow.Is_Active__c;
                c.category = existingRow.Category__c;
                c.displayOrder = existingRow.Display_Order__c;
                c.allowlistRecordId = existingRow.Id;
                c.source = String.isBlank(existingRow.Source__c)
                    ? (isTemplate ? 'Template' : 'Manual')
                    : existingRow.Source__c;
                // Effective inAllowlist: included unless this row suppresses it.
                c.inAllowlist = (act != 'Exclude') && c.active;
            } else if (isTemplate) {
                // No row in CR_Reportable_Object__c, but it's an implicit template default.
                c.action = 'Include';
                c.active = true;
                c.category = deriveCategory(apiName);
                c.displayOrder = null;
                c.allowlistRecordId = null;
                c.source = 'Template';
                c.inAllowlist = true;
            } else {
                c.action = null;
                c.active = false;
                c.source = null;
                c.inAllowlist = false;
            }
            results.add(c);
        }
        results.sort(new CandidateComparator());
        return results;
    }

    @AuraEnabled
    public static Integer saveAllowlist(String entriesJson) {
        // Switched from List<AllowlistEntry> to a raw JSON string parameter
        // because Salesforce's wire-layer deserialization of inner-class fields
        // was inexplicably arriving with all-null values in some sandbox/runtimes.
        // Parsing the JSON ourselves avoids that path entirely.
        if (String.isBlank(entriesJson)) return 0;
        List<Object> rawList;
        try {
            Object parsed = JSON.deserializeUntyped(entriesJson);
            if (!(parsed instanceof List<Object>)) {
                throw new AuraHandledException('Allowlist payload must be a JSON array.');
            }
            rawList = (List<Object>) parsed;
        } catch (Exception ex) {
            throw new AuraHandledException('Could not parse allowlist payload: ' + ex.getMessage());
        }
        if (rawList.isEmpty()) return 0;
        List<CR_Reportable_Object__c> toUpsert = new List<CR_Reportable_Object__c>();
        Set<String> seenApiNames = new Set<String>();
        Integer skippedBlank = 0;
        Integer skippedDup = 0;
        for (Object raw : rawList) {
            if (!(raw instanceof Map<String, Object>)) {
                skippedBlank++;
                continue;
            }
            Map<String, Object> entry = (Map<String, Object>) raw;
            String apiName = entry.get('apiName') == null ? null : String.valueOf(entry.get('apiName'));
            if (String.isBlank(apiName)) {
                skippedBlank++;
                continue;
            }
            if (seenApiNames.contains(apiName)) {
                skippedDup++;
                continue;
            }
            seenApiNames.add(apiName);
            Boolean active = entry.get('active') instanceof Boolean ? (Boolean) entry.get('active') : true;
            String category = entry.get('category') == null ? null : String.valueOf(entry.get('category'));
            Object recordIdRaw = entry.get('recordId');
            Id recordId = (recordIdRaw == null || String.isBlank(String.valueOf(recordIdRaw)))
                ? null : Id.valueOf(String.valueOf(recordIdRaw));
            Object displayOrderRaw = entry.get('displayOrder');
            Decimal displayOrder = null;
            if (displayOrderRaw instanceof Decimal) displayOrder = (Decimal) displayOrderRaw;
            else if (displayOrderRaw instanceof Integer) displayOrder = Decimal.valueOf((Integer) displayOrderRaw);
            else if (displayOrderRaw instanceof Long) displayOrder = Decimal.valueOf((Long) displayOrderRaw);
            // Phase 1 v2 — read the Action picklist. Older callers that omit
            // it default to 'Include' so existing UI flows keep working.
            String action = entry.get('action') == null ? 'Include' : String.valueOf(entry.get('action'));
            if (action != 'Include' && action != 'Exclude') action = 'Include';
            CR_Reportable_Object__c r = new CR_Reportable_Object__c();
            r.SObject_API_Name__c = apiName;
            r.Name = apiName;
            r.Is_Active__c = active;
            r.Category__c = String.isBlank(category) ? deriveCategory(apiName) : category;
            r.Display_Order__c = displayOrder;
            r.Action__c = action;
            // Saves from the manager UI are always Manual; Template rows are
            // shadows of the Apex constant and never need a DB row.
            r.Source__c = 'Manual';
            if (recordId != null) r.Id = recordId;
            toUpsert.add(r);
        }
        if (toUpsert.isEmpty()) {
            String diag = 'No allowlist records were saved. Received ' + rawList.size()
                + ' entries (skipped blank: ' + skippedBlank
                + ', skipped duplicate: ' + skippedDup + ').';
            if (!rawList.isEmpty()) {
                diag += ' First raw entry: ' + JSON.serialize(rawList[0]);
            }
            throw new AuraHandledException(diag);
        }
        upsert toUpsert SObject_API_Name__c;
        return toUpsert.size();
    }

    @AuraEnabled
    public static Integer autoPopulateDefaults() {
        Map<String, CR_Reportable_Object__c> existing = mapAllowlistByApiName();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<CR_Reportable_Object__c> toInsert = new List<CR_Reportable_Object__c>();

        // Common standard objects.
        for (String apiName : DEFAULT_STANDARD_OBJECTS) {
            if (existing.containsKey(apiName)) continue;
            if (!globalDescribe.containsKey(apiName)) continue;
            Schema.DescribeSObjectResult d = globalDescribe.get(apiName).getDescribe();
            if (!d.isQueryable() || !d.isAccessible()) continue;
            CR_Reportable_Object__c r = new CR_Reportable_Object__c();
            r.SObject_API_Name__c = apiName;
            r.Name = apiName;
            r.Category__c = 'Standard';
            r.Is_Active__c = true;
            toInsert.add(r);
        }

        // All custom objects, minus noisy suffixes.
        for (String apiName : globalDescribe.keySet()) {
            if (existing.containsKey(apiName)) continue;
            Schema.DescribeSObjectResult d = globalDescribe.get(apiName).getDescribe();
            if (!d.isCustom() || !d.isQueryable() || !d.isAccessible()) continue;
            if (hasNoisySuffix(apiName)) continue;
            CR_Reportable_Object__c r = new CR_Reportable_Object__c();
            r.SObject_API_Name__c = apiName;
            r.Name = apiName;
            r.Category__c = deriveCategory(apiName);
            r.Is_Active__c = true;
            toInsert.add(r);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        return toInsert.size();
    }

    @AuraEnabled
    public static Integer clearAllowlist() {
        List<CR_Reportable_Object__c> all = [
            SELECT Id, Is_Active__c FROM CR_Reportable_Object__c WHERE Is_Active__c = true LIMIT 10000
        ];
        for (CR_Reportable_Object__c r : all) r.Is_Active__c = false;
        if (!all.isEmpty()) update all;
        return all.size();
    }

    /**
     * Phase 1 v2 — effective allowlist:
     *   (TEMPLATE_PRIMARY ∪ TEMPLATE_TRAVERSED ∪ T3 Includes) − T3 Excludes
     *
     * T3 = `CR_Reportable_Object__c` records. A row with Action__c = 'Exclude'
     * (or Is_Active__c = false) suppresses a template default. A row with
     * Action__c = 'Include' and Is_Active__c = true is a per-org addition.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getActiveAllowlist() {
        Set<String> effective = new Set<String>();
        // T1 + T2 — template-derived defaults.
        effective.addAll(computeDefaultAllowlist());
        // T3 — apply per-org overrides.
        for (CR_Reportable_Object__c r : [
            SELECT SObject_API_Name__c, Is_Active__c, Action__c
            FROM CR_Reportable_Object__c
        ]) {
            if (String.isBlank(r.SObject_API_Name__c)) continue;
            String act = String.isBlank(r.Action__c) ? 'Include' : r.Action__c;
            if (act == 'Exclude') {
                // Suppress a template default OR a previously-added manual entry.
                effective.remove(r.SObject_API_Name__c);
            } else if (r.Is_Active__c) {
                // Manual include (or activated row).
                effective.add(r.SObject_API_Name__c);
            }
        }
        List<String> ordered = new List<String>(effective);
        ordered.sort();
        return ordered;
    }

    @TestVisible
    private static Map<String, CR_Reportable_Object__c> mapAllowlistByApiName() {
        Map<String, CR_Reportable_Object__c> result = new Map<String, CR_Reportable_Object__c>();
        for (CR_Reportable_Object__c r : [
            SELECT Id, SObject_API_Name__c, Is_Active__c, Category__c, Display_Order__c,
                   Action__c, Source__c
            FROM CR_Reportable_Object__c
        ]) {
            if (!String.isBlank(r.SObject_API_Name__c)) {
                result.put(r.SObject_API_Name__c, r);
            }
        }
        return result;
    }

    @TestVisible
    private static String deriveCategory(String apiName) {
        if (String.isBlank(apiName)) return 'Other';
        if (apiName.startsWith('Fact_')) return 'Fact';
        if (apiName.startsWith('Dim_')) return 'Dimension';
        if (apiName.endsWith('__c')) return 'Custom';
        return 'Standard';
    }

    @TestVisible
    private static Boolean hasNoisySuffix(String apiName) {
        for (String suffix : NOISY_SUFFIXES) {
            if (apiName.endsWith(suffix)) return true;
        }
        return false;
    }

    private class CandidateComparator implements Comparator<CandidateObject> {
        public Integer compare(CandidateObject a, CandidateObject b) {
            // Allowlisted first, then alphabetical by label.
            if (a.inAllowlist && !b.inAllowlist) return -1;
            if (!a.inAllowlist && b.inAllowlist) return 1;
            return a.label.compareTo(b.label);
        }
    }
}