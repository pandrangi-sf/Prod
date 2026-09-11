@IsTest
private class CR_UserPreferenceService_Test {

    private static Dashboard__c makeDashboard() {
        Dashboard__c d = new Dashboard__c(
            Name = 'UP Test',
            Developer_Name__c = 'UP_Test_' + String.valueOf(Crypto.getRandomLong()),
            Folder__c = 'Tests',
            Category__c = 'Unit',
            Filter_JSON__c = '[]',
            Layout_JSON__c = '{"columns":12}',
            Is_Public__c = true,
            Version__c = 1
        );
        insert d;
        return d;
    }

    @IsTest
    static void empty_when_no_preference_saved_yet() {
        Dashboard__c d = makeDashboard();
        Test.startTest();
        CR_UserPreferenceService.DashboardPreference pref =
            CR_UserPreferenceService.getDashboardPreference(d.Id);
        Test.stopTest();
        System.assertEquals(null, pref.preferenceId, 'No row should exist yet');
        System.assertEquals(null, pref.filterStateJson);
    }

    @IsTest
    static void save_then_get_round_trips_filter_state() {
        Dashboard__c d = makeDashboard();
        String state = '[{"field":"Stage","operator":"=","value":"Won"}]';

        Test.startTest();
        Id prefId = CR_UserPreferenceService.saveDashboardPreference(d.Id, state);
        // Cacheable getter — must call again with a fresh transaction context to
        // bypass any platform cache. Within a single Apex test transaction this
        // is fine.
        CR_UserPreferenceService.DashboardPreference pref =
            CR_UserPreferenceService.getDashboardPreference(d.Id);
        Test.stopTest();

        System.assertEquals(prefId, pref.preferenceId);
        System.assertEquals(state, pref.filterStateJson);
    }

    @IsTest
    static void second_save_upserts_the_existing_row() {
        Dashboard__c d = makeDashboard();
        Id firstId = CR_UserPreferenceService.saveDashboardPreference(d.Id, '[]');
        Test.startTest();
        Id secondId = CR_UserPreferenceService.saveDashboardPreference(d.Id, '[{"a":1}]');
        Test.stopTest();
        System.assertEquals(firstId, secondId, 'Second save should update, not insert');
        // Confirm exactly one row exists.
        Integer rowCount = [SELECT COUNT() FROM CR_User_Preference__c WHERE Dashboard__c = :d.Id];
        System.assertEquals(1, rowCount);
    }

    @IsTest
    static void rejects_null_dashboard_id() {
        try {
            CR_UserPreferenceService.saveDashboardPreference(null, '[]');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            // expected
        }
    }

    @IsTest
    static void rejects_oversized_payload() {
        Dashboard__c d = makeDashboard();
        String big = 'x'.repeat(32001);
        try {
            CR_UserPreferenceService.saveDashboardPreference(d.Id, big);
            System.assert(false, 'Expected AuraHandledException for oversized payload');
        } catch (AuraHandledException ex) {
            // expected
        }
    }

    @IsTest
    static void lookup_key_is_15_char_user_underscore_15_char_dashboard() {
        Dashboard__c d = makeDashboard();
        String key = CR_UserPreferenceService.buildLookupKey(UserInfo.getUserId(), d.Id);
        System.assertEquals(31, key.length(), '15 + underscore + 15');
        System.assert(key.contains('_'));
    }
}