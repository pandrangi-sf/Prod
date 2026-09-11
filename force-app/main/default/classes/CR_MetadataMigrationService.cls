public with sharing class CR_MetadataMigrationService {
    // Not cacheable: parses arbitrary user-supplied XML. Caching by (name, xml)
    // would mean repeated edits of the same draft never re-parse.
    @AuraEnabled
    public static CR_Types.MigrationPreview previewReportXml(String reportName, String reportXml) {
        if (String.isBlank(reportXml)) {
            throw new AuraHandledException('Report XML is required.');
        }
        Dom.Document document = new Dom.Document();
        document.load(reportXml);
        Dom.XmlNode root = document.getRootElement();

        CR_Types.MigrationPreview preview = new CR_Types.MigrationPreview();
        preview.sourceName = reportName;
        preview.sourceType = 'Report';
        preview.unsupportedFeatures = new List<String>();
        preview.requiredEtlChanges = new List<String>();

        List<String> columns = parseColumns(root);
        if (!childTextValues(root, 'blocks').isEmpty()) {
            preview.sourceType = 'JoinedReport';
            preview.unsupportedFeatures.add('Joined reports are migrated as dashboard components, one block per dataset.');
        }
        if (!children(root, 'crossFilters').isEmpty()) {
            preview.unsupportedFeatures.add('Cross filters require manual review and are logged during migration.');
        }

        String reportType = firstChildText(root, 'reportType');
        String primaryObject = inferPrimaryObject(reportType);
        Map<String, Object> dataset = new Map<String, Object>{
            'datasetKey' => primaryObject + '_Migrated',
            'mode' => 'hybrid',
            'primaryObject' => primaryObject,
            'relatedObjects' => new List<Object>(),
            'fieldPaths' => columns
        };
        Map<String, Object> report = new Map<String, Object>{
            'dataset' => dataset,
            'fields' => columns,
            'filters' => parseFilters(root),
            'groupings' => parseGroupings(root),
            'aggregations' => inferAggregations(columns),
            'sort' => new List<Object>(),
            'pagination' => new Map<String, Object>{ 'pageSize' => 200 },
            'chart' => parseChart(root),
            'drillDown' => new Map<String, Object>{ 'enabled' => true }
        };

        preview.datasetDefinitionJson = JSON.serializePretty(dataset);
        preview.reportDefinitionJson = JSON.serializePretty(report);
        if (preview.unsupportedFeatures.isEmpty()) {
            preview.unsupportedFeatures.add('None detected in XML preview.');
        }
        return preview;
    }

    @AuraEnabled
    public static Id migrateReportXml(String reportName, String folder, String reportXml) {
        CR_Types.MigrationPreview preview = previewReportXml(reportName, reportXml);
        Id reportDefinitionId = CR_ReportDefinitionService.saveReport(
            null,
            reportName,
            (String) ((Map<String, Object>) JSON.deserializeUntyped(preview.datasetDefinitionJson)).get('datasetKey'),
            preview.reportDefinitionJson,
            folder,
            'Migrated',
            false,
            null,
            'Migrated from ' + preview.sourceType
        );
        Migration_Log__c log = new Migration_Log__c(
            Name = reportName,
            Source_Type__c = preview.sourceType,
            Source_Name__c = reportName,
            Status__c = preview.unsupportedFeatures.contains('None detected in XML preview.') ? 'Migrated' : 'Unsupported',
            Report_Definition__c = reportDefinitionId,
            Details_JSON__c = JSON.serializePretty(preview)
        );
        insert log;
        return reportDefinitionId;
    }

    // Real Salesforce Report metadata wraps columns as
    //   <columns><field>OPPORTUNITY.NAME</field></columns>
    // The original implementation treated <columns> as a text node (the shape
    // of an earlier internal draft) which produced empty fields against real
    // SF exports. We now prefer the <field> child, then fall back to direct
    // text so legacy pastes that did work keep working.
    private static List<String> parseColumns(Dom.XmlNode root) {
        List<String> fields = new List<String>();
        for (Dom.XmlNode colNode : children(root, 'columns')) {
            String field = firstChildText(colNode, 'field');
            if (String.isBlank(field)) {
                field = colNode.getText();
            }
            if (String.isNotBlank(field)) {
                fields.add(field.trim());
            }
        }
        return fields;
    }

    // Real Salesforce Report metadata nests filter rows under <criteriaItems>:
    //   <filter><criteriaItems><column/><operator/><value/></criteriaItems>…</filter>
    // The original code looked for <column> directly under <filter> (the flat
    // legacy shape) which collapsed multi-criteria reports to a single filter.
    // Prefer <criteriaItems> when present and fall back to the legacy shape.
    private static List<Object> parseFilters(Dom.XmlNode root) {
        List<Object> filters = new List<Object>();
        List<Dom.XmlNode> criteriaItems = children(root, 'criteriaItems');
        if (!criteriaItems.isEmpty()) {
            for (Dom.XmlNode ci : criteriaItems) {
                String field = firstChildText(ci, 'column');
                if (String.isBlank(field)) continue;
                filters.add(new Map<String, Object>{
                    'field' => field,
                    'operator' => normalizeOperator(firstChildText(ci, 'operator')),
                    'value' => firstChildText(ci, 'value')
                });
            }
            return filters;
        }
        for (Dom.XmlNode filterNode : children(root, 'filter')) {
            String field = firstChildText(filterNode, 'column');
            if (String.isBlank(field)) continue;
            filters.add(new Map<String, Object>{
                'field' => field,
                'operator' => normalizeOperator(firstChildText(filterNode, 'operator')),
                'value' => firstChildText(filterNode, 'value')
            });
        }
        return filters;
    }

    // Real Salesforce Report metadata wraps each grouping as
    //   <groupingsDown><field>X</field><dateGranularity>None</dateGranularity>…</groupingsDown>
    // The original code took the wrapper's text and ended up with empty strings.
    private static List<Object> parseGroupings(Dom.XmlNode root) {
        List<Object> groupings = new List<Object>();
        for (Dom.XmlNode g : children(root, 'groupingsDown')) {
            String field = extractGroupingField(g);
            if (String.isNotBlank(field)) {
                groupings.add(new Map<String, Object>{ 'field' => field, 'axis' => 'down' });
            }
        }
        for (Dom.XmlNode g : children(root, 'groupingsAcross')) {
            String field = extractGroupingField(g);
            if (String.isNotBlank(field)) {
                groupings.add(new Map<String, Object>{ 'field' => field, 'axis' => 'across' });
            }
        }
        return groupings;
    }

    private static String extractGroupingField(Dom.XmlNode g) {
        String field = firstChildText(g, 'field');
        if (String.isBlank(field)) {
            field = g.getText();
        }
        return String.isBlank(field) ? null : field.trim();
    }

    private static List<Object> inferAggregations(List<String> columns) {
        List<Object> aggregations = new List<Object>();
        for (String column : columns) {
            if (column != null && (column.endsWith('.Amount') || column.endsWith('Amount') || column.contains('Revenue'))) {
                aggregations.add(new Map<String, Object>{ 'field' => column, 'function' => 'SUM' });
            }
        }
        if (aggregations.isEmpty()) {
            aggregations.add(new Map<String, Object>{ 'field' => 'Id', 'function' => 'COUNT' });
        }
        return aggregations;
    }

    private static Map<String, Object> parseChart(Dom.XmlNode root) {
        String chartType = firstChildText(root, 'chartType');
        return new Map<String, Object>{
            'type' => String.isBlank(chartType) ? 'bar' : chartType.toLowerCase(),
            'x' => null,
            'y' => null
        };
    }

    private static String inferPrimaryObject(String reportType) {
        if (String.isBlank(reportType)) return 'Report';
        String lower = reportType.toLowerCase();
        if (lower.contains('opportunit')) return 'Opportunity';
        if (lower.contains('case')) return 'Case';
        if (lower.contains('account')) return 'Account';
        if (lower.contains('lead')) return 'Lead';
        return reportType;
    }

    private static String normalizeOperator(String operator) {
        if (String.isBlank(operator)) return '=';
        Map<String, String> operators = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'greaterThan' => '>',
            'greaterOrEqual' => '>=',
            'lessThan' => '<',
            'lessOrEqual' => '<=',
            'contains' => 'LIKE'
        };
        return operators.containsKey(operator) ? operators.get(operator) : operator;
    }

    private static List<String> childTextValues(Dom.XmlNode root, String name) {
        List<String> values = new List<String>();
        for (Dom.XmlNode node : children(root, name)) {
            String value = node.getText();
            if (!String.isBlank(value)) values.add(value);
        }
        return values;
    }

    private static String firstChildText(Dom.XmlNode root, String name) {
        for (Dom.XmlNode node : children(root, name)) {
            return node.getText();
        }
        return null;
    }

    // Returns all descendants of `root` whose tag matches `name`. The recursive
    // walk is intentional — Salesforce report XML nests the elements we care
    // about (e.g. <chart><chartType/></chart>, <filter><criteriaItems/></filter>),
    // and callers benefit from a flat list regardless of depth.
    private static List<Dom.XmlNode> children(Dom.XmlNode root, String name) {
        List<Dom.XmlNode> matches = new List<Dom.XmlNode>();
        for (Dom.XmlNode child : root.getChildElements()) {
            if (child.getName() == name) {
                matches.add(child);
            }
            matches.addAll(children(child, name));
        }
        return matches;
    }
}