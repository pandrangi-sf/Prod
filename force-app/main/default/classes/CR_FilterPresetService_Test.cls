@isTest
private class CR_FilterPresetService_Test {

    @isTest
    static void getActivePresets_returnsValidShape() {
        Test.startTest();
        List<CR_FilterPresetService.FilterPreset> presets = CR_FilterPresetService.getActivePresets();
        Test.stopTest();

        System.assertNotEquals(null, presets, 'service must return a non-null list');
        for (CR_FilterPresetService.FilterPreset p : presets) {
            System.assertNotEquals(null, p.key, 'every preset needs a developer-name key');
            System.assertNotEquals(null, p.label, 'every preset needs a master label');
            System.assertNotEquals(null, p.filterJson, 'filter JSON is required on the field');
        }
    }
}