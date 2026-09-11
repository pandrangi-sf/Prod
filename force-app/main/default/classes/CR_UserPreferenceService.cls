// Per-(User, Dashboard) UI-state persistence. The LWC writes filter selections
// here so they survive across sessions and devices; reads on mount.
//
// Why an SObject instead of a UI Action customizer or custom setting:
//   - We need per-user storage, not per-org. Custom metadata types and most
//     Custom Settings hierarchies don't scale to thousands of users with
//     thousands of distinct dashboards.
//   - SObject access lands inside the normal sharing/FLS path. Each user
//     can only read/write their own preferences.
//
// Identity model: Lookup_Key__c = '<userId15>_<dashboardId15>' is unique-
// constrained, so upsert can find the existing row in one DML without the
// caller having to query first.
public with sharing class CR_UserPreferenceService {

    public class DashboardPreference {
        @AuraEnabled public String filterStateJson { get; set; }
        @AuraEnabled public Id preferenceId { get; set; }
        @AuraEnabled public Datetime lastModified { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static DashboardPreference getDashboardPreference(Id dashboardId) {
        if (dashboardId == null) return new DashboardPreference();
        String key = buildLookupKey(UserInfo.getUserId(), dashboardId);
        // OwnerId is the platform's per-user field on every SObject; combined
        // with the unique Lookup_Key__c it gives us (user, dashboard) scoping
        // without a custom lookup that fights SF's required-lookup-to-User
        // constraints.
        List<CR_User_Preference__c> rows = [
            SELECT Id, Filter_State_JSON__c, LastModifiedDate
            FROM CR_User_Preference__c
            WHERE Lookup_Key__c = :key
              AND OwnerId = :UserInfo.getUserId()
            LIMIT 1
        ];
        DashboardPreference out = new DashboardPreference();
        if (!rows.isEmpty()) {
            out.preferenceId = rows[0].Id;
            out.filterStateJson = rows[0].Filter_State_JSON__c;
            out.lastModified = rows[0].LastModifiedDate;
        }
        return out;
    }

    @AuraEnabled
    public static Id saveDashboardPreference(Id dashboardId, String filterStateJson) {
        if (dashboardId == null) {
            throw new AuraHandledException('Dashboard id is required.');
        }
        // Field length cap defends against accidental megablob writes.
        if (filterStateJson != null && filterStateJson.length() > 32000) {
            throw new AuraHandledException('Filter state is too large to persist (max 32K).');
        }
        String key = buildLookupKey(UserInfo.getUserId(), dashboardId);
        CR_User_Preference__c row = new CR_User_Preference__c(
            Dashboard__c = dashboardId,
            Lookup_Key__c = key,
            Filter_State_JSON__c = filterStateJson,
            OwnerId = UserInfo.getUserId()
        );
        // Upsert by external id — the unique-constrained Lookup_Key__c lets the
        // platform pick INSERT vs UPDATE for us, saving a SOQL.
        upsert row Lookup_Key__c;
        return row.Id;
    }

    @TestVisible
    private static String buildLookupKey(Id userId, Id dashboardId) {
        // Pin to 15-char form so the composite key is stable regardless of
        // whether the caller passed 15 or 18 char ids.
        return String.valueOf(userId).left(15) + '_' + String.valueOf(dashboardId).left(15);
    }
}