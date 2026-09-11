@IsTest
public class CR_TestDataFactory {
    public static Report_Definition__c createFactOpportunityReport(Boolean insertRecord) {
        String definitionJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Test_Fact_Opportunity',
                'mode' => 'fact',
                'objectApiName' => 'Fact_Opportunity__c',
                'primaryObject' => 'Fact_Opportunity__c'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Opportunity_Name__c', 'label' => 'Opportunity' },
                new Map<String, Object>{ 'path' => 'Amount__c', 'label' => 'Amount' },
                new Map<String, Object>{ 'path' => 'Stage_Name__c', 'label' => 'Stage' }
            },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>(),
            'sort' => new List<Object>{ new Map<String, Object>{ 'field' => 'Id', 'direction' => 'ASC' } },
            'pagination' => new Map<String, Object>{ 'pageSize' => 100 },
            'chart' => new Map<String, Object>{ 'type' => 'bar' },
            'drillDown' => new Map<String, Object>{ 'enabled' => true }
        });
        Report_Definition__c report = new Report_Definition__c(
            Name = 'Pipeline Report',
            Developer_Name__c = 'Pipeline_Report_Test',
            Root_Object__c = 'Fact_Opportunity__c',
            Dataset_Key__c = 'Test_Fact_Opportunity',
            Definition_JSON__c = definitionJson,
            Folder__c = 'Tests',
            Category__c = 'Unit',
            Is_Public__c = true,
            Version__c = 1
        );
        if (insertRecord) {
            insert report;
        }
        return report;
    }

    /**
     * A Standard-User-profile user holding the Custom_Reporting_Admin permission set.
     * Report/export/subscription/ETL code enforces FLS (CR_QueryEngine.validateFieldPath)
     * and custom permissions (Run_Custom_Reporting_ETL); on a freshly-installed org the
     * deploying user has neither on the new CRF fields, so tests must run those privileged
     * operations as a properly-provisioned user. Created inside runAs to avoid MIXED_DML
     * with the surrounding data DML.
     */
    public static User createReportingAdminUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'cradm',
                Email = 'cradmin@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'ReportingAdmin',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'cradmin' + rand + '@example.com.invalid'
            );
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    public static void createFactOpportunityRows() {
        insert new List<Fact_Opportunity__c>{
            new Fact_Opportunity__c(
                Name = 'FO-001',
                Source_Opportunity_Id__c = '006000000000001AAA',
                Opportunity_Name__c = 'Alpha',
                Amount__c = 100,
                Stage_Name__c = 'Prospecting',
                Close_Date__c = Date.today(),
                Fiscal_Period__c = '2026-04',
                Snapshot_Date__c = Date.today(),
                Is_Current__c = true,
                Record_Count__c = 1
            ),
            new Fact_Opportunity__c(
                Name = 'FO-002',
                Source_Opportunity_Id__c = '006000000000002AAA',
                Opportunity_Name__c = 'Beta',
                Amount__c = 250,
                Stage_Name__c = 'Closed Won',
                Close_Date__c = Date.today(),
                Fiscal_Period__c = '2026-04',
                Snapshot_Date__c = Date.today(),
                Is_Current__c = true,
                Record_Count__c = 1
            )
        };
    }
}