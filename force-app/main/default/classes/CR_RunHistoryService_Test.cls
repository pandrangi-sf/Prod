@IsTest
private class CR_RunHistoryService_Test {

    @IsTest
    static void logRun_inserts_success_row() {
        Report_Definition__c def = new Report_Definition__c(
            Name = 'Slow Test Report',
            Developer_Name__c = 'slow_test_report_' + String.valueOf(Crypto.getRandomLong()),
            Dataset_Key__c = 'Account',
            Definition_JSON__c = '{}'
        );
        insert def;

        Test.startTest();
        CR_RunHistoryService.logRun(def.Id, System.now(), 1234, 42, false, null);
        Test.stopTest();

        List<Report_Run__c> rows = [
            SELECT Id, Status__c, Duration_Ms__c, Row_Count__c, Aggregate_Result__c, Error_Message__c
            FROM Report_Run__c WHERE Report_Definition__c = :def.Id
        ];
        System.assertEquals(1, rows.size(), 'Expected one run row');
        System.assertEquals('Success', rows[0].Status__c);
        System.assertEquals(1234, rows[0].Duration_Ms__c);
        System.assertEquals(42, rows[0].Row_Count__c);
        System.assertEquals(false, rows[0].Aggregate_Result__c);
        System.assert(String.isBlank(rows[0].Error_Message__c));
    }

    @IsTest
    static void logRun_marks_failure_and_truncates_long_messages() {
        Report_Definition__c def = new Report_Definition__c(
            Name = 'Failing Report',
            Developer_Name__c = 'failing_report_' + String.valueOf(Crypto.getRandomLong()),
            Dataset_Key__c = 'Account',
            Definition_JSON__c = '{}'
        );
        insert def;

        // Construct a message longer than the truncation threshold.
        String longMessage = 'x'.repeat(1500);

        Test.startTest();
        CR_RunHistoryService.logRun(def.Id, System.now(), 10, 0, true, longMessage);
        Test.stopTest();

        Report_Run__c row = [
            SELECT Status__c, Aggregate_Result__c, Error_Message__c
            FROM Report_Run__c WHERE Report_Definition__c = :def.Id LIMIT 1
        ];
        System.assertEquals('Failed', row.Status__c);
        System.assertEquals(true, row.Aggregate_Result__c);
        System.assert(row.Error_Message__c.endsWith('…'), 'Long error should be truncated with ellipsis');
        System.assert(row.Error_Message__c.length() <= 1000, 'Error message should fit field length');
    }

    @IsTest
    static void getSlowReports_returns_top_n_by_avg_duration() {
        Report_Definition__c fast = new Report_Definition__c(
            Name = 'Fast', Developer_Name__c = 'fast_' + Crypto.getRandomLong(),
            Dataset_Key__c = 'Account', Definition_JSON__c = '{}'
        );
        Report_Definition__c slow = new Report_Definition__c(
            Name = 'Slow', Developer_Name__c = 'slow_' + Crypto.getRandomLong(),
            Dataset_Key__c = 'Account', Definition_JSON__c = '{}'
        );
        insert new List<Report_Definition__c>{ fast, slow };

        // Three runs each — slow's avg duration is intentionally an order of
        // magnitude higher so ordering is unambiguous.
        List<Report_Run__c> runs = new List<Report_Run__c>();
        for (Integer i = 0; i < 3; i++) {
            runs.add(new Report_Run__c(
                Report_Definition__c = fast.Id, Run_At__c = System.now(),
                Duration_Ms__c = 50, Row_Count__c = 5, Status__c = 'Success'
            ));
            runs.add(new Report_Run__c(
                Report_Definition__c = slow.Id, Run_At__c = System.now(),
                Duration_Ms__c = 2500, Row_Count__c = 5, Status__c = 'Success'
            ));
        }
        insert runs;

        Test.startTest();
        List<CR_RunHistoryService.SlowReport> top = CR_RunHistoryService.getSlowReports(7, 5);
        Test.stopTest();

        System.assertEquals(2, top.size(), 'Two distinct reports should surface');
        System.assertEquals(slow.Id, top[0].reportDefinitionId, 'Slow report should be first');
        System.assertEquals('Slow', top[0].reportName);
        System.assertEquals(3, top[0].runCount);
        System.assert(top[0].avgDurationMs > top[1].avgDurationMs);
    }

    @IsTest
    static void getSlowReports_returns_empty_when_no_data() {
        Test.startTest();
        List<CR_RunHistoryService.SlowReport> top = CR_RunHistoryService.getSlowReports(null, null);
        Test.stopTest();
        System.assert(top.isEmpty());
    }
}