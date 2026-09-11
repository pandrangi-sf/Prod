// DTO-only coverage filler. CR_Types is a bag of @AuraEnabled inner classes
// used as request/response shapes. Real callers (CR_QueryEngine, etc.)
// instantiate them in production code paths, but SF's coverage tool doesn't
// always credit those indirect usages. This test directly exercises every
// inner class so deploying CR_Types schema changes doesn't trip the 75%
// per-class coverage gate.
@IsTest
private class CR_Types_Test {

    @IsTest
    static void exercise_every_dto() {
        CR_Types.ObjectInfo oi = new CR_Types.ObjectInfo();
        oi.apiName = 'x'; oi.label = 'x'; oi.pluralLabel = 'x';
        oi.custom = true; oi.queryable = true; oi.createable = true; oi.updateable = true;
        System.assertEquals('x', oi.apiName);

        CR_Types.FieldInfo fi = new CR_Types.FieldInfo();
        fi.apiName = 'x'; fi.relationshipName = 'x'; fi.label = 'x'; fi.dataType = 'STRING';
        fi.accessible = true; fi.filterable = true; fi.groupable = true; fi.sortable = true;
        fi.calculated = false; fi.referenceTo = new List<String>{ 'Account' };
        fi.picklistValues = new List<String>{ 'A' };
        System.assertEquals('STRING', fi.dataType);

        CR_Types.RelationshipInfo ri = new CR_Types.RelationshipInfo();
        ri.relationshipName = 'x'; ri.objectApiName = 'x'; ri.fieldApiName = 'x';
        ri.label = 'x'; ri.direction = 'parent';
        System.assertEquals('parent', ri.direction);

        CR_Types.DescribeResult dr = new CR_Types.DescribeResult();
        dr.objectInfo = oi;
        dr.fields = new List<CR_Types.FieldInfo>{ fi };
        dr.parentRelationships = new List<CR_Types.RelationshipInfo>{ ri };
        dr.childRelationships = new List<CR_Types.RelationshipInfo>();
        System.assertEquals(1, dr.fields.size());

        CR_Types.DatasetDefinition dd = new CR_Types.DatasetDefinition();
        dd.datasetKey = 'x'; dd.mode = 'live'; dd.primaryObject = 'Account';
        dd.relatedObjects = new List<String>(); dd.fieldPaths = new List<String>();
        dd.relationshipGraphJson = '{}';
        System.assertEquals('live', dd.mode);

        CR_Types.ReportDefinitionRecord rdr = new CR_Types.ReportDefinitionRecord();
        rdr.id = '001000000000001AAA'; rdr.name = 'x'; rdr.datasetKey = 'x';
        rdr.definitionJson = '{}'; rdr.folder = 'x'; rdr.category = 'x';
        rdr.isPublic = true; rdr.version = 1; rdr.lastRunAt = System.now();
        rdr.lastRunStatus = 'x'; rdr.rootObject = 'x'; rdr.createdByName = 'x';
        rdr.createdDate = System.now(); rdr.description = 'x';
        System.assertEquals(true, rdr.isPublic);

        CR_Types.ColumnInfo ci = new CR_Types.ColumnInfo();
        ci.key = 'x'; ci.label = 'x'; ci.dataType = 'STRING'; ci.numeric = false;
        System.assertEquals('x', ci.key);

        CR_Types.QueryResult qr = new CR_Types.QueryResult();
        qr.columns = new List<CR_Types.ColumnInfo>{ ci };
        qr.rows = new List<Map<String, Object>>{ new Map<String, Object>{ 'a' => 1 } };
        qr.totals = new Map<String, Object>{ 'total' => 1 };
        qr.groupLevels = new List<String>{ 'a' };
        qr.nextPageToken = 'token'; qr.executedSoql = 'SELECT'; qr.rowCount = 1;
        qr.aggregateResult = false; qr.warnings = new List<String>();
        qr.errorMessage = null; qr.cacheHit = false;
        System.assertEquals(1, qr.rowCount);
        System.assertEquals(false, qr.cacheHit);

        CR_Types.ValidationResult vr = new CR_Types.ValidationResult();
        vr.addWarning('w');
        vr.addError('e');
        System.assertEquals(false, vr.valid);
        System.assertEquals(1, vr.errors.size());
        System.assertEquals(1, vr.warnings.size());

        CR_Types.DatasetOption datasetOpt = new CR_Types.DatasetOption();
        datasetOpt.datasetKey = 'x'; datasetOpt.label = 'x'; datasetOpt.description = 'x';
        datasetOpt.sobjectApiName = 'Account'; datasetOpt.mode = 'live';
        System.assertEquals('Account', datasetOpt.sobjectApiName);

        CR_Types.ExportStatus es = new CR_Types.ExportStatus();
        es.exportId = '001000000000001AAA'; es.status = 'Complete';
        es.message = 'ok'; es.contentVersionId = '068000000000001AAA';
        System.assertEquals('Complete', es.status);

        CR_Types.MigrationPreview mp = new CR_Types.MigrationPreview();
        mp.sourceName = 'x'; mp.sourceType = 'StandardReport';
        mp.datasetDefinitionJson = '{}'; mp.reportDefinitionJson = '{}';
        mp.unsupportedFeatures = new List<String>{ 'f' };
        mp.requiredEtlChanges = new List<String>{ 'e' };
        System.assertEquals('StandardReport', mp.sourceType);

        CR_Types.JoinedBlockResult jbr = new CR_Types.JoinedBlockResult();
        jbr.blockId = 'x'; jbr.blockLabel = 'x';
        jbr.columns = new List<CR_Types.ColumnInfo>();
        jbr.rowCount = 0; jbr.executedSoql = 'x';
        jbr.warnings = new List<String>(); jbr.joinColumnKey = 'g0';
        System.assertEquals('g0', jbr.joinColumnKey);

        CR_Types.JoinedQueryResult jqr = new CR_Types.JoinedQueryResult();
        jqr.joinKey = 'x'; jqr.joinType = 'inner';
        jqr.blocks = new List<CR_Types.JoinedBlockResult>{ jbr };
        jqr.crossBlockColumns = new List<CR_Types.ColumnInfo>();
        jqr.rows = new List<Map<String, Object>>();
        jqr.rowCount = 0; jqr.warnings = new List<String>();
        jqr.errorMessage = null;
        System.assertEquals('inner', jqr.joinType);
    }
}