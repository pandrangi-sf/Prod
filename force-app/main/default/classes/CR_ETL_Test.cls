@IsTest
private class CR_ETL_Test {
    @IsTest
    static void opportunityBatchBuildsDimensionsAndFacts() {
        Account account = new Account(Name = 'Acme', Industry = 'Manufacturing');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'Acme Renewal',
            AccountId = account.Id,
            StageName = 'Prospecting',
            Amount = 500,
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        Test.startTest();
        Database.executeBatch(new CR_OpportunityFactBatch(Date.today()), 200);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Dim_Account__c WHERE Source_Account_Id__c = :String.valueOf(account.Id)]);
        System.assertEquals(1, [SELECT COUNT() FROM Fact_Opportunity__c WHERE Source_Opportunity_Id__c = :String.valueOf(opportunity.Id)]);
    }

    @IsTest
    static void caseBatchBuildsFacts() {
        Account account = new Account(Name = 'Support Account');
        insert account;
        Case caseRecord = new Case(AccountId = account.Id, Status = 'New', Origin = 'Phone', Priority = 'Medium');
        insert caseRecord;

        Test.startTest();
        Database.executeBatch(new CR_CaseFactBatch(Date.today()), 200);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Fact_Case__c WHERE Source_Case_Id__c = :String.valueOf(caseRecord.Id)]);
    }
}