@isTest
private class CR_ReportConfigService_Test {
    @isTest
    static void enabledFlagReturnsTrue() {
        CR_ReportConfigService.testFlags = new List<CR_Report_Feature_Flag__mdt>{
            new CR_Report_Feature_Flag__mdt(Feature_Key__c = 'Default_Chart_Engine', Is_Enabled__c = true)
        };
        Test.startTest();
        System.assertEquals(true, CR_ReportConfigService.isEChartsDefault(), 'Enabled flag should resolve true');
        Test.stopTest();
    }

    @isTest
    static void disabledFlagReturnsFalse() {
        CR_ReportConfigService.testFlags = new List<CR_Report_Feature_Flag__mdt>{
            new CR_Report_Feature_Flag__mdt(Feature_Key__c = 'Default_Chart_Engine', Is_Enabled__c = false)
        };
        System.assertEquals(false, CR_ReportConfigService.isEChartsDefault(), 'Disabled flag should resolve false');
    }

    @isTest
    static void missingFlagDefaultsFalse() {
        CR_ReportConfigService.testFlags = new List<CR_Report_Feature_Flag__mdt>();
        System.assertEquals(false, CR_ReportConfigService.isEChartsDefault(), 'Missing flag should default to false');
    }
}