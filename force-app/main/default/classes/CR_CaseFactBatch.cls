public with sharing class CR_CaseFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    private Date snapshotDate;
    private Datetime sinceDate;

    public CR_CaseFactBatch() {
        this(Date.today());
    }

    public CR_CaseFactBatch(Date snapshotDate) {
        this(snapshotDate, null);
    }

    public CR_CaseFactBatch(Date snapshotDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, CaseNumber, Status, Priority, CreatedDate, AccountId, Account.Name, Account.Industry,
                    Account.Type, Account.BillingCountry, OwnerId, LastModifiedDate
                FROM Case
                WHERE LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, CaseNumber, Status, Priority, CreatedDate, AccountId, Account.Name, Account.Industry,
                Account.Type, Account.BillingCountry, OwnerId, LastModifiedDate
            FROM Case
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Map<String, Dim_Account__c> accountsBySourceId = new Map<String, Dim_Account__c>();
        Set<Id> ownerIds = new Set<Id>();
        for (SObject row : scope) {
            Case caseRecord = (Case) row;
            if (caseRecord.AccountId != null) {
                accountsBySourceId.put(String.valueOf(caseRecord.AccountId), new Dim_Account__c(
                    Name = caseRecord.Account == null ? String.valueOf(caseRecord.AccountId) : caseRecord.Account.Name,
                    Source_Account_Id__c = String.valueOf(caseRecord.AccountId),
                    Account_Name__c = caseRecord.Account == null ? null : caseRecord.Account.Name,
                    Industry__c = caseRecord.Account == null ? null : caseRecord.Account.Industry,
                    Type__c = caseRecord.Account == null ? null : caseRecord.Account.Type,
                    Billing_Country__c = caseRecord.Account == null ? null : caseRecord.Account.BillingCountry,
                    Is_Current__c = true,
                    Last_Source_Modified__c = caseRecord.LastModifiedDate
                ));
            }
            if (caseRecord.OwnerId != null && String.valueOf(caseRecord.OwnerId).startsWith('005')) {
                ownerIds.add(caseRecord.OwnerId);
            }
        }

        if (!accountsBySourceId.isEmpty()) {
            Database.upsert(accountsBySourceId.values(), Dim_Account__c.Fields.Source_Account_Id__c, false);
        }
        Map<Id, User> usersById = ownerIds.isEmpty()
            ? new Map<Id, User>()
            : new Map<Id, User>([SELECT Id, Name, Email, Profile.Name, IsActive FROM User WHERE Id IN :ownerIds]);
        Map<String, Dim_User__c> usersBySourceId = new Map<String, Dim_User__c>();
        for (User userRecord : usersById.values()) {
            usersBySourceId.put(String.valueOf(userRecord.Id), new Dim_User__c(
                Name = userRecord.Name,
                Source_User_Id__c = String.valueOf(userRecord.Id),
                User_Name__c = userRecord.Name,
                Email__c = userRecord.Email,
                Profile_Name__c = userRecord.Profile == null ? null : userRecord.Profile.Name,
                Is_Active__c = userRecord.IsActive
            ));
        }
        if (!usersBySourceId.isEmpty()) {
            Database.upsert(usersBySourceId.values(), Dim_User__c.Fields.Source_User_Id__c, false);
        }

        Map<String, Dim_Account__c> persistedAccounts = new Map<String, Dim_Account__c>();
        for (Dim_Account__c accountDimension : [
            SELECT Id, Source_Account_Id__c
            FROM Dim_Account__c
            WHERE Source_Account_Id__c IN :accountsBySourceId.keySet()
        ]) {
            persistedAccounts.put(accountDimension.Source_Account_Id__c, accountDimension);
        }
        Map<String, Dim_User__c> persistedUsers = new Map<String, Dim_User__c>();
        for (Dim_User__c userDimension : [
            SELECT Id, Source_User_Id__c
            FROM Dim_User__c
            WHERE Source_User_Id__c IN :usersBySourceId.keySet()
        ]) {
            persistedUsers.put(userDimension.Source_User_Id__c, userDimension);
        }

        List<Fact_Case__c> facts = new List<Fact_Case__c>();
        for (SObject row : scope) {
            Case caseRecord = (Case) row;
            Fact_Case__c fact = new Fact_Case__c();
            fact.Name = 'FC-' + String.valueOf(caseRecord.Id);
            fact.Source_Case_Id__c = String.valueOf(caseRecord.Id);
            fact.Case_Number__c = caseRecord.CaseNumber;
            fact.Status__c = caseRecord.Status;
            fact.Priority__c = caseRecord.Priority;
            fact.Created_Date__c = caseRecord.CreatedDate;
            fact.Age_Days__c = caseRecord.CreatedDate == null ? null : caseRecord.CreatedDate.date().daysBetween(Date.today());
            fact.Snapshot_Date__c = snapshotDate;
            fact.Is_Current__c = true;
            fact.Record_Count__c = 1;
            if (caseRecord.AccountId != null && persistedAccounts.containsKey(String.valueOf(caseRecord.AccountId))) {
                fact.Dim_Account__c = persistedAccounts.get(String.valueOf(caseRecord.AccountId)).Id;
            }
            if (caseRecord.OwnerId != null && persistedUsers.containsKey(String.valueOf(caseRecord.OwnerId))) {
                fact.Dim_Owner__c = persistedUsers.get(String.valueOf(caseRecord.OwnerId)).Id;
            }
            facts.add(fact);
        }
        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_Case__c.Fields.Source_Case_Id__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
    }
}