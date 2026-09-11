/**
 * Lightweight, cacheable reader for CR_Report_Feature_Flag__mdt toggles that
 * the LWC layer needs at render time. Kept separate from the heavier services
 * so a flag lookup is a single cached round-trip.
 *
 * First consumer: Default_Chart_Engine — when enabled, the report and
 * dashboard viewers default chart rendering to Apache ECharts instead of
 * Chart.js. Default OFF, so deploying this is a no-op until an admin flips the
 * flag (revertible without a redeploy).
 */
public with sharing class CR_ReportConfigService {
    // Injection seam for tests — custom metadata records can't be inserted via
    // DML, so the test sets this to exercise enabled / disabled / missing.
    @TestVisible
    private static List<CR_Report_Feature_Flag__mdt> testFlags = null;

    @AuraEnabled(cacheable=true)
    public static Boolean isEChartsDefault() {
        return isEnabled('Default_Chart_Engine');
    }

    private static Boolean isEnabled(String featureKey) {
        List<CR_Report_Feature_Flag__mdt> flags = testFlags != null
            ? testFlags
            : [
                SELECT Is_Enabled__c
                FROM CR_Report_Feature_Flag__mdt
                WHERE Feature_Key__c = :featureKey
                LIMIT 1
            ];
        for (CR_Report_Feature_Flag__mdt flag : flags) {
            return flag.Is_Enabled__c == true;
        }
        // No record for this key → feature off.
        return false;
    }
}