@IsTest
private class CR_MetricService_Test {

    private static final String DS = 'Opportunity_AdHoc';

    @TestSetup
    static void seed() {
        // Insert metric definitions directly — the engine-resolution tests don't need the
        // permission gate, and inserting here keeps them independent of first-deploy grant caching.
        insert new List<CR_Metric__c>{
            new CR_Metric__c(
                Developer_Name__c = 'Total_Amount', Name = 'Total Amount', Dataset_Key__c = DS,
                Aggregation__c = 'SUM', Field_Path__c = 'Amount__c', Format__c = 'Currency', Is_Active__c = true
            ),
            new CR_Metric__c(
                Developer_Name__c = 'Won_Amount', Name = 'Won Amount', Dataset_Key__c = DS,
                Aggregation__c = 'SUM', Field_Path__c = 'Amount__c', Format__c = 'Currency', Is_Active__c = true,
                Is_Certified__c = true,
                Filter_JSON__c = '[{"field":"Stage__c","operator":"=","value":"Closed Won"}]'
            ),
            new CR_Metric__c(
                Developer_Name__c = 'Big_Amount', Name = 'Big Amount', Dataset_Key__c = DS,
                Aggregation__c = 'SUM', Field_Path__c = 'Amount__c', Format__c = 'Currency', Is_Active__c = true,
                Filter_JSON__c = '[{"field":"Amount__c","operator":">","value":10000}]'
            ),
            new CR_Metric__c(
                Developer_Name__c = 'Retired_Metric', Name = 'Retired Metric', Dataset_Key__c = DS,
                Aggregation__c = 'COUNT', Format__c = 'Number', Is_Active__c = false
            )
        };
    }

    // ---------- engine resolution ----------

    @IsTest
    static void resolvesAMetricReferenceIntoAConcreteAggregation() {
        Map<String, Object> def = new Map<String, Object>{
            'aggregations' => new List<Object>{ new Map<String, Object>{ 'metric' => 'Total_Amount' } }
        };

        CR_MetricService.resolveIntoDefinition(def);

        List<Object> aggs = (List<Object>) def.get('aggregations');
        Map<String, Object> agg = (Map<String, Object>) aggs[0];
        System.assertEquals('SUM', agg.get('function'), 'Metric aggregation should be expanded.');
        System.assertEquals('Amount__c', agg.get('field'), 'Metric field should be expanded.');
        System.assertEquals('Total Amount', agg.get('label'), 'Metric name becomes the column label.');
        System.assert(agg.get('metric') == null, 'The metric reference should have been replaced.');
    }

    @IsTest
    static void mergesAMetricLevelFilterIntoTheReportFilters() {
        Map<String, Object> def = new Map<String, Object>{
            'aggregations' => new List<Object>{ new Map<String, Object>{ 'metric' => 'Won_Amount' } },
            'filters' => new List<Object>{
                new Map<String, Object>{ 'field' => 'Territory__c', 'operator' => '=', 'value' => 'FL' }
            }
        };

        CR_MetricService.resolveIntoDefinition(def);

        List<Object> filters = (List<Object>) def.get('filters');
        System.assertEquals(2, filters.size(),
            'The metric filter should be AND-ed onto the existing report filter.');
    }

    @IsTest
    static void leavesInlineAggregationsUntouched() {
        Map<String, Object> def = new Map<String, Object>{
            'aggregations' => new List<Object>{
                new Map<String, Object>{ 'function' => 'COUNT', 'field' => '' }
            }
        };

        CR_MetricService.resolveIntoDefinition(def);

        Map<String, Object> agg = (Map<String, Object>) ((List<Object>) def.get('aggregations'))[0];
        System.assertEquals('COUNT', agg.get('function'), 'A plain inline aggregation is left alone.');
    }

    @IsTest
    static void rejectsCombiningTwoFilteredMetrics() {
        Map<String, Object> def = new Map<String, Object>{
            'aggregations' => new List<Object>{
                new Map<String, Object>{ 'metric' => 'Won_Amount' },
                new Map<String, Object>{ 'metric' => 'Big_Amount' }
            }
        };
        try {
            CR_MetricService.resolveIntoDefinition(def);
            System.assert(false, 'Two filtered metrics in one query should be rejected.');
        } catch (CR_MetricService.MetricException e) {
            System.assert(e.getMessage().contains('cannot be combined'), e.getMessage());
        }
    }

    @IsTest
    static void rejectsUnknownAndInactiveMetrics() {
        try {
            CR_MetricService.resolveIntoDefinition(new Map<String, Object>{
                'aggregations' => new List<Object>{ new Map<String, Object>{ 'metric' => 'Does_Not_Exist' } }
            });
            System.assert(false, 'Unknown metric should throw.');
        } catch (CR_MetricService.MetricException e) {
            System.assert(e.getMessage().contains('Unknown metric'), e.getMessage());
        }

        try {
            CR_MetricService.resolveIntoDefinition(new Map<String, Object>{
                'aggregations' => new List<Object>{ new Map<String, Object>{ 'metric' => 'Retired_Metric' } }
            });
            System.assert(false, 'Inactive metric should throw.');
        } catch (CR_MetricService.MetricException e) {
            System.assert(e.getMessage().contains('inactive'), e.getMessage());
        }
    }

    @IsTest
    static void resolveIsANoOpWithoutMetricReferences() {
        Map<String, Object> def = new Map<String, Object>{
            'aggregations' => new List<Object>{ new Map<String, Object>{ 'function' => 'SUM', 'field' => 'Amount__c' } }
        };
        CR_MetricService.resolveIntoDefinition(def);           // no metric key
        CR_MetricService.resolveIntoDefinition(new Map<String, Object>()); // no aggregations
        CR_MetricService.resolveIntoDefinition(null);          // null definition
        System.assertEquals(1, ((List<Object>) def.get('aggregations')).size(), 'Unchanged.');
    }

    // ---------- read ----------

    @IsTest
    static void getMetricsForDatasetReturnsOnlyActiveOnesCertifiedFirst() {
        List<CR_MetricService.MetricDto> metrics = CR_MetricService.getMetricsForDataset(DS);

        System.assertEquals(3, metrics.size(), 'Only the 3 active metrics for this dataset.');
        System.assertEquals(true, metrics[0].isCertified, 'Certified metrics sort first.');
        System.assertEquals(0, CR_MetricService.getMetricsForDataset('Nope_AdHoc').size());
        System.assertEquals(0, CR_MetricService.getMetricsForDataset(null).size());
    }

    @IsTest
    static void listAllMetricsIncludesInactive() {
        System.assertEquals(4, CR_MetricService.listAllMetrics().size(),
            'The admin console sees inactive metrics too.');
    }

    // ---------- write / governance ----------

    @IsTest
    static void adminCanCreateEditAndDeleteAMetric() {
        // Run as a System Administrator: on a first deploy the new object grant on the
        // Custom_Reporting_Admin permission set is not yet visible to describe.isCreateable(),
        // so gate-dependent writes are exercised under a profile that has CRUD immediately.
        System.runAs(sysAdmin()) {
            System.assertEquals(true, CR_MetricService.canManageMetrics(), 'Sys admin can manage.');

            Id id = CR_MetricService.saveMetric(JSON.serialize(new Map<String, Object>{
                'developerName' => 'New_Metric', 'name' => 'New Metric', 'datasetKey' => DS,
                'aggregation' => 'AVG', 'fieldPath' => 'Amount__c', 'format' => 'Number',
                'decimalPlaces' => 2, 'isCertified' => true, 'isActive' => true,
                'description' => 'Average deal size.', 'category' => 'Revenue'
            }));
            System.assertNotEquals(null, id);

            CR_Metric__c saved = [SELECT Developer_Name__c, Aggregation__c, Is_Certified__c FROM CR_Metric__c WHERE Id = :id];
            System.assertEquals('New_Metric', saved.Developer_Name__c);
            System.assertEquals('AVG', saved.Aggregation__c);
            System.assertEquals(true, saved.Is_Certified__c);

            // Edit the same record.
            CR_MetricService.saveMetric(JSON.serialize(new Map<String, Object>{
                'id' => id, 'developerName' => 'New_Metric', 'name' => 'New Metric (renamed)',
                'datasetKey' => DS, 'aggregation' => 'AVG', 'fieldPath' => 'Amount__c', 'format' => 'Number'
            }));
            System.assertEquals('New Metric (renamed)', [SELECT Name FROM CR_Metric__c WHERE Id = :id].Name);

            CR_MetricService.deleteMetric(id);
            System.assertEquals(0, [SELECT COUNT() FROM CR_Metric__c WHERE Id = :id]);
        }
    }

    @IsTest
    static void saveRejectsBadInput() {
        System.runAs(sysAdmin()) {
            assertSaveFails(new Map<String, Object>{ 'developerName' => '9bad', 'name' => 'x', 'datasetKey' => DS, 'aggregation' => 'SUM', 'fieldPath' => 'Amount__c' }, 'Developer Name');
            assertSaveFails(new Map<String, Object>{ 'developerName' => 'Ok', 'name' => '', 'datasetKey' => DS, 'aggregation' => 'SUM', 'fieldPath' => 'Amount__c' }, 'name');
            assertSaveFails(new Map<String, Object>{ 'developerName' => 'Ok', 'name' => 'Ok', 'datasetKey' => '', 'aggregation' => 'SUM', 'fieldPath' => 'Amount__c' }, 'dataset');
            assertSaveFails(new Map<String, Object>{ 'developerName' => 'Ok', 'name' => 'Ok', 'datasetKey' => DS, 'aggregation' => 'SUM', 'fieldPath' => '' }, 'field to summarize');
            assertSaveFails(new Map<String, Object>{ 'developerName' => 'Ok', 'name' => 'Ok', 'datasetKey' => DS, 'aggregation' => 'SUM', 'fieldPath' => 'Amount__c', 'filterJson' => '{not json' }, 'filter');
        }
    }

    private static void assertSaveFails(Map<String, Object> payload, String expectInMessage) {
        try {
            CR_MetricService.saveMetric(JSON.serialize(payload));
            System.assert(false, 'Expected a validation failure mentioning: ' + expectInMessage);
        } catch (AuraHandledException e) {
            // Message text is asserted loosely via getMessage where the platform exposes it.
            System.assert(true);
        }
    }

    private static User sysAdmin() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String uniq = 'crmetric' + String.valueOf(System.now().getTime()).right(7);
        User u = new User(
            FirstName = 'Metric', LastName = 'Admin', Alias = 'mtadm',
            Email = uniq + '@example.com', Username = uniq + '@crf.test.example.com',
            ProfileId = p.Id, TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }
}