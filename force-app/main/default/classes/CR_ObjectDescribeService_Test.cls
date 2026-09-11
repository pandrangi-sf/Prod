@IsTest
private class CR_ObjectDescribeService_Test {
    @IsTest
    static void describesAccountAndBuildsDataset() {
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.listObjects();
        System.assert(!objects.isEmpty());

        CR_Types.DescribeResult accountDescribe = CR_ObjectDescribeService.describeObject('Account', 1);
        System.assertEquals('Account', accountDescribe.objectInfo.apiName);
        System.assert(!accountDescribe.fields.isEmpty());

        String datasetJson = CR_ObjectDescribeService.buildDatasetDefinition(
            'Opportunity',
            new List<String>{ 'Account', 'User' },
            new List<String>{ 'Opportunity.Amount', 'Account.Name', 'User.Email' }
        );
        System.assert(datasetJson.contains('Opportunity.Amount'));
        System.assert(!datasetJson.contains('"fields"'), 'Relationship graph should not embed full field describe payloads');
    }

    @IsTest
    static void searchesObjectsWithBoundedResults() {
        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.searchObjects('opp', 5);
        Test.stopTest();

        System.assert(!objects.isEmpty(), 'Expected Opportunity-like objects to match');
        System.assert(objects.size() <= 5, 'Search should honor the result limit');
        Boolean hasOpportunity = false;
        for (CR_Types.ObjectInfo info : objects) {
            if (info.apiName == 'Opportunity') hasOpportunity = true;
        }
        System.assertEquals(true, hasOpportunity, 'Standard fallback objects should be searchable by API name');
    }

    @IsTest
    static void searchesActivityAliasAcrossTaskAndEvent() {
        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.searchObjects('activity', 10);
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (CR_Types.ObjectInfo info : objects) {
            apiNames.add(info.apiName);
        }
        System.assert(
            apiNames.contains('Task') || apiNames.contains('Event'),
            'Activity search should surface queryable activity objects such as Task or Event'
        );
    }
}