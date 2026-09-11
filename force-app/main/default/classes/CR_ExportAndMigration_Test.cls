@IsTest
private class CR_ExportAndMigration_Test {
    @IsTest
    static void queueableExportCreatesContentVersion() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            Id exportId = CR_ExportService.enqueueExport(report.Id);
            Test.stopTest();

            Report_Export__c exportRecord = [
                SELECT Status__c, Content_Version_Id__c
                FROM Report_Export__c
                WHERE Id = :exportId
            ];
            System.assertEquals('Complete', exportRecord.Status__c);
            System.assertNotEquals(null, exportRecord.Content_Version_Id__c);

            CR_Types.ExportStatus status = CR_ExportService.getExportStatus(exportId);
            System.assertEquals('Complete', status.status);
            System.assertNotEquals(null, status.contentVersionId);

            List<CR_ExportService.ExportQueueItem> allQueue = CR_ExportService.listRecentExports(null, 5);
            System.assertEquals(1, allQueue.size());
            System.assertEquals(exportId, allQueue[0].exportId);

            List<CR_ExportService.ExportQueueItem> reportQueue = CR_ExportService.listRecentExports(report.Id, 5);
            System.assertEquals(1, reportQueue.size());
            System.assertEquals(exportId, reportQueue[0].exportId);
        }
    }

    @IsTest
    static void largeExportSplitsIntoMultipleFiles() {
        // The factory makes two data rows; forcing 1 row/part proves the
        // exporter flushes multiple bounded files and links each to the export
        // record. Called directly (not via the Queueable) because @TestVisible
        // static overrides don't cross the async boundary.
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        Report_Export__c exportRecord = new Report_Export__c(
            Name = 'Split Test Export',
            Report_Definition__c = report.Id,
            Status__c = 'Queued'
        );
        insert exportRecord;

        CR_ExportService.maxPartRows = 1;

        // The export runs an FLS-enforced report, so execute it as a provisioned user.
        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            CR_ExportService.ExportResult er =
                CR_ExportService.buildCsvFiles(exportRecord, report.Definition_JSON__c, null);
            Test.stopTest();

            System.assertEquals(2, er.rowCount, 'Both data rows should be exported.');
            System.assertEquals(2, er.partCount, 'At 1 row per part, two rows produce two files.');
            System.assertEquals(2, er.contentVersionIds.size(), 'One ContentVersion per part.');

            Integer links = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :exportRecord.Id];
            System.assertEquals(2, links, 'Every part should be linked to the export record.');
        }
    }

    @IsTest
    static void exportPausesOnCpuBudgetAndResumesWhereItLeftOff() {
        // A 33k-row export blew the 60s async CPU limit in production and, because a CPU
        // LimitException cannot be caught, the record was left stuck on "Queued". The exporter
        // now stops when it nears the budget and re-enqueues itself. Forcing a zero CPU budget
        // with one row per page makes it yield after the first page.
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        Report_Export__c exportRecord = new Report_Export__c(
            Name = 'Resume Test Export',
            Report_Definition__c = report.Id,
            Status__c = 'Queued'
        );
        insert exportRecord;

        CR_ExportService.pageSize = 1;

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();

            CR_ExportService.cpuBudgetMs = 0; // out of budget the moment the first page lands
            CR_ExportService.ExportResult first =
                CR_ExportService.buildCsvFiles(exportRecord, report.Definition_JSON__c, null);

            System.assertEquals(false, first.done, 'The exporter should have paused, not finished.');
            System.assertNotEquals(null, first.nextPageToken, 'A paused export must say where to resume.');
            System.assertEquals(1, first.rowCount, 'One page of one row was written before pausing.');
            System.assertEquals(1, first.partCount, 'Work done before the pause is flushed to a file.');

            CR_ExportService.cpuBudgetMs = 35000; // fresh transaction, full budget
            CR_ExportService.ExportResult second = CR_ExportService.buildCsvFiles(
                exportRecord, report.Definition_JSON__c, null,
                first.nextPageToken, first.rowCount, first.partCount
            );

            Test.stopTest();

            System.assertEquals(true, second.done, 'The resumed run should finish the export.');
            System.assertEquals(2, second.rowCount,
                'Resuming must continue the running total, not restart from zero.');
            System.assertEquals(2, second.partCount, 'Part numbering continues across the chain.');

            Integer links = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :exportRecord.Id];
            System.assertEquals(2, links, 'Every part from every chunk stays linked to the export record.');
        }
    }

    @IsTest
    static void emptyResultStillProducesOneFile() {
        // No fact rows inserted -> zero data rows. The exporter should still
        // emit a single headers-only file rather than nothing.
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        Report_Export__c exportRecord = new Report_Export__c(
            Name = 'Empty Export',
            Report_Definition__c = report.Id,
            Status__c = 'Queued'
        );
        insert exportRecord;

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            CR_ExportService.ExportResult er =
                CR_ExportService.buildCsvFiles(exportRecord, report.Definition_JSON__c, null);
            Test.stopTest();

            System.assertEquals(0, er.rowCount, 'No data rows.');
            System.assertEquals(1, er.partCount, 'Empty result still yields one headers-only file.');
        }
    }

    @IsTest
    static void filteredExportUsesDashboardFilters() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            Id exportId = CR_ExportService.enqueueFilteredExport(
                report.Id,
                '[{"field":"Stage_Name__c","operator":"=","value":"Prospecting"}]'
            );
            Test.stopTest();

            Report_Export__c exportRecord = [
                SELECT Status__c, Content_Version_Id__c
                FROM Report_Export__c
                WHERE Id = :exportId
            ];
            System.assertEquals('Complete', exportRecord.Status__c);
            System.assertNotEquals(null, exportRecord.Content_Version_Id__c);
        }
    }

    @IsTest
    static void dashboardExportQueuesBoundedComponentReports() {
        CR_TestDataFactory.createFactOpportunityRows();
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(true);
        Dashboard__c dashboard = new Dashboard__c(
            Name = 'Export Dashboard',
            Developer_Name__c = 'Export_Dashboard',
            Folder__c = 'Tests',
            Category__c = 'Unit',
            Filter_JSON__c = '[{"field":"Stage_Name__c","operator":"=","value":"Prospecting"}]',
            Layout_JSON__c = '{"columns":12}',
            Is_Public__c = true,
            Version__c = 1
        );
        insert dashboard;
        insert new Dashboard_Component__c(
            Name = 'Pipeline',
            Dashboard__c = dashboard.Id,
            Report_Definition__c = report.Id,
            Visualization_JSON__c = '{"type":"table"}',
            Position_X__c = 0,
            Position_Y__c = 0,
            Width__c = 6,
            Height__c = 3
        );

        System.runAs(CR_TestDataFactory.createReportingAdminUser()) {
            Test.startTest();
            CR_ExportService.DashboardExportResult result = CR_ExportService.enqueueDashboardExports(dashboard.Id);
            Test.stopTest();

            System.assertEquals(1, result.exportIds.size());
            Report_Export__c exportRecord = [
                SELECT Status__c, Content_Version_Id__c
                FROM Report_Export__c
                WHERE Id = :result.exportIds[0]
            ];
            System.assertEquals('Complete', exportRecord.Status__c);
            System.assertNotEquals(null, exportRecord.Content_Version_Id__c);
        }
    }

    @IsTest
    static void exportFailureUpdatesStatus() {
        Report_Definition__c report = CR_TestDataFactory.createFactOpportunityReport(false);
        report.Name = 'Bad Export Report';
        report.Developer_Name__c = 'Bad_Export_Report';
        report.Definition_JSON__c = JSON.serialize(new Map<String, Object>{
            'dataset' => new Map<String, Object>{
                'datasetKey' => 'Bad_Object',
                'mode' => 'live',
                'objectApiName' => 'Nope__c',
                'primaryObject' => 'Nope__c'
            },
            'fields' => new List<Object>{ new Map<String, Object>{ 'path' => 'Name', 'label' => 'Name' } },
            'filters' => new List<Object>(),
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>()
        });
        insert report;

        Test.startTest();
        Id exportId = CR_ExportService.enqueueExport(report.Id);
        Test.stopTest();

        Report_Export__c exportRecord = [
            SELECT Status__c, Content_Version_Id__c
            FROM Report_Export__c
            WHERE Id = :exportId
        ];
        System.assertEquals('Failed', exportRecord.Status__c);
        System.assertEquals(null, exportRecord.Content_Version_Id__c);
    }

    @IsTest
    static void dashboardExportWithNoReportComponentsReturnsWarning() {
        Dashboard__c dashboard = new Dashboard__c(
            Name = 'Empty Export Dashboard',
            Developer_Name__c = 'Empty_Export_Dashboard',
            Folder__c = 'Tests',
            Category__c = 'Unit',
            Filter_JSON__c = '[]',
            Layout_JSON__c = '{"columns":12}',
            Is_Public__c = true,
            Version__c = 1
        );
        insert dashboard;

        CR_ExportService.DashboardExportResult result = CR_ExportService.enqueueDashboardExports(dashboard.Id);

        System.assertEquals(0, result.exportIds.size());
        System.assertEquals(false, result.warnings.isEmpty());
    }

    @IsTest
    static void previewAndMigrateReportXml_realSalesforceShape() {
        // Mirrors the actual Salesforce Report metadata format: <columns> wraps
        // <field>, <filter> wraps <criteriaItems>, multiple criteria stay
        // distinct, <groupingsDown> wraps <field> + <dateGranularity>.
        String xml = '<Report xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<reportType>OpportunityList</reportType>'
            + '<columns><field>Opportunity.Name</field></columns>'
            + '<columns><field>Opportunity.Amount</field><aggregateTypes>Sum</aggregateTypes></columns>'
            + '<filter>'
            +   '<booleanFilter>1 AND 2</booleanFilter>'
            +   '<criteriaItems><column>Opportunity.StageName</column><operator>equals</operator><value>Prospecting</value></criteriaItems>'
            +   '<criteriaItems><column>Opportunity.Amount</column><operator>greaterThan</operator><value>10000</value></criteriaItems>'
            + '</filter>'
            + '<groupingsDown><field>Opportunity.OwnerId</field><dateGranularity>None</dateGranularity><sortOrder>Asc</sortOrder></groupingsDown>'
            + '<chart><chartType>VerticalBar</chartType></chart>'
            + '</Report>';

        CR_Types.MigrationPreview preview = CR_MetadataMigrationService.previewReportXml('Pipeline', xml);
        // Both columns made it through the <field> wrapper.
        System.assert(preview.reportDefinitionJson.contains('Opportunity.Name'),
            'first column field should be extracted');
        System.assert(preview.reportDefinitionJson.contains('Opportunity.Amount'),
            'second column field should be extracted');
        // Both criteriaItems became distinct filters, not collapsed into one.
        System.assert(preview.reportDefinitionJson.contains('Opportunity.StageName'),
            'first criteriaItem field should be present');
        System.assert(preview.reportDefinitionJson.contains('"value" : "10000"'),
            'second criteriaItem value should be present');
        // Grouping field extracted from inside <groupingsDown><field>.
        System.assert(preview.reportDefinitionJson.contains('Opportunity.OwnerId'),
            'grouping field should be extracted from real SF shape');

        Id reportId = CR_MetadataMigrationService.migrateReportXml('Pipeline', 'Migrated', xml);
        System.assertNotEquals(null, reportId, 'migration of real SF report XML should succeed');
    }

    // Legacy "flat" XML shape that earlier drafts produced. Kept testable so a
    // future refactor doesn't silently drop the backward-compat fallback.
    @IsTest
    static void previewAndMigrateReportXml_legacyFlatShape() {
        String xml = '<Report xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<reportType>Opportunity</reportType>'
            + '<columns>Opportunity.Name</columns>'
            + '<columns>Opportunity.Amount</columns>'
            + '<filter><column>Opportunity.StageName</column><operator>equals</operator><value>Prospecting</value></filter>'
            + '<groupingsDown>Opportunity.StageName</groupingsDown>'
            + '<chartType>VerticalBar</chartType>'
            + '</Report>';

        CR_Types.MigrationPreview preview = CR_MetadataMigrationService.previewReportXml('Legacy Pipeline', xml);
        System.assert(preview.reportDefinitionJson.contains('Opportunity.Amount'),
            'flat-shape columns should still parse via fallback');

        Id reportId = CR_MetadataMigrationService.migrateReportXml('Legacy Pipeline', 'Migrated', xml);
        System.assertNotEquals(null, reportId);
    }
}