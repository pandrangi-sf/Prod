public with sharing class CR_StandardReportImportService {
    private static final Set<String> SUPPORTED_FORMATS = new Set<String>{ 'Tabular', 'Summary', 'Matrix' };
    private static final Integer LIST_LIMIT = 200;
    private static final Integer MAX_IMPORT_BUCKETS = 25;
    private static final Integer MAX_IMPORT_BUCKET_RULES = 250;
    private static final Integer MAX_IMPORT_SUMMARY_FORMULAS = 10;
    private static final Set<String> SUPPORTED_BUCKET_TYPES = new Set<String>{ 'PICKLIST', 'TEXT', 'NUMBER' };
    private static final Set<String> SUPPORTED_BUCKET_OPERATORS = new Set<String>{
        '=', '!=', '>', '>=', '<', '<=', 'BETWEEN', 'CONTAINS'
    };

    public class StandardReportSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String format;
        @AuraEnabled public String folderName;
        @AuraEnabled public String description;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    public class ImportResult {
        @AuraEnabled public String reportName;
        @AuraEnabled public String sourceReportId;
        @AuraEnabled public String format;
        @AuraEnabled public String primaryObject;
        @AuraEnabled public String reportType;
        @AuraEnabled public String definitionJson;
        @AuraEnabled public List<String> warnings;
    }

    @AuraEnabled(cacheable=true)
    public static List<StandardReportSummary> listStandardReports(String searchTerm) {
        String term = String.isBlank(searchTerm) ? '' : searchTerm.trim();
        String likeTerm = '%' + String.escapeSingleQuotes(term) + '%';
        Set<String> formats = SUPPORTED_FORMATS;

        List<Report> reports = [
            SELECT Id, Name, Format, Description, FolderName, LastModifiedDate
            FROM Report
            WHERE Format IN :formats
              AND Name LIKE :likeTerm
            ORDER BY LastModifiedDate DESC
            LIMIT :LIST_LIMIT
        ];

        List<StandardReportSummary> results = new List<StandardReportSummary>();
        for (Report r : reports) {
            StandardReportSummary s = new StandardReportSummary();
            s.id = r.Id;
            s.name = r.Name;
            s.format = String.valueOf(r.Format);
            s.folderName = r.FolderName;
            s.description = r.Description;
            s.lastModifiedDate = r.LastModifiedDate;
            results.add(s);
        }
        return results;
    }

    @AuraEnabled
    public static ImportResult importStandardReport(Id reportId) {
        if (reportId == null) {
            throw new AuraHandledException('Report Id is required.');
        }

        Reports.ReportDescribeResult describe;
        try {
            describe = Reports.ReportManager.describeReport(reportId);
        } catch (Exception ex) {
            throw new AuraHandledException('Could not describe report: ' + ex.getMessage());
        }

        Reports.ReportMetadata meta = describe.getReportMetadata();
        if (meta == null) {
            throw new AuraHandledException('Report metadata is empty.');
        }

        String format = toTitleCaseFormat(String.valueOf(meta.getReportFormat()));
        if (!SUPPORTED_FORMATS.contains(format)) {
            throw new AuraHandledException('Unsupported report format: ' + format
                + '. Tabular, Summary, and Matrix reports only.');
        }

        // Extract primitives from the Reports.* objects so the rest of the work
        // is testable without needing a real ReportMetadata instance.
        List<String> columns = meta.getDetailColumns() == null ? new List<String>() : meta.getDetailColumns();

        List<Map<String, Object>> filterPrimitives = new List<Map<String, Object>>();
        if (meta.getReportFilters() != null) {
            for (Reports.ReportFilter f : meta.getReportFilters()) {
                filterPrimitives.add(new Map<String, Object>{
                    'column' => f.getColumn(),
                    'operator' => f.getOperator(),
                    'value' => f.getValue()
                });
            }
        }

        List<String> groupingsDown = new List<String>();
        if (meta.getGroupingsDown() != null) {
            for (Reports.GroupingInfo g : meta.getGroupingsDown()) {
                groupingsDown.add(g.getName());
            }
        }
        List<String> groupingsAcross = new List<String>();
        if (meta.getGroupingsAcross() != null) {
            for (Reports.GroupingInfo g : meta.getGroupingsAcross()) {
                groupingsAcross.add(g.getName());
            }
        }
        List<Map<String, String>> sortDescriptors = new List<Map<String, String>>();
        if (meta.getGroupingsDown() != null) {
            for (Reports.GroupingInfo g : meta.getGroupingsDown()) {
                sortDescriptors.add(new Map<String, String>{
                    'field' => g.getName(),
                    'direction' => g.getSortOrder() == Reports.ColumnSortOrder.DESCENDING ? 'DESC' : 'ASC'
                });
            }
        }

        List<String> aggregateTokens = meta.getAggregates() == null ? new List<String>() : meta.getAggregates();
        String reportTypeName = meta.getReportType() == null ? null : meta.getReportType().getType();
        String standardDateToken = meta.getStandardDateFilter() == null ? null : meta.getStandardDateFilter().getDurationValue();

        List<String> extractionWarnings = new List<String>();
        List<Map<String, Object>> customFormulas = extractCustomSummaryFormulas(meta, extractionWarnings);
        List<Map<String, Object>> bucketPrimitives = extractBucketPrimitives(meta, extractionWarnings);

        ImportResult result = buildResultFromPrimitives(
            reportId,
            meta.getName(),
            format,
            reportTypeName,
            columns,
            filterPrimitives,
            groupingsDown,
            groupingsAcross,
            sortDescriptors,
            aggregateTokens,
            meta.getReportBooleanFilter(),
            standardDateToken,
            customFormulas,
            bucketPrimitives
        );
        result.warnings.addAll(extractionWarnings);

        logImport(result);
        return result;
    }

    private static void logImport(ImportResult result) {
        try {
            String status = (result.warnings != null && !result.warnings.isEmpty())
                ? 'Imported with warnings'
                : 'Imported';
            Migration_Log__c log = new Migration_Log__c(
                Name = result.reportName == null ? 'Standard Report Import' : result.reportName,
                Source_Type__c = 'StandardReport',
                Source_Name__c = result.reportName,
                Status__c = status,
                Details_JSON__c = JSON.serialize(new Map<String, Object>{
                    'sourceReportId' => result.sourceReportId,
                    'format' => result.format,
                    'reportType' => result.reportType,
                    'primaryObject' => result.primaryObject,
                    'warnings' => result.warnings == null ? new List<String>() : result.warnings,
                    'definitionJson' => result.definitionJson
                })
            );
            insert log;
        } catch (Exception ex) {
            // Audit-logging failure must not block the import; swallow.
        }
    }

    @TestVisible
    private static ImportResult buildResultFromPrimitives(
        Id reportId,
        String reportName,
        String format,
        String reportType,
        List<String> columns,
        List<Map<String, Object>> filterPrimitives,
        List<String> groupingsDown,
        List<String> groupingsAcross,
        List<Map<String, String>> sortDescriptors,
        List<String> aggregateTokens,
        String boolFilter,
        String standardDateToken
    ) {
        return buildResultFromPrimitives(
            reportId, reportName, format, reportType, columns, filterPrimitives,
            groupingsDown, groupingsAcross, sortDescriptors, aggregateTokens,
            boolFilter, standardDateToken, new List<Map<String, Object>>()
        );
    }

    @TestVisible
    private static ImportResult buildResultFromPrimitives(
        Id reportId,
        String reportName,
        String format,
        String reportType,
        List<String> columns,
        List<Map<String, Object>> filterPrimitives,
        List<String> groupingsDown,
        List<String> groupingsAcross,
        List<Map<String, String>> sortDescriptors,
        List<String> aggregateTokens,
        String boolFilter,
        String standardDateToken,
        List<Map<String, Object>> customFormulas
    ) {
        return buildResultFromPrimitives(
            reportId, reportName, format, reportType, columns, filterPrimitives,
            groupingsDown, groupingsAcross, sortDescriptors, aggregateTokens,
            boolFilter, standardDateToken, customFormulas, new List<Map<String, Object>>()
        );
    }

    @TestVisible
    private static ImportResult buildResultFromPrimitives(
        Id reportId,
        String reportName,
        String format,
        String reportType,
        List<String> columns,
        List<Map<String, Object>> filterPrimitives,
        List<String> groupingsDown,
        List<String> groupingsAcross,
        List<Map<String, String>> sortDescriptors,
        List<String> aggregateTokens,
        String boolFilter,
        String standardDateToken,
        List<Map<String, Object>> customFormulas,
        List<Map<String, Object>> bucketPrimitives
    ) {
        ImportResult result = new ImportResult();
        result.warnings = new List<String>();
        result.reportName = reportName;
        result.sourceReportId = reportId == null ? null : String.valueOf(reportId);
        result.format = format;
        result.reportType = reportType;
        result.primaryObject = inferPrimaryObject(reportType);
        List<Object> unsupportedImports = new List<Object>();

        Boolean primaryObjectIsQueryable = result.primaryObject != null
            && Schema.getGlobalDescribe().containsKey(result.primaryObject);
        if (!primaryObjectIsQueryable) {
            result.warnings.add('This report uses Custom Report Type "' + reportType
                + '". Pick a base object on the Columns step before saving.');
            result.primaryObject = null;
        }

        Map<String, Object> dataset = new Map<String, Object>{
            'datasetKey' => primaryObjectIsQueryable ? result.primaryObject + '_Imported' : '',
            'mode' => 'live',
            'objectApiName' => primaryObjectIsQueryable ? result.primaryObject : null,
            'primaryObject' => primaryObjectIsQueryable ? result.primaryObject : null,
            'relatedObjects' => new List<Object>(),
            'fieldPaths' => new List<Object>()
        };

        List<Object> fieldDefs = new List<Object>();
        for (String column : (columns == null ? new List<String>() : columns)) {
            fieldDefs.add(new Map<String, Object>{ 'path' => column, 'label' => column });
        }

        List<Object> filters = new List<Object>();
        for (Map<String, Object> fp : (filterPrimitives == null ? new List<Map<String, Object>>() : filterPrimitives)) {
            Map<String, Object> condition = translateFilter(
                (String) fp.get('column'),
                (String) fp.get('operator'),
                fp.get('value'),
                result.warnings
            );
            if (condition != null) filters.add(condition);
        }
        if (!String.isBlank(boolFilter) && boolFilter != '1') {
            result.warnings.add('Filter logic "' + boolFilter
                + '" preserved as-is; engine supports AND/OR groups but not full boolean expressions yet.');
        }

        List<Object> groupings = new List<Object>();
        for (String name : (groupingsDown == null ? new List<String>() : groupingsDown)) {
            groupings.add(new Map<String, Object>{ 'field' => name });
        }
        for (String name : (groupingsAcross == null ? new List<String>() : groupingsAcross)) {
            groupings.add(new Map<String, Object>{ 'field' => name });
        }

        List<Object> sortClauses = new List<Object>();
        for (Map<String, String> sd : (sortDescriptors == null ? new List<Map<String, String>>() : sortDescriptors)) {
            sortClauses.add(new Map<String, Object>{
                'field' => sd.get('field'),
                'direction' => sd.get('direction')
            });
        }

        List<Object> aggregations = new List<Object>();
        for (String token : (aggregateTokens == null ? new List<String>() : aggregateTokens)) {
            Map<String, Object> agg = parseAggregateToken(token);
            if (agg != null) aggregations.add(agg);
        }

        List<Object> summaryFormulasOut = new List<Object>();
        for (Map<String, Object> f : (customFormulas == null ? new List<Map<String, Object>>() : customFormulas)) {
            if (summaryFormulasOut.size() >= MAX_IMPORT_SUMMARY_FORMULAS) {
                addUnsupportedImport(
                    unsupportedImports,
                    'summaryFormula',
                    (String) f.get('name'),
                    null,
                    'Summary formula import limit exceeded.',
                    'Review this formula on the source report and recreate it manually if needed.'
                );
                continue;
            }
            String name = (String) f.get('name');
            String expression = (String) f.get('expression');
            if (String.isBlank(name) || String.isBlank(expression)) continue;
            summaryFormulasOut.add(new Map<String, Object>{
                'name' => name,
                'label' => firstNonBlank(new List<String>{ (String) f.get('label'), name }),
                'type' => firstNonBlank(new List<String>{ (String) f.get('type'), 'number' }),
                'expression' => expression,
                'description' => f.get('description'),
                'decimalPlaces' => f.get('decimalPlaces'),
                'display' => new Map<String, Object>{
                    'downGroupType' => f.get('downGroupType'),
                    'downGroup' => f.get('downGroup'),
                    'acrossGroupType' => f.get('acrossGroupType'),
                    'acrossGroup' => f.get('acrossGroup')
                },
                'status' => 'needsReview'
            });
            result.warnings.add(
                'Custom summary formula "' + name + '" was preserved for import review. ' +
                'It is not executed in preview, viewer, or export until summary-formula runtime support is enabled.'
            );
        }
        List<Object> bucketsOut = translateBuckets(bucketPrimitives, result.warnings, unsupportedImports);

        Map<String, Object> definition = new Map<String, Object>{
            'dataset' => dataset,
            'fields' => fieldDefs,
            'filters' => filters,
            'groupings' => groupings,
            'aggregations' => aggregations,
            'formulas' => new List<Object>(),
            'summaryFormulas' => summaryFormulasOut,
            'buckets' => bucketsOut,
            'unsupportedImports' => unsupportedImports,
            'sort' => sortClauses,
            'pagination' => new Map<String, Object>{ 'pageSize' => 200, 'strategy' => 'keyset' },
            'chart' => new Map<String, Object>{ 'type' => 'bar' },
            'drillDown' => new Map<String, Object>{ 'enabled' => true },
            'sourceStandardReportId' => result.sourceReportId
        };

        if (!String.isBlank(standardDateToken)) {
            String soqlLiteral = mapStandardDateFilterToSoql(standardDateToken);
            if (soqlLiteral != null) {
                String dateField = inferDateFieldForReport(reportType);
                if (dateField != null) {
                    filters.add(new Map<String, Object>{
                        'field' => dateField,
                        'operator' => '=',
                        'value' => soqlLiteral
                    });
                } else {
                    result.warnings.add('Standard date filter "' + standardDateToken
                        + '" recognized but no obvious date field on this object. Add manually with literal "'
                        + soqlLiteral + '".');
                }
            } else {
                result.warnings.add('Standard date filter "' + standardDateToken
                    + '" is not yet translatable. Re-add it in the Filters step.');
            }
        }
        if (format == 'Matrix' && groupingsAcross != null && !groupingsAcross.isEmpty()) {
            result.warnings.add('Matrix "across" groupings are imported as additional flat groupings; add a pivot step in Visualize.');
        }

        result.definitionJson = JSON.serializePretty(definition);
        return result;
    }

    private static List<Map<String, Object>> extractCustomSummaryFormulas(
        Reports.ReportMetadata meta,
        List<String> warnings
    ) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        try {
            Map<String, Reports.ReportCsf> formulas = meta.getCustomSummaryFormula();
            if (formulas == null || formulas.isEmpty()) {
                return out;
            }
            for (String key : formulas.keySet()) {
                Reports.ReportCsf csf = formulas.get(key);
                if (csf == null) {
                    continue;
                }
                String label = csf.getLabel();
                out.add(new Map<String, Object>{
                    'name' => firstNonBlank(new List<String>{ label, key, 'Imported Summary Formula' }),
                    'label' => label,
                    'expression' => csf.getFormula(),
                    'description' => csf.getDescription(),
                    'type' => normalizeFormulaType(String.valueOf(csf.getFormulaType())),
                    'decimalPlaces' => csf.getDecimalPlaces(),
                    'downGroupType' => String.valueOf(csf.getDownGroupType()),
                    'downGroup' => csf.getDownGroup(),
                    'acrossGroupType' => String.valueOf(csf.getAcrossGroupType()),
                    'acrossGroup' => csf.getAcrossGroup()
                });
            }
        } catch (Exception ex) {
            warnings.add('Could not extract custom summary formulas: ' + ex.getMessage());
        }
        return out;
    }

    private static List<Map<String, Object>> extractBucketPrimitives(
        Reports.ReportMetadata meta,
        List<String> warnings
    ) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        try {
            List<Reports.BucketField> buckets = meta.getBuckets();
            if (buckets == null) {
                return out;
            }
            for (Reports.BucketField bucketField : buckets) {
                List<Object> values = new List<Object>();
                if (bucketField.getValues() != null) {
                    for (Reports.BucketFieldValue bucketValue : bucketField.getValues()) {
                        values.add(new Map<String, Object>{
                            'label' => bucketValue.getLabel(),
                            'rangeUpperBound' => bucketValue.getRangeUpperBound(),
                            'sourceValues' => bucketValue.getSourceDimensionValues()
                        });
                    }
                }
                out.add(new Map<String, Object>{
                    'name' => firstNonBlank(new List<String>{ bucketField.getLabel(), bucketField.getSourceColumnName() + ' Bucket' }),
                    'sourceField' => bucketField.getSourceColumnName(),
                    'bucketType' => String.valueOf(bucketField.getBucketType()),
                    'defaultValue' => firstNonBlank(new List<String>{ bucketField.getOtherBucketLabel(), 'Other' }),
                    'nullTreatedAsZero' => bucketField.getNullTreatedAsZero(),
                    'values' => values
                });
            }
        } catch (Exception ex) {
            warnings.add('Could not extract bucket fields: ' + ex.getMessage());
        }
        return out;
    }

    @TestVisible
    private static List<Object> translateBuckets(
        List<Map<String, Object>> bucketPrimitives,
        List<String> warnings,
        List<Object> unsupportedImports
    ) {
        List<Object> out = new List<Object>();
        Integer totalRules = 0;
        for (Map<String, Object> primitive : (bucketPrimitives == null ? new List<Map<String, Object>>() : bucketPrimitives)) {
            String name = firstNonBlank(new List<String>{ asString(primitive.get('name')), asString(primitive.get('label')) });
            String sourceField = firstNonBlank(new List<String>{ asString(primitive.get('sourceField')), asString(primitive.get('field')) });
            String bucketType = String.isBlank(asString(primitive.get('bucketType')))
                ? 'PICKLIST'
                : asString(primitive.get('bucketType')).toUpperCase();

            if (out.size() >= MAX_IMPORT_BUCKETS) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucket',
                    name,
                    sourceField,
                    'Bucket import limit exceeded.',
                    'Recreate this bucket manually if it is needed.'
                );
                continue;
            }
            if (String.isBlank(name) || String.isBlank(sourceField)) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucket',
                    name,
                    sourceField,
                    'Bucket is missing a name or source field.',
                    'Review the source report and recreate this bucket manually if it is needed.'
                );
                continue;
            }
            if (!SUPPORTED_BUCKET_TYPES.contains(bucketType)) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucket',
                    name,
                    sourceField,
                    'Bucket type "' + bucketType + '" is not supported by the custom bucket evaluator.',
                    'Recreate this bucket manually in Group & Summarize if it is needed.'
                );
                resultWarning(warnings, 'Bucket "' + name + '" was not converted because type "' + bucketType + '" is unsupported.');
                continue;
            }

            List<Object> rules = primitive.containsKey('rules')
                ? translateExplicitBucketRules(primitive, warnings, unsupportedImports)
                : translateReportBucketValues(primitive, warnings, unsupportedImports);
            totalRules += rules.size();
            if (totalRules > MAX_IMPORT_BUCKET_RULES) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucket',
                    name,
                    sourceField,
                    'Bucket rule import limit exceeded.',
                    'Keep the converted buckets already imported, then recreate remaining bucket rules manually.'
                );
                break;
            }
            if (rules.isEmpty()) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucket',
                    name,
                    sourceField,
                    'No supported bucket rules were available to convert.',
                    'Recreate this bucket manually in Group & Summarize if it is needed.'
                );
                continue;
            }

            out.add(new Map<String, Object>{
                'name' => name,
                'sourceField' => sourceField,
                'defaultValue' => firstNonBlank(new List<String>{ asString(primitive.get('defaultValue')), 'Other' }),
                'importedFromStandardReport' => true,
                'sourceBucketType' => bucketType,
                'rules' => rules
            });
            resultWarning(warnings, 'Bucket "' + name + '" was converted during import. Review it in Group & Summarize.');
        }
        return out;
    }

    private static List<Object> translateExplicitBucketRules(
        Map<String, Object> primitive,
        List<String> warnings,
        List<Object> unsupportedImports
    ) {
        List<Object> rules = new List<Object>();
        String bucketName = asString(primitive.get('name'));
        String sourceField = asString(primitive.get('sourceField'));
        for (Object ruleObject : asObjectList(primitive.get('rules'))) {
            Map<String, Object> rule = asMap(ruleObject);
            String operator = normalizeBucketOperator(asString(rule.get('operator')));
            String label = asString(rule.get('label'));
            if (operator == null || String.isBlank(label)) {
                addUnsupportedImport(
                    unsupportedImports,
                    'bucketRule',
                    bucketName,
                    sourceField,
                    'Unsupported or incomplete bucket rule: ' + JSON.serialize(rule),
                    'Recreate this rule manually if it is needed.'
                );
                continue;
            }
            Map<String, Object> converted = new Map<String, Object>{
                'operator' => operator,
                'value' => rule.get('value'),
                'label' => label
            };
            if (operator == 'BETWEEN') {
                converted.put('valueTo', rule.get('valueTo'));
            }
            rules.add(converted);
        }
        return rules;
    }

    private static List<Object> translateReportBucketValues(
        Map<String, Object> primitive,
        List<String> warnings,
        List<Object> unsupportedImports
    ) {
        String bucketType = String.isBlank(asString(primitive.get('bucketType')))
            ? 'PICKLIST'
            : asString(primitive.get('bucketType')).toUpperCase();
        String bucketName = asString(primitive.get('name'));
        String sourceField = asString(primitive.get('sourceField'));
        List<Object> rules = new List<Object>();
        if (bucketType == 'NUMBER') {
            Decimal previousUpper;
            for (Object valueObject : asObjectList(primitive.get('values'))) {
                Map<String, Object> valueMap = asMap(valueObject);
                String label = asString(valueMap.get('label'));
                Decimal upper = toDecimal(valueMap.get('rangeUpperBound'));
                if (String.isBlank(label) || upper == null) {
                    addUnsupportedImport(
                        unsupportedImports,
                        'bucketRule',
                        bucketName,
                        sourceField,
                        'Number bucket rule is missing a label or upper bound.',
                        'Review the source report bucket boundaries.'
                    );
                    continue;
                }
                if (previousUpper == null) {
                    rules.add(new Map<String, Object>{ 'operator' => '<=', 'value' => upper, 'label' => label });
                } else {
                    rules.add(new Map<String, Object>{
                        'operator' => 'BETWEEN',
                        'value' => previousUpper,
                        'valueTo' => upper,
                        'label' => label
                    });
                }
                previousUpper = upper;
            }
            if (!rules.isEmpty()) {
                resultWarning(warnings, 'Number bucket "' + bucketName + '" was converted with inclusive range boundaries; review exact edge values.');
            }
            return rules;
        }

        for (Object valueObject : asObjectList(primitive.get('values'))) {
            Map<String, Object> valueMap = asMap(valueObject);
            String label = asString(valueMap.get('label'));
            for (Object sourceValue : asObjectList(valueMap.get('sourceValues'))) {
                if (String.isBlank(label) || sourceValue == null) {
                    continue;
                }
                rules.add(new Map<String, Object>{
                    'operator' => '=',
                    'value' => sourceValue,
                    'label' => label
                });
            }
        }
        return rules;
    }

    private static void addUnsupportedImport(
        List<Object> unsupportedImports,
        String type,
        String sourceName,
        String sourceField,
        String reason,
        String recommendedAction
    ) {
        unsupportedImports.add(new Map<String, Object>{
            'type' => type,
            'sourceName' => sourceName,
            'sourceField' => sourceField,
            'reason' => reason,
            'recommendedAction' => recommendedAction
        });
    }

    private static String normalizeBucketOperator(String operator) {
        if (String.isBlank(operator)) {
            return null;
        }
        Map<String, String> mapping = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'lessThan' => '<',
            'greaterThan' => '>',
            'lessOrEqual' => '<=',
            'greaterOrEqual' => '>=',
            'contains' => 'CONTAINS',
            'between' => 'BETWEEN'
        };
        String normalized = mapping.containsKey(operator) ? mapping.get(operator) : operator.toUpperCase();
        return SUPPORTED_BUCKET_OPERATORS.contains(normalized) ? normalized : null;
    }

    private static String normalizeFormulaType(String formulaType) {
        if (String.isBlank(formulaType)) return 'number';
        String lower = formulaType.toLowerCase();
        if (lower.contains('percent')) return 'number';
        if (lower.contains('currency')) return 'number';
        if (lower.contains('number')) return 'number';
        if (lower.contains('text')) return 'text';
        return 'number';
    }

    private static void resultWarning(List<String> warnings, String message) {
        if (warnings != null && !warnings.contains(message)) {
            warnings.add(message);
        }
    }

    @TestVisible
    private static Map<String, Object> translateFilter(String column, String operator, Object value, List<String> warnings) {
        String normalized = normalizeOperator(operator);
        if (normalized == null) {
            warnings.add('Filter on "' + column + '" uses unsupported operator "' + operator + '" and was skipped. Re-add it manually.');
            return null;
        }
        Object outValue = wrapValueForOperator(operator, value);
        return new Map<String, Object>{
            'field' => column,
            'operator' => normalized,
            'value' => outValue
        };
    }

    @TestVisible
    private static Object wrapValueForOperator(String reportOperator, Object value) {
        if (value == null) return null;
        String stringValue = String.valueOf(value);
        if (reportOperator == 'contains') return '%' + stringValue + '%';
        if (reportOperator == 'startsWith') return stringValue + '%';
        if (reportOperator == 'endsWith') return '%' + stringValue;
        return value;
    }

    @TestVisible
    private static Map<String, Object> parseAggregateToken(String token) {
        if (String.isBlank(token)) return null;
        if ('RowCount'.equalsIgnoreCase(token) || 'COUNT'.equalsIgnoreCase(token)) {
            return new Map<String, Object>{ 'function' => 'COUNT' };
        }
        // Standard tokens look like "s!Amount" (sum), "a!Amount" (avg), "mn!Amount", "mx!Amount", "u!Amount" (unique)
        Integer bangIndex = token.indexOf('!');
        if (bangIndex <= 0) {
            return new Map<String, Object>{ 'function' => 'SUM', 'field' => token };
        }
        String prefix = token.substring(0, bangIndex);
        String column = token.substring(bangIndex + 1);
        String fn;
        if (prefix == 's') fn = 'SUM';
        else if (prefix == 'a') fn = 'AVG';
        else if (prefix == 'mn') fn = 'MIN';
        else if (prefix == 'mx') fn = 'MAX';
        else if (prefix == 'u') fn = 'COUNT'; // count distinct -> COUNT (engine doesn't support COUNT_DISTINCT yet)
        else fn = 'SUM';
        return new Map<String, Object>{ 'function' => fn, 'field' => column };
    }

    @TestVisible
    private static String mapStandardDateFilterToSoql(String durationValue) {
        if (String.isBlank(durationValue)) return null;
        String upper = durationValue.toUpperCase();
        Map<String, String> direct = new Map<String, String>{
            'TODAY' => 'TODAY',
            'YESTERDAY' => 'YESTERDAY',
            'TOMORROW' => 'TOMORROW',
            'THIS_WEEK' => 'THIS_WEEK',
            'LAST_WEEK' => 'LAST_WEEK',
            'NEXT_WEEK' => 'NEXT_WEEK',
            'THIS_MONTH' => 'THIS_MONTH',
            'LAST_MONTH' => 'LAST_MONTH',
            'NEXT_MONTH' => 'NEXT_MONTH',
            'THIS_QUARTER' => 'THIS_QUARTER',
            'LAST_QUARTER' => 'LAST_QUARTER',
            'NEXT_QUARTER' => 'NEXT_QUARTER',
            'THIS_YEAR' => 'THIS_YEAR',
            'LAST_YEAR' => 'LAST_YEAR',
            'NEXT_YEAR' => 'NEXT_YEAR',
            'CURRENT_FQ' => 'THIS_FISCAL_QUARTER',
            'LAST_FQ' => 'LAST_FISCAL_QUARTER',
            'NEXT_FQ' => 'NEXT_FISCAL_QUARTER',
            'CURRENT_FY' => 'THIS_FISCAL_YEAR',
            'LAST_FY' => 'LAST_FISCAL_YEAR',
            'NEXT_FY' => 'NEXT_FISCAL_YEAR'
        };
        if (direct.containsKey(upper)) return direct.get(upper);
        // Pattern: LAST_N_DAYS, LAST_30_DAYS, LAST_60_DAYS, LAST_90_DAYS, LAST_120_DAYS, etc.
        Matcher last = Pattern.compile('^LAST_(\\d+)_DAYS$').matcher(upper);
        if (last.matches()) return 'LAST_N_DAYS:' + last.group(1);
        Matcher next = Pattern.compile('^NEXT_(\\d+)_DAYS$').matcher(upper);
        if (next.matches()) return 'NEXT_N_DAYS:' + next.group(1);
        return null;
    }

    @TestVisible
    private static String inferDateFieldForReport(String reportType) {
        // Best-effort: pick a sensible default date field per common report types.
        if (String.isBlank(reportType)) return null;
        String lower = reportType.toLowerCase();
        if (lower.contains('opportunit')) return 'CloseDate';
        if (lower.contains('case')) return 'CreatedDate';
        if (lower.contains('account')) return 'CreatedDate';
        if (lower.contains('lead')) return 'CreatedDate';
        if (lower.contains('contact')) return 'CreatedDate';
        return null;
    }

    @TestVisible
    private static String inferPrimaryObject(String reportType) {
        if (String.isBlank(reportType)) return 'Account';
        if (Schema.getGlobalDescribe().containsKey(reportType)) return reportType;
        String lower = reportType.toLowerCase();
        if (lower.contains('opportunit')) return 'Opportunity';
        if (lower.contains('case')) return 'Case';
        if (lower.contains('account')) return 'Account';
        if (lower.contains('contact')) return 'Contact';
        if (lower.contains('lead')) return 'Lead';
        if (lower.contains('campaign')) return 'Campaign';
        if (lower.contains('user')) return 'User';
        return reportType;
    }

    @TestVisible
    private static String normalizeOperator(String operator) {
        if (String.isBlank(operator)) return '=';
        // Mapped operators have engine-supported translations.
        Map<String, String> mapping = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'lessThan' => '<',
            'greaterThan' => '>',
            'lessOrEqual' => '<=',
            'greaterOrEqual' => '>=',
            'contains' => 'LIKE',
            'startsWith' => 'LIKE',
            'endsWith' => 'LIKE',
            'includes' => 'INCLUDES',
            'excludes' => 'EXCLUDES'
        };
        // Unmapped operators (notContain, between, withinDays, withinHours, withinMinutes,
        // lastNDays, nextNDays) have no clean engine equivalent and are reported per-filter
        // by the caller via warnings. Sprint 2 introduces relative-date support.
        return mapping.containsKey(operator) ? mapping.get(operator) : null;
    }

    private static List<Object> asObjectList(Object value) {
        if (value == null) {
            return new List<Object>();
        }
        if (value instanceof List<Object>) {
            return (List<Object>) value;
        }
        List<Object> wrapped = new List<Object>();
        wrapped.add(value);
        return wrapped;
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String firstNonBlank(List<String> values) {
        for (String value : values) {
            if (!String.isBlank(value)) {
                return value;
            }
        }
        return null;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof Long) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value));
        }
        String text = String.valueOf(value);
        return String.isBlank(text) ? null : Decimal.valueOf(text);
    }

    private static String toTitleCaseFormat(String format) {
        if (String.isBlank(format)) return format;
        String lower = format.toLowerCase();
        if (lower == 'tabular') return 'Tabular';
        if (lower == 'summary') return 'Summary';
        if (lower == 'matrix') return 'Matrix';
        if (lower == 'multi_block' || lower == 'multiblock') return 'MultiBlock';
        if (lower == 'joined') return 'Joined';
        return format;
    }
}