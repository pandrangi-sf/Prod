public inherited sharing class CR_Types {
    public class ObjectInfo {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String pluralLabel { get; set; }
        @AuraEnabled public Boolean custom { get; set; }
        @AuraEnabled public Boolean queryable { get; set; }
        @AuraEnabled public Boolean createable { get; set; }
        @AuraEnabled public Boolean updateable { get; set; }
    }

    public class FieldInfo {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String relationshipName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String dataType { get; set; }
        @AuraEnabled public Boolean accessible { get; set; }
        @AuraEnabled public Boolean filterable { get; set; }
        @AuraEnabled public Boolean groupable { get; set; }
        @AuraEnabled public Boolean sortable { get; set; }
        @AuraEnabled public Boolean calculated { get; set; }
        @AuraEnabled public List<String> referenceTo { get; set; }
        @AuraEnabled public List<String> picklistValues { get; set; }
    }

    public class RelationshipInfo {
        @AuraEnabled public String relationshipName { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String fieldApiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String direction { get; set; }
    }

    public class DescribeResult {
        @AuraEnabled public ObjectInfo objectInfo { get; set; }
        @AuraEnabled public List<FieldInfo> fields { get; set; }
        @AuraEnabled public List<RelationshipInfo> parentRelationships { get; set; }
        @AuraEnabled public List<RelationshipInfo> childRelationships { get; set; }
    }

    public class DatasetDefinition {
        @AuraEnabled public String datasetKey { get; set; }
        @AuraEnabled public String mode { get; set; }
        @AuraEnabled public String primaryObject { get; set; }
        @AuraEnabled public List<String> relatedObjects { get; set; }
        @AuraEnabled public List<String> fieldPaths { get; set; }
        @AuraEnabled public String relationshipGraphJson { get; set; }
    }

    public class ReportDefinitionRecord {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String datasetKey { get; set; }
        @AuraEnabled public String definitionJson { get; set; }
        @AuraEnabled public String folder { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Boolean isPublic { get; set; }
        @AuraEnabled public Decimal version { get; set; }
        @AuraEnabled public Datetime lastRunAt { get; set; }
        @AuraEnabled public String lastRunStatus { get; set; }
        @AuraEnabled public String rootObject { get; set; }
        @AuraEnabled public String createdByName { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
        @AuraEnabled public String description { get; set; }
    }

    public class ColumnInfo {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String dataType { get; set; }
        @AuraEnabled public Boolean numeric { get; set; }
    }

    public class QueryResult {
        @AuraEnabled public List<ColumnInfo> columns { get; set; }
        @AuraEnabled public List<Map<String, Object>> rows { get; set; }
        @AuraEnabled public Map<String, Object> totals { get; set; }
        @AuraEnabled public List<String> groupLevels { get; set; }
        @AuraEnabled public String nextPageToken { get; set; }
        @AuraEnabled public String executedSoql { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public Boolean aggregateResult { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        // Phase 3 v5: true when the result came from CR_QueryCacheService rather
        // than from a fresh SOQL execution. Lets the Health Monitor show cache
        // hit rate and lets the LWC label stale-vs-fresh data if it wants to.
        @AuraEnabled public Boolean cacheHit { get; set; }
        // Optional viewer-side default grouping: a column field path the report
        // viewer should pre-group detail rows by on load (Definition_JSON
        // "viewGroupBy"). Pure display hint — does not affect the SOQL.
        @AuraEnabled public String viewGroupBy { get; set; }
    }

    public class ValidationResult {
        @AuraEnabled public Boolean valid { get; set; }
        @AuraEnabled public List<String> errors { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }

        public ValidationResult() {
            valid = true;
            errors = new List<String>();
            warnings = new List<String>();
        }

        public void addError(String message) {
            valid = false;
            errors.add(message);
        }

        public void addWarning(String message) {
            warnings.add(message);
        }
    }

    public class DatasetOption {
        @AuraEnabled public String datasetKey { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String sobjectApiName { get; set; }
        @AuraEnabled public String mode { get; set; }
    }

    public class ExportStatus {
        @AuraEnabled public Id exportId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String contentVersionId { get; set; }
    }

    public class MigrationPreview {
        @AuraEnabled public String sourceName { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public String datasetDefinitionJson { get; set; }
        @AuraEnabled public String reportDefinitionJson { get; set; }
        @AuraEnabled public List<String> unsupportedFeatures { get; set; }
        @AuraEnabled public List<String> requiredEtlChanges { get; set; }
    }

    public class JoinedBlockResult {
        @AuraEnabled public String blockId { get; set; }
        @AuraEnabled public String blockLabel { get; set; }
        @AuraEnabled public List<ColumnInfo> columns { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public String executedSoql { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }
        // Column key inside this block that the engine matched against the join key
        // (e.g., "g0" for an aggregate block grouped by the join field). The renderer
        // hides this column from the namespaced output to avoid duplicating the
        // leading join-key column.
        @AuraEnabled public String joinColumnKey { get; set; }
    }

    public class JoinedQueryResult {
        @AuraEnabled public String joinKey { get; set; }
        @AuraEnabled public String joinType { get; set; }
        @AuraEnabled public List<JoinedBlockResult> blocks { get; set; }
        @AuraEnabled public List<ColumnInfo> crossBlockColumns { get; set; }
        @AuraEnabled public List<Map<String, Object>> rows { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
    }
}