@isTest
private class CR_DashboardSprint2_Test {

    @isTest
    static void errorResultProducesEmptyShellWithErrorMessage() {
        CR_Types.QueryResult result = CR_DashboardService.errorResult('something went wrong');
        System.assertNotEquals(null, result);
        System.assertEquals('something went wrong', result.errorMessage);
        System.assertEquals(0, result.rowCount);
        System.assertNotEquals(null, result.columns);
        System.assertNotEquals(null, result.rows);
    }

    @isTest
    static void validateDashboardFiltersReturnsEmptyForNoFilters() {
        List<String> errors = CR_DashboardService.validateDashboardFilters('[]', '[]');
        System.assertEquals(0, errors.size());

        errors = CR_DashboardService.validateDashboardFilters(null, null);
        System.assertEquals(0, errors.size());

        errors = CR_DashboardService.validateDashboardFilters('   ', '   ');
        System.assertEquals(0, errors.size());
    }

    @isTest
    static void validateDashboardFiltersFlagsBadFieldOnExistingReport() {
        // Insert a report definition referencing Account so we have a real report to validate against.
        String reportDefinitionJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Id', 'label' => 'Id' },
                new Map<String, Object>{ 'path' => 'Name', 'label' => 'Name' }
            },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        Id reportId = CR_ReportDefinitionService.saveReport(
            null, 'Sprint2 Account Report', 'Account_AdHoc', reportDefinitionJson, 'Tests', 'Unit', false, null, null
        );

        // Filter referencing a field that doesn't exist on Account.
        String dashboardFilters = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'field' => 'NonExistent_Field__c',
                'operator' => '=',
                'value' => 'foo'
            }
        });
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Account Tile',
                'reportDefinitionId' => reportId,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });

        Test.startTest();
        List<String> errors = CR_DashboardService.validateDashboardFilters(dashboardFilters, componentsJson);
        Test.stopTest();

        System.assert(errors.size() >= 1, 'Expected an error for the bad filter field');
        Boolean foundReportName = false;
        for (String err : errors) {
            if (err.contains('Sprint2 Account Report')) foundReportName = true;
        }
        System.assertEquals(true, foundReportName, 'Expected the error to name the affected report');
    }

    @isTest
    static void saveDashboardThrowsWhenFilterFieldMissing() {
        String reportDefinitionJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Id' } },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        Id reportId = CR_ReportDefinitionService.saveReport(
            null, 'Sprint2 Save Reject', 'Account_AdHoc', reportDefinitionJson, 'Tests', 'Unit', false, null, null
        );

        String filterJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'field' => 'NonExistent__c', 'operator' => '=', 'value' => 'x' }
        });
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Tile',
                'reportDefinitionId' => reportId,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });

        Test.startTest();
        try {
            CR_DashboardService.saveDashboard(
                null, 'Sprint2 Reject Test', 'F', 'C', filterJson, '{"columns":12}', false, componentsJson, null
            );
            System.assert(false, 'Expected AuraHandledException for invalid filter field');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void loadDashboardWithBrokenComponentReportDoesNotThrow() {
        // Persist a dashboard with a component referencing a real report definition,
        // then update the report's Definition_JSON__c to be garbage so its load fails.
        String validJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Id' } },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        Id reportId = CR_ReportDefinitionService.saveReport(
            null, 'Sprint2 Broken', 'Account_AdHoc', validJson, 'Tests', 'Unit', false, null, null
        );
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Broken Tile',
                'reportDefinitionId' => reportId,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint2 Broken Dash', 'F', 'C', '[]', '{"columns":12}', false, componentsJson, null
        );

        // Now corrupt the saved report definition so runReportById will throw.
        Report_Definition__c corrupt = [SELECT Id, Definition_JSON__c FROM Report_Definition__c WHERE Id = :reportId];
        corrupt.Definition_JSON__c = 'not valid json';
        update corrupt;

        Test.startTest();
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, true);
        Test.stopTest();

        System.assertEquals(1, payload.components.size());
        Id componentId = payload.components[0].Id;
        CR_Types.QueryResult result = payload.componentResults.get(componentId);
        System.assertNotEquals(null, result, 'Expected a placeholder result for the broken component');
        System.assertNotEquals(null, result.errorMessage, 'Expected errorMessage to be populated');
        System.assert(result.errorMessage.contains('Broken Tile'), 'Expected error to name the component');
    }

    @isTest
    static void loadDashboardDeduplicatesIdenticalReportComponents() {
        String validJson = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Account_AdHoc',
                'mode' => 'live',
                'objectApiName' => 'Account',
                'primaryObject' => 'Account'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Id' } },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        Id reportId = CR_ReportDefinitionService.saveReport(
            null, 'Sprint2 Dedup', 'Account_AdHoc', validJson, 'Tests', 'Unit', false, null, null
        );
        // Two components reference the same report.
        String componentsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'name' => 'Tile A',
                'reportDefinitionId' => reportId,
                'visualization' => new Map<String, Object>{ 'type' => 'table' },
                'x' => 0, 'y' => 0, 'w' => 6, 'h' => 3
            },
            new Map<String, Object>{
                'name' => 'Tile B',
                'reportDefinitionId' => reportId,
                'visualization' => new Map<String, Object>{ 'type' => 'bar' },
                'x' => 6, 'y' => 0, 'w' => 6, 'h' => 3
            }
        });
        Id dashboardId = CR_DashboardService.saveDashboard(
            null, 'Sprint2 Dedup Dash', 'F', 'C', '[]', '{"columns":12}', false, componentsJson, null
        );

        Test.startTest();
        CR_DashboardService.DashboardPayload payload = CR_DashboardService.loadDashboard(dashboardId, true);
        Test.stopTest();

        // Both components received a result (dedup gives same instance — both are non-null).
        System.assertEquals(2, payload.componentResults.size());
        for (Id componentId : payload.componentResults.keySet()) {
            System.assertNotEquals(null, payload.componentResults.get(componentId));
        }
    }
}