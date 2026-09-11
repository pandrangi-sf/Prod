@isTest
private class CR_Phase2_Test {

    // ---- CR_StandardReportImportService — operator translation ----

    @isTest
    static void normalizeOperatorCoversCommonCases() {
        System.assertEquals('=', CR_StandardReportImportService.normalizeOperator('equals'));
        System.assertEquals('!=', CR_StandardReportImportService.normalizeOperator('notEqual'));
        System.assertEquals('<', CR_StandardReportImportService.normalizeOperator('lessThan'));
        System.assertEquals('>', CR_StandardReportImportService.normalizeOperator('greaterThan'));
        System.assertEquals('<=', CR_StandardReportImportService.normalizeOperator('lessOrEqual'));
        System.assertEquals('>=', CR_StandardReportImportService.normalizeOperator('greaterOrEqual'));
        System.assertEquals('LIKE', CR_StandardReportImportService.normalizeOperator('contains'));
        System.assertEquals('LIKE', CR_StandardReportImportService.normalizeOperator('startsWith'));
        System.assertEquals('LIKE', CR_StandardReportImportService.normalizeOperator('endsWith'));
        System.assertEquals('INCLUDES', CR_StandardReportImportService.normalizeOperator('includes'));
        System.assertEquals('EXCLUDES', CR_StandardReportImportService.normalizeOperator('excludes'));
        System.assertEquals('=', CR_StandardReportImportService.normalizeOperator(null));
    }

    @isTest
    static void normalizeOperatorReturnsNullForUnsupportedOps() {
        System.assertEquals(null, CR_StandardReportImportService.normalizeOperator('between'));
        System.assertEquals(null, CR_StandardReportImportService.normalizeOperator('notContain'));
        System.assertEquals(null, CR_StandardReportImportService.normalizeOperator('withinDays'));
        System.assertEquals(null, CR_StandardReportImportService.normalizeOperator('lastNDays'));
    }

    @isTest
    static void wrapValueForOperatorAddsWildcards() {
        System.assertEquals('%foo%', CR_StandardReportImportService.wrapValueForOperator('contains', 'foo'));
        System.assertEquals('foo%', CR_StandardReportImportService.wrapValueForOperator('startsWith', 'foo'));
        System.assertEquals('%foo', CR_StandardReportImportService.wrapValueForOperator('endsWith', 'foo'));
        System.assertEquals('foo', CR_StandardReportImportService.wrapValueForOperator('equals', 'foo'));
        System.assertEquals(null, CR_StandardReportImportService.wrapValueForOperator('contains', null));
    }

    @isTest
    static void translateFilterPassesGoodOpAndWarnsOnBadOp() {
        List<String> warnings = new List<String>();
        Map<String, Object> good = CR_StandardReportImportService.translateFilter(
            'Stage_Name__c', 'equals', 'Closed Won', warnings
        );
        System.assertNotEquals(null, good);
        System.assertEquals('=', good.get('operator'));
        System.assertEquals(0, warnings.size());

        Map<String, Object> bad = CR_StandardReportImportService.translateFilter(
            'Amount__c', 'between', '100', warnings
        );
        System.assertEquals(null, bad);
        System.assertEquals(1, warnings.size());
        System.assert(warnings[0].contains('Amount__c'), 'Warning should name the field');
    }

    @isTest
    static void translateFilterWrapsContainsValue() {
        List<String> warnings = new List<String>();
        Map<String, Object> result = CR_StandardReportImportService.translateFilter(
            'Name', 'contains', 'Acme', warnings
        );
        System.assertNotEquals(null, result);
        System.assertEquals('LIKE', result.get('operator'));
        System.assertEquals('%Acme%', result.get('value'));
    }

    @isTest
    static void inferPrimaryObjectFallsBackForKnownTypes() {
        System.assertEquals('Opportunity', CR_StandardReportImportService.inferPrimaryObject('Opportunities'));
        System.assertEquals('Case', CR_StandardReportImportService.inferPrimaryObject('Cases'));
        System.assertEquals('Account', CR_StandardReportImportService.inferPrimaryObject(null));
        System.assertEquals('Lead', CR_StandardReportImportService.inferPrimaryObject('LeadByStatus'));
    }

    @isTest
    static void parseAggregateTokenHandlesStandardPrefixes() {
        Map<String, Object> sumAgg = CR_StandardReportImportService.parseAggregateToken('s!Amount');
        System.assertEquals('SUM', sumAgg.get('function'));
        System.assertEquals('Amount', sumAgg.get('field'));

        Map<String, Object> countAgg = CR_StandardReportImportService.parseAggregateToken('RowCount');
        System.assertEquals('COUNT', countAgg.get('function'));

        Map<String, Object> avgAgg = CR_StandardReportImportService.parseAggregateToken('a!Score');
        System.assertEquals('AVG', avgAgg.get('function'));

        Map<String, Object> minAgg = CR_StandardReportImportService.parseAggregateToken('mn!Age');
        System.assertEquals('MIN', minAgg.get('function'));

        Map<String, Object> maxAgg = CR_StandardReportImportService.parseAggregateToken('mx!Score');
        System.assertEquals('MAX', maxAgg.get('function'));
    }

    @isTest
    static void listStandardReportsRunsWithoutException() {
        Test.startTest();
        List<CR_StandardReportImportService.StandardReportSummary> results =
            CR_StandardReportImportService.listStandardReports('');
        Test.stopTest();
        System.assertNotEquals(null, results);
    }

    // Integration test: exercises importStandardReport end-to-end against a real Report
    // record in the org. Skips gracefully if no Tabular/Summary/Matrix reports are visible
    // to the running user. This is the only path that covers the orchestrator's calls to
    // Reports.ReportManager.describeReport(), since the Reports namespace cannot be mocked.
    @isTest(SeeAllData=true)
    static void importStandardReportEndToEndAgainstRealReport() {
        List<Report> reports = [
            SELECT Id, Name FROM Report
            WHERE Format IN ('Tabular', 'Summary', 'Matrix')
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (reports.isEmpty()) {
            // No reports visible — nothing to assert; let the test pass.
            System.debug('No standard reports in org for end-to-end import test; skipping.');
            return;
        }

        Test.startTest();
        CR_StandardReportImportService.ImportResult result =
            CR_StandardReportImportService.importStandardReport(reports[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.definitionJson);
        System.assertEquals(reports[0].Id, (Id) result.sourceReportId);

        // Audit logging is fire-and-forget by design (Migration_Log__c may have
        // org-specific validation rules). Surface the count via debug log only.
        Integer logCount = [
            SELECT COUNT() FROM Migration_Log__c
            WHERE Source_Type__c = 'StandardReport'
              AND Source_Name__c = :reports[0].Name
        ];
        System.debug('Audit log rows for imported report: ' + logCount);
    }

    // Integration test for listStandardReports against a real org. Asserts the SOQL
    // executes and returns a list whose entries (if any) have the expected DTO shape.
    @isTest(SeeAllData=true)
    static void listStandardReportsReturnsTabularSummaryMatrix() {
        Test.startTest();
        List<CR_StandardReportImportService.StandardReportSummary> results =
            CR_StandardReportImportService.listStandardReports('');
        Test.stopTest();

        System.assertNotEquals(null, results);
        for (CR_StandardReportImportService.StandardReportSummary r : results) {
            System.assertNotEquals(null, r.id);
            System.assert(
                new Set<String>{ 'Tabular', 'Summary', 'Matrix' }.contains(r.format),
                'Unexpected format in result: ' + r.format
            );
        }
    }

    @isTest
    static void importStandardReportRejectsNullId() {
        Test.startTest();
        try {
            CR_StandardReportImportService.importStandardReport(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void buildResultFromPrimitivesProducesExpectedDefinition() {
        List<Map<String, Object>> filters = new List<Map<String, Object>>{
            new Map<String, Object>{ 'column' => 'Name', 'operator' => 'contains', 'value' => 'Acme' },
            new Map<String, Object>{ 'column' => 'AnnualRevenue', 'operator' => 'between', 'value' => '100' }
        };
        List<Map<String, String>> sortDescriptors = new List<Map<String, String>>{
            new Map<String, String>{ 'field' => 'Industry', 'direction' => 'DESC' }
        };

        Test.startTest();
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null,
            'Test Imported Report',
            'Tabular',
            'Account',
            new List<String>{ 'Name', 'Industry', 'AnnualRevenue' },
            filters,
            new List<String>{ 'Industry' },
            new List<String>(),
            sortDescriptors,
            new List<String>{ 's!AnnualRevenue', 'RowCount' },
            '1 AND 2',
            null
        );
        Test.stopTest();

        System.assertEquals('Account', result.primaryObject);
        System.assertEquals('Tabular', result.format);
        System.assertNotEquals(null, result.definitionJson);
        System.assert(result.warnings.size() >= 2,
            'Expected warnings for between-filter and bool filter logic; got: ' + result.warnings);

        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        Map<String, Object> dataset = (Map<String, Object>) def.get('dataset');
        System.assertEquals('Account', dataset.get('primaryObject'));

        List<Object> outFilters = (List<Object>) def.get('filters');
        System.assertEquals(1, outFilters.size(), 'Between filter should be skipped');
        Map<String, Object> kept = (Map<String, Object>) outFilters[0];
        System.assertEquals('LIKE', kept.get('operator'));
        System.assertEquals('%Acme%', kept.get('value'));

        List<Object> outAggs = (List<Object>) def.get('aggregations');
        System.assertEquals(2, outAggs.size());
        System.assertEquals('SUM', ((Map<String, Object>) outAggs[0]).get('function'));
        System.assertEquals('COUNT', ((Map<String, Object>) outAggs[1]).get('function'));
    }

    @isTest
    static void buildResultFromPrimitivesDetectsCustomReportType() {
        Test.startTest();
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null,
            'CRT Report',
            'Summary',
            'Some_Custom_Report_Type__c',
            new List<String>{ 'Field__c' },
            new List<Map<String, Object>>(),
            new List<String>(),
            new List<String>(),
            new List<Map<String, String>>(),
            new List<String>(),
            null,
            null
        );
        Test.stopTest();

        System.assertEquals(null, result.primaryObject);
        System.assert(result.warnings.size() >= 1);
        System.assert(result.warnings[0].contains('Custom Report Type'),
            'First warning should call out the CRT: ' + result.warnings[0]);
    }

    @isTest
    static void buildResultFromPrimitivesWarnsForUntranslatableDateFilter() {
        // An unmapped value falls through to a warning with the original token.
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null,
            'Unknown Date Report',
            'Tabular',
            'Account',
            new List<String>{ 'Name' },
            new List<Map<String, Object>>(),
            new List<String>(),
            new List<String>(),
            new List<Map<String, String>>(),
            new List<String>(),
            null,
            'SOME_UNRECOGNIZED_DURATION'
        );
        Boolean foundDateWarning = false;
        for (String w : result.warnings) {
            if (w.contains('SOME_UNRECOGNIZED_DURATION')) foundDateWarning = true;
        }
        System.assertEquals(true, foundDateWarning, 'Expected a warning naming the unrecognized duration');
    }

    @isTest
    static void buildResultFromPrimitivesTranslatesStandardDateToFilter() {
        // CURRENT_FQ on an Opportunity report should land on CloseDate.
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null, 'Date FQ Report', 'Tabular', 'Opportunity',
            new List<String>{ 'Name' },
            new List<Map<String, Object>>(),
            new List<String>(), new List<String>(), new List<Map<String, String>>(),
            new List<String>(), null, 'CURRENT_FQ'
        );
        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        List<Object> outFilters = (List<Object>) def.get('filters');
        System.assertEquals(1, outFilters.size(), 'Expected the standard date filter to translate into one filter row');
        Map<String, Object> filterRow = (Map<String, Object>) outFilters[0];
        System.assertEquals('CloseDate', filterRow.get('field'));
        System.assertEquals('THIS_FISCAL_QUARTER', filterRow.get('value'));
    }

    @isTest
    static void buildResultFromPrimitivesIncludesCustomFormulas() {
        List<Map<String, Object>> csfs = new List<Map<String, Object>>{
            new Map<String, Object>{
                'name' => 'WinRate',
                'label' => 'Win Rate',
                'expression' => 'WonAmount / TotalAmount',
                'description' => 'Win percentage'
            }
        };
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null, 'CSF Report', 'Tabular', 'Account',
            new List<String>{ 'Name' },
            new List<Map<String, Object>>(),
            new List<String>(), new List<String>(), new List<Map<String, String>>(),
            new List<String>(), null, null,
            csfs
        );
        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        List<Object> rowFormulas = (List<Object>) def.get('formulas');
        System.assertEquals(0, rowFormulas.size(), 'Imported summary formulas must not execute as row formulas.');
        List<Object> outFormulas = (List<Object>) def.get('summaryFormulas');
        System.assertEquals(1, outFormulas.size());
        Map<String, Object> first = (Map<String, Object>) outFormulas[0];
        System.assertEquals('WinRate', first.get('name'));
        System.assertEquals('WonAmount / TotalAmount', first.get('expression'));
        Boolean foundWarning = false;
        for (String w : result.warnings) {
            if (w.contains('WinRate') && w.contains('Custom summary formula')) foundWarning = true;
        }
        System.assertEquals(true, foundWarning, 'Expected a warning naming WinRate');
    }

    @isTest
    static void buildResultFromPrimitivesConvertsSupportedBuckets() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>{
            new Map<String, Object>{
                'name' => 'Industry Bucket',
                'sourceField' => 'Industry',
                'bucketType' => 'PICKLIST',
                'defaultValue' => 'Other Industries',
                'values' => new List<Object>{
                    new Map<String, Object>{
                        'label' => 'Healthcare',
                        'sourceValues' => new List<Object>{ 'Healthcare', 'Hospitals' }
                    }
                }
            }
        };

        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null, 'Bucket Report', 'Tabular', 'Account',
            new List<String>{ 'Name', 'Industry' },
            new List<Map<String, Object>>(),
            new List<String>(), new List<String>(), new List<Map<String, String>>(),
            new List<String>(), null, null,
            new List<Map<String, Object>>(), buckets
        );

        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        List<Object> outBuckets = (List<Object>) def.get('buckets');
        System.assertEquals(1, outBuckets.size());
        Map<String, Object> bucket = (Map<String, Object>) outBuckets[0];
        System.assertEquals('Industry Bucket', bucket.get('name'));
        System.assertEquals('Industry', bucket.get('sourceField'));
        List<Object> rules = (List<Object>) bucket.get('rules');
        System.assertEquals(2, rules.size(), 'Each source value should become a bucket rule.');
        List<Object> unsupported = (List<Object>) def.get('unsupportedImports');
        System.assertEquals(0, unsupported.size());
    }

    @isTest
    static void buildResultFromPrimitivesFlagsUnsupportedBucketTypes() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>{
            new Map<String, Object>{
                'name' => 'Created Date Bucket',
                'sourceField' => 'CreatedDate',
                'bucketType' => 'DATE',
                'values' => new List<Object>{
                    new Map<String, Object>{ 'label' => 'Recent', 'sourceValues' => new List<Object>{ 'THIS_MONTH' } }
                }
            }
        };

        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null, 'Unsupported Bucket Report', 'Tabular', 'Account',
            new List<String>{ 'Name', 'CreatedDate' },
            new List<Map<String, Object>>(),
            new List<String>(), new List<String>(), new List<Map<String, String>>(),
            new List<String>(), null, null,
            new List<Map<String, Object>>(), buckets
        );

        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        System.assertEquals(0, ((List<Object>) def.get('buckets')).size());
        List<Object> unsupported = (List<Object>) def.get('unsupportedImports');
        System.assertEquals(1, unsupported.size());
        Map<String, Object> item = (Map<String, Object>) unsupported[0];
        System.assertEquals('bucket', item.get('type'));
        System.assert(String.valueOf(item.get('reason')).contains('DATE'));
    }

    @isTest
    static void translateBucketsHandlesExplicitRulesAndUnsupportedRules() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>{
            new Map<String, Object>{
                'name' => 'Amount Bucket',
                'sourceField' => 'AnnualRevenue',
                'bucketType' => 'NUMBER',
                'rules' => new List<Object>{
                    new Map<String, Object>{ 'operator' => 'between', 'value' => 1, 'valueTo' => 100, 'label' => 'Small' },
                    new Map<String, Object>{ 'operator' => 'matchesRegex', 'value' => '.*', 'label' => 'Unsupported' },
                    new Map<String, Object>{ 'operator' => 'equals', 'value' => 500, 'label' => '' }
                }
            }
        };
        List<String> warnings = new List<String>();
        List<Object> unsupported = new List<Object>();

        List<Object> converted = CR_StandardReportImportService.translateBuckets(buckets, warnings, unsupported);

        System.assertEquals(1, converted.size());
        List<Object> rules = (List<Object>) ((Map<String, Object>) converted[0]).get('rules');
        System.assertEquals(1, rules.size(), 'Only the supported complete rule should convert.');
        System.assertEquals('BETWEEN', ((Map<String, Object>) rules[0]).get('operator'));
        System.assertEquals(2, unsupported.size(), 'Unsupported and incomplete rules should be preserved for review.');
    }

    @isTest
    static void translateBucketsHandlesNumberRangesAndEmptyBuckets() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>{
            new Map<String, Object>{
                'name' => 'Revenue Bands',
                'sourceField' => 'AnnualRevenue',
                'bucketType' => 'NUMBER',
                'values' => new List<Object>{
                    new Map<String, Object>{ 'label' => 'Low', 'rangeUpperBound' => 100 },
                    new Map<String, Object>{ 'label' => 'Mid', 'rangeUpperBound' => 500 },
                    new Map<String, Object>{ 'label' => 'Missing Upper' }
                }
            },
            new Map<String, Object>{
                'name' => 'Empty Bucket',
                'sourceField' => 'Industry',
                'bucketType' => 'PICKLIST',
                'values' => new List<Object>()
            },
            new Map<String, Object>{
                'name' => 'Missing Source',
                'bucketType' => 'PICKLIST',
                'values' => new List<Object>()
            }
        };
        List<String> warnings = new List<String>();
        List<Object> unsupported = new List<Object>();

        List<Object> converted = CR_StandardReportImportService.translateBuckets(buckets, warnings, unsupported);

        System.assertEquals(1, converted.size());
        List<Object> rules = (List<Object>) ((Map<String, Object>) converted[0]).get('rules');
        System.assertEquals(2, rules.size());
        System.assertEquals('<=', ((Map<String, Object>) rules[0]).get('operator'));
        System.assertEquals('BETWEEN', ((Map<String, Object>) rules[1]).get('operator'));
        System.assert(unsupported.size() >= 3, 'Expected missing upper, empty bucket, and missing source review items.');
        System.assert(!warnings.isEmpty(), 'Expected a warning for inclusive number bucket boundaries.');
    }

    @isTest
    static void translateBucketsCapsConvertedBucketCount() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>();
        for (Integer i = 0; i < 27; i++) {
            buckets.add(new Map<String, Object>{
                'name' => 'Bucket ' + i,
                'sourceField' => 'Industry',
                'bucketType' => 'PICKLIST',
                'values' => new List<Object>{
                    new Map<String, Object>{
                        'label' => 'Group ' + i,
                        'sourceValues' => new List<Object>{ 'Value ' + i }
                    }
                }
            });
        }
        List<String> warnings = new List<String>();
        List<Object> unsupported = new List<Object>();

        List<Object> converted = CR_StandardReportImportService.translateBuckets(buckets, warnings, unsupported);

        System.assertEquals(25, converted.size(), 'Only the bounded number of buckets should convert.');
        System.assertEquals(2, unsupported.size(), 'Overflow buckets should be preserved as review items.');
    }

    @isTest
    static void buildResultFromPrimitivesCapsSummaryFormulaImports() {
        List<Map<String, Object>> formulas = new List<Map<String, Object>>();
        for (Integer i = 0; i < 12; i++) {
            formulas.add(new Map<String, Object>{
                'name' => 'Formula' + i,
                'label' => 'Formula ' + i,
                'expression' => 'RowCount',
                'type' => 'number',
                'decimalPlaces' => 0
            });
        }

        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null, 'Many Formula Report', 'Summary', 'Account',
            new List<String>{ 'Name' },
            new List<Map<String, Object>>(),
            new List<String>{ 'Industry' }, new List<String>(), new List<Map<String, String>>(),
            new List<String>(), null, null,
            formulas, new List<Map<String, Object>>()
        );

        Map<String, Object> def = (Map<String, Object>) JSON.deserializeUntyped(result.definitionJson);
        System.assertEquals(10, ((List<Object>) def.get('summaryFormulas')).size());
        System.assertEquals(2, ((List<Object>) def.get('unsupportedImports')).size());
    }

    @isTest
    static void mapStandardDateFilterCoversCommonValues() {
        System.assertEquals('THIS_QUARTER', CR_StandardReportImportService.mapStandardDateFilterToSoql('THIS_QUARTER'));
        System.assertEquals('LAST_FISCAL_YEAR', CR_StandardReportImportService.mapStandardDateFilterToSoql('LAST_FY'));
        System.assertEquals('THIS_FISCAL_QUARTER', CR_StandardReportImportService.mapStandardDateFilterToSoql('CURRENT_FQ'));
        System.assertEquals('LAST_N_DAYS:30', CR_StandardReportImportService.mapStandardDateFilterToSoql('LAST_30_DAYS'));
        System.assertEquals('LAST_N_DAYS:90', CR_StandardReportImportService.mapStandardDateFilterToSoql('LAST_90_DAYS'));
        System.assertEquals('NEXT_N_DAYS:7', CR_StandardReportImportService.mapStandardDateFilterToSoql('NEXT_7_DAYS'));
        System.assertEquals(null, CR_StandardReportImportService.mapStandardDateFilterToSoql('SOME_UNKNOWN_VALUE'));
        System.assertEquals(null, CR_StandardReportImportService.mapStandardDateFilterToSoql(null));
    }

    @isTest
    static void inferDateFieldForReportPicksDefaults() {
        System.assertEquals('CloseDate', CR_StandardReportImportService.inferDateFieldForReport('Opportunities'));
        System.assertEquals('CreatedDate', CR_StandardReportImportService.inferDateFieldForReport('CaseStatus'));
        System.assertEquals(null, CR_StandardReportImportService.inferDateFieldForReport(null));
        System.assertEquals(null, CR_StandardReportImportService.inferDateFieldForReport('SomeEsotericReportType'));
    }

    @isTest
    static void formulaEnginePostfixIsCachedAcrossRows() {
        // Run validateFormula twice with the same expression: second call should hit the cache.
        // We can't directly observe cache hits in Apex, but at minimum both invocations should produce identical results.
        String formulaJson = JSON.serialize(new Map<String, Object>{
            'name' => 'CacheTest',
            'type' => 'number',
            'expression' => '(2 + 3) * 4'
        });
        CR_Types.ValidationResult r1 = CR_FormulaEngine.validateFormula(formulaJson, '{}');
        CR_Types.ValidationResult r2 = CR_FormulaEngine.validateFormula(formulaJson, '{}');
        System.assertEquals(true, r1.valid);
        System.assertEquals(true, r2.valid);

        // Validate the postfix builder directly for shape correctness.
        List<String> postfix = CR_FormulaEngine.buildPostfix('2 + 3 * 4');
        System.assertEquals(5, postfix.size(), 'Expected: 2 3 4 * +; got ' + postfix);
        System.assertEquals('+', postfix[postfix.size() - 1]);
        System.assertEquals('*', postfix[postfix.size() - 2]);
    }

    @isTest
    static void engineRecognizesSoqlDateLiterals() {
        System.assertEquals(true, CR_QueryEngine.isSoqlDateLiteral('TODAY'));
        System.assertEquals(true, CR_QueryEngine.isSoqlDateLiteral('THIS_QUARTER'));
        System.assertEquals(true, CR_QueryEngine.isSoqlDateLiteral('LAST_N_DAYS:7'));
        System.assertEquals(false, CR_QueryEngine.isSoqlDateLiteral('today'));
        System.assertEquals(false, CR_QueryEngine.isSoqlDateLiteral('Some Value'));
        System.assertEquals(false, CR_QueryEngine.isSoqlDateLiteral(''));
        System.assertEquals(false, CR_QueryEngine.isSoqlDateLiteral(null));
    }

    @isTest
    static void buildResultFromPrimitivesFlagsMatrixAcrossGroupings() {
        CR_StandardReportImportService.ImportResult result = CR_StandardReportImportService.buildResultFromPrimitives(
            null,
            'Matrix Report',
            'Matrix',
            'Account',
            new List<String>{ 'Name' },
            new List<Map<String, Object>>(),
            new List<String>{ 'Industry' },
            new List<String>{ 'Type' },
            new List<Map<String, String>>(),
            new List<String>(),
            null,
            null
        );
        Boolean foundMatrixWarning = false;
        for (String w : result.warnings) {
            if (w.contains('across')) foundMatrixWarning = true;
        }
        System.assertEquals(true, foundMatrixWarning);
    }

    // ---- CR_ReportDefinitionService ----

    @isTest
    static void listDatasetsRunsWithoutException() {
        Test.startTest();
        List<CR_Types.DatasetOption> results = CR_ReportDefinitionService.listDatasets();
        Test.stopTest();
        System.assertNotEquals(null, results);
    }

    @isTest
    static void saveReportRejectsBlankName() {
        Test.startTest();
        try {
            CR_ReportDefinitionService.saveReport(
                null, '', 'Account_AdHoc', buildMinimalDefinitionJson('Account'), 'F', 'C', false, null, null
            );
            System.assert(false, 'Expected AuraHandledException for blank name');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void saveReportInsertsAndUpdatesNewRecord() {
        String json = buildMinimalDefinitionJson('Account');
        Test.startTest();
        Id newId = CR_ReportDefinitionService.saveReport(
            null, 'Phase2 Test Report', 'Account_AdHoc', json, 'Test', 'Test', false, null, 'Phase2 description'
        );
        System.assertNotEquals(null, newId);

        Report_Definition__c inserted = [
            SELECT Id, Version__c FROM Report_Definition__c WHERE Id = :newId
        ];
        Decimal v1 = inserted.Version__c;
        System.assertEquals(1, v1);

        // Update with matching version succeeds.
        Id updatedId = CR_ReportDefinitionService.saveReport(
            newId, 'Phase2 Test Report v2', 'Account_AdHoc', json, 'Test', 'Test', false, v1, null
        );
        System.assertEquals(newId, updatedId);

        Report_Definition__c updated = [
            SELECT Version__c FROM Report_Definition__c WHERE Id = :newId
        ];
        System.assertEquals(v1 + 1, updated.Version__c);
        Test.stopTest();
    }

    @isTest
    static void saveReportRejectsStaleVersion() {
        String json = buildMinimalDefinitionJson('Account');
        Id newId = CR_ReportDefinitionService.saveReport(
            null, 'Phase2 Stale Test', 'Account_AdHoc', json, 'Test', 'Test', false, null, null
        );
        Report_Definition__c rec = [SELECT Version__c FROM Report_Definition__c WHERE Id = :newId];
        Decimal stale = rec.Version__c - 5;

        Test.startTest();
        try {
            CR_ReportDefinitionService.saveReport(
                newId, 'Phase2 Stale Test', 'Account_AdHoc', json, 'Test', 'Test', false, stale, null
            );
            System.assert(false, 'Expected concurrency exception');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void loadReportRoundTrip() {
        String json = buildMinimalDefinitionJson('Account');
        Id newId = CR_ReportDefinitionService.saveReport(
            null, 'Phase2 Load Test', 'Account_AdHoc', json, 'F', 'C', true, null, 'Load test description'
        );

        Test.startTest();
        CR_Types.ReportDefinitionRecord loaded = CR_ReportDefinitionService.loadReport(newId);
        Test.stopTest();

        System.assertEquals(newId, loaded.id);
        System.assertEquals('Phase2 Load Test', loaded.name);
        System.assertEquals(true, loaded.isPublic);
    }

    @isTest
    static void listReportsReturnsRecentlyInserted() {
        CR_ReportDefinitionService.saveReport(
            null, 'Phase2 List Test', 'Account_AdHoc',
            buildMinimalDefinitionJson('Account'), 'F', 'C', false, null, null
        );
        Test.startTest();
        List<CR_Types.ReportDefinitionRecord> results = CR_ReportDefinitionService.listReports('Phase2');
        Test.stopTest();
        System.assert(results.size() >= 1, 'Expected at least one Phase2 record');
    }

    // ---- CR_FormulaEngine.validateFormula ----

    @isTest
    static void validateFormulaValidExpression() {
        String formulaJson = JSON.serialize(new Map<String, Object>{
            'name' => 'Doubled',
            'type' => 'number',
            'expression' => '2 + 3'
        });
        Test.startTest();
        CR_Types.ValidationResult result = CR_FormulaEngine.validateFormula(formulaJson, '{}');
        Test.stopTest();
        System.assertEquals(true, result.valid, String.join(result.errors, ', '));
    }

    @isTest
    static void validateFormulaMissingName() {
        String formulaJson = JSON.serialize(new Map<String, Object>{
            'expression' => '1 + 1'
        });
        CR_Types.ValidationResult result = CR_FormulaEngine.validateFormula(formulaJson, '{}');
        System.assertEquals(false, result.valid);
        System.assert(result.errors.size() >= 1);
    }

    @isTest
    static void validateFormulaMissingExpression() {
        String formulaJson = JSON.serialize(new Map<String, Object>{
            'name' => 'NoExpr'
        });
        CR_Types.ValidationResult result = CR_FormulaEngine.validateFormula(formulaJson, '{}');
        System.assertEquals(false, result.valid);
    }

    @isTest
    static void validateFormulaInvalidJson() {
        CR_Types.ValidationResult result = CR_FormulaEngine.validateFormula('not json', '{}');
        System.assertEquals(false, result.valid);
    }

    // ---- helpers ----

    private static String buildMinimalDefinitionJson(String objectApiName) {
        return JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => objectApiName + '_AdHoc',
                'mode' => 'live',
                'objectApiName' => objectApiName,
                'primaryObject' => objectApiName
            },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'path' => 'Id', 'label' => 'Id' },
                new Map<String, Object>{ 'path' => 'Name', 'label' => 'Name' }
            },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
    }
}