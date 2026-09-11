public with sharing class CR_FilterPresetService {

    public class FilterPreset {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String filterJson { get; set; }
    }

    // Returns active filter presets ordered by Display_Order then label. Each
    // record's Filter_JSON__c is passed through verbatim so the LWC can decide
    // which keys to honor — keeps the contract loose so new preset properties
    // can be added without an Apex change.
    @AuraEnabled(cacheable=true)
    public static List<FilterPreset> getActivePresets() {
        List<FilterPreset> result = new List<FilterPreset>();
        for (CR_Filter_Preset__mdt p : [
            SELECT DeveloperName, MasterLabel, Description__c, Filter_JSON__c, Display_Order__c
            FROM CR_Filter_Preset__mdt
            WHERE Is_Active__c = true
            ORDER BY Display_Order__c NULLS LAST, MasterLabel
        ]) {
            FilterPreset fp = new FilterPreset();
            fp.key = p.DeveloperName;
            fp.label = p.MasterLabel;
            fp.description = p.Description__c;
            fp.filterJson = p.Filter_JSON__c;
            result.add(fp);
        }
        return result;
    }
}