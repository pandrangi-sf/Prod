public with sharing class CR_OpportunityFactBatch implements Database.Batchable<SObject>, Database.Stateful {
    private Date snapshotDate;
    // Optional watermark: when non-null, start() filters to records modified
    // since the cutoff. Default callers (nightly ETL) leave this null for a
    // full refresh; incremental jobs pass a recent cutoff.
    private Datetime sinceDate;

    public CR_OpportunityFactBatch() {
        this(Date.today());
    }

    public CR_OpportunityFactBatch(Date snapshotDate) {
        this(snapshotDate, null);
    }

    public CR_OpportunityFactBatch(Date snapshotDate, Datetime sinceDate) {
        this.snapshotDate = snapshotDate == null ? Date.today() : snapshotDate;
        this.sinceDate = sinceDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime cutoff = sinceDate;
        if (cutoff != null) {
            return Database.getQueryLocator([
                SELECT Id, Name, Amount, StageName, CloseDate, AccountId, Account.Name, Account.Industry,
                    Account.Type, Account.BillingCountry, OwnerId, LastModifiedDate
                FROM Opportunity
                WHERE LastModifiedDate >= :cutoff
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, Amount, StageName, CloseDate, AccountId, Account.Name, Account.Industry,
                Account.Type, Account.BillingCountry, OwnerId, LastModifiedDate
            FROM Opportunity
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Map<String, Dim_Account__c> accountsBySourceId = new Map<String, Dim_Account__c>();
        Set<Id> ownerIds = new Set<Id>();
        for (SObject row : scope) {
            Opportunity opportunity = (Opportunity) row;
            if (opportunity.AccountId != null) {
                accountsBySourceId.put(String.valueOf(opportunity.AccountId), new Dim_Account__c(
                    Name = opportunity.Account == null ? String.valueOf(opportunity.AccountId) : opportunity.Account.Name,
                    Source_Account_Id__c = String.valueOf(opportunity.AccountId),
                    Account_Name__c = opportunity.Account == null ? null : opportunity.Account.Name,
                    Industry__c = opportunity.Account == null ? null : opportunity.Account.Industry,
                    Type__c = opportunity.Account == null ? null : opportunity.Account.Type,
                    Billing_Country__c = opportunity.Account == null ? null : opportunity.Account.BillingCountry,
                    Is_Current__c = true,
                    Last_Source_Modified__c = opportunity.LastModifiedDate
                ));
            }
            if (opportunity.OwnerId != null && String.valueOf(opportunity.OwnerId).startsWith('005')) {
                ownerIds.add(opportunity.OwnerId);
            }
        }

        if (!accountsBySourceId.isEmpty()) {
            Database.upsert(accountsBySourceId.values(), Dim_Account__c.Fields.Source_Account_Id__c, false);
        }
        Map<Id, User> usersById = new Map<Id, User>();
        if (!ownerIds.isEmpty()) {
            usersById = new Map<Id, User>([
                SELECT Id, Name, Email, Profile.Name, IsActive
                FROM User
                WHERE Id IN :ownerIds
            ]);
        }
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

        List<Fact_Opportunity__c> facts = new List<Fact_Opportunity__c>();
        for (SObject row : scope) {
            Opportunity opportunity = (Opportunity) row;
            Fact_Opportunity__c fact = new Fact_Opportunity__c();
            fact.Name = 'FO-' + String.valueOf(opportunity.Id);
            fact.Source_Opportunity_Id__c = String.valueOf(opportunity.Id);
            fact.Opportunity_Name__c = opportunity.Name;
            fact.Amount__c = opportunity.Amount;
            fact.Stage_Name__c = opportunity.StageName;
            fact.Close_Date__c = opportunity.CloseDate;
            fact.Fiscal_Period__c = opportunity.CloseDate == null
                ? null
                : String.valueOf(opportunity.CloseDate.year()) + '-' + String.valueOf(opportunity.CloseDate.month()).leftPad(2, '0');
            fact.Snapshot_Date__c = snapshotDate;
            fact.Is_Current__c = true;
            fact.Record_Count__c = 1;
            if (opportunity.AccountId != null && persistedAccounts.containsKey(String.valueOf(opportunity.AccountId))) {
                fact.Dim_Account__c = persistedAccounts.get(String.valueOf(opportunity.AccountId)).Id;
            }
            if (opportunity.OwnerId != null && persistedUsers.containsKey(String.valueOf(opportunity.OwnerId))) {
                fact.Dim_Owner__c = persistedUsers.get(String.valueOf(opportunity.OwnerId)).Id;
            }
            facts.add(fact);
        }
        if (!facts.isEmpty()) {
            Database.upsert(facts, Fact_Opportunity__c.Fields.Source_Opportunity_Id__c, false);
        }
    }

    public void finish(Database.BatchableContext context) {
    }
}