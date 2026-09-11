@IsTest
private class CR_DatasetCatalogService_Test {

    @IsTest
    static void returns_peek_for_known_dataset() {
        // Discover an existing CR_Dataset__mdt record from the org's seed
        // metadata rather than hard-coding a developer name. The seed set
        // varies between dev sandboxes, qa, and prod; the test only cares
        // that getInstance() round-trips correctly for *some* record.
        Map<String, CR_Dataset__mdt> all = CR_Dataset__mdt.getAll();
        System.assert(!all.isEmpty(), 'Org has no CR_Dataset__mdt records seeded; cannot exercise happy path');
        String anyKey = new List<String>(all.keySet())[0];
        CR_Dataset__mdt seed = all.get(anyKey);

        Test.startTest();
        CR_DatasetCatalogService.DatasetPeek peek =
            CR_DatasetCatalogService.getDatasetPeek(anyKey);
        Test.stopTest();

        System.assertEquals(anyKey, peek.datasetKey);
        System.assertEquals(seed.SObject_API_Name__c, peek.sobjectApiName);
        System.assertEquals(seed.Mode__c, peek.mode);
        // accessible + rowCount + lastRefreshAt are best-effort; assert only
        // that a label came back when the object resolved.
        if (peek.accessible == true) {
            System.assertNotEquals(null, peek.objectLabel);
        }
    }

    @IsTest
    static void throws_for_unknown_dataset() {
        try {
            CR_DatasetCatalogService.getDatasetPeek('No_Such_Dataset');
            System.assert(false, 'Expected AuraHandledException for unknown dataset');
        } catch (AuraHandledException ex) {
            // expected
        }
    }

    @IsTest
    static void throws_for_blank_key() {
        try {
            CR_DatasetCatalogService.getDatasetPeek('');
            System.assert(false, 'Expected AuraHandledException for blank key');
        } catch (AuraHandledException ex) {
            // expected
        }
    }
}