public with sharing class CR_ExportService {
    public class ExportQueueItem {
        @AuraEnabled public Id exportId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Id reportDefinitionId { get; set; }
        @AuraEnabled public String reportName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String contentVersionId { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
    }

    public class DashboardExportResult {
        @AuraEnabled public List<Id> exportIds { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }

        public DashboardExportResult() {
            exportIds = new List<Id>();
            warnings = new List<String>();
        }
    }

    private static final Integer MAX_DASHBOARD_EXPORTS = 10;

    // Export sizing knobs. A single Apex-built file is heap-bound (~12 MB hard
    // limit), so large result sets are flushed into multiple bounded CSV "part"
    // files instead of one. @TestVisible so a unit test can force a split on a
    // tiny dataset. PAGE_SIZE drives how many rows we pull from the query
    // engine per call; the part caps decide when to flush a file.
    @TestVisible private static Integer maxTotalRows = 100000;
    @TestVisible private static Integer pageSize = 2000;
    @TestVisible private static Integer maxPartRows = 50000;
    @TestVisible private static Integer maxPartBytes = 2500000;   // ~2.5 MB CSV text/part
    @TestVisible private static Integer heapFlushBytes = 6000000; // defensive: flush if heap climbs

    // Async Apex gets 60s of CPU. Escaping every cell of a large report costs far more than
    // that in one go — a 33k-row export died on "Apex CPU time limit exceeded" in production.
    // So each transaction stops once it has burned this much CPU, flushes what it has, and
    // re-enqueues itself to carry on with a fresh 60s budget. Headroom below 60s covers the
    // flush (Blob + ContentVersion insert) and the bookkeeping after the loop.
    @TestVisible private static Integer cpuBudgetMs = 35000;

    @TestVisible
    private class ExportResult {
        public List<Id> contentVersionIds = new List<Id>();
        public Integer rowCount = 0;
        public Integer partCount = 0;
        public Boolean truncated = false;
        // Resume state: when done is false the caller must re-enqueue starting at nextPageToken.
        public Boolean done = false;
        public String nextPageToken;
    }

    @AuraEnabled
    public static Id enqueueExport(Id reportDefinitionId) {
        return enqueueExportInternal(reportDefinitionId, null);
    }

    @AuraEnabled
    public static Id enqueueFilteredExport(Id reportDefinitionId, String dashboardFiltersJson) {
        return enqueueExportInternal(reportDefinitionId, dashboardFiltersJson);
    }

    @AuraEnabled
    public static DashboardExportResult enqueueDashboardExports(Id dashboardId) {
        if (dashboardId == null) {
            throw new AuraHandledException('Dashboard Id is required.');
        }

        Dashboard__c dashboard = [
            SELECT Id, Name, Filter_JSON__c
            FROM Dashboard__c
            WHERE Id = :dashboardId
            LIMIT 1
        ];

        Integer componentQueryLimit = MAX_DASHBOARD_EXPORTS + 1;
        List<Dashboard_Component__c> components = [
            SELECT Id, Name, Report_Definition__c
            FROM Dashboard_Component__c
            WHERE Dashboard__c = :dashboardId
            AND Report_Definition__c != null
            ORDER BY Position_Y__c, Position_X__c
            LIMIT :componentQueryLimit
        ];

        DashboardExportResult result = new DashboardExportResult();
        if (components.size() > MAX_DASHBOARD_EXPORTS) {
            result.warnings.add(
                'Only the first ' + MAX_DASHBOARD_EXPORTS
                + ' component reports were queued to avoid too many async jobs at once.'
            );
        }

        Set<Id> queuedReportIds = new Set<Id>();
        Integer queuedCount = 0;
        for (Dashboard_Component__c component : components) {
            if (queuedCount >= MAX_DASHBOARD_EXPORTS) {
                break;
            }
            if (queuedReportIds.contains(component.Report_Definition__c)) {
                continue;
            }
            queuedReportIds.add(component.Report_Definition__c);
            result.exportIds.add(enqueueExportInternal(component.Report_Definition__c, dashboard.Filter_JSON__c));
            queuedCount++;
        }
        if (result.exportIds.isEmpty()) {
            result.warnings.add('No dashboard components with source reports were found.');
        }
        return result;
    }

    private static Id enqueueExportInternal(Id reportDefinitionId, String dashboardFiltersJson) {
        if (reportDefinitionId == null) {
            throw new AuraHandledException('Report Definition Id is required.');
        }
        Report_Definition__c report = [
            SELECT Id, Name
            FROM Report_Definition__c
            WHERE Id = :reportDefinitionId
            LIMIT 1
        ];
        Report_Export__c exportRecord = new Report_Export__c(
            Name = report.Name + ' Export ' + Datetime.now().format('yyyy-MM-dd HH:mm'),
            Report_Definition__c = reportDefinitionId,
            Status__c = 'Queued',
            Message__c = hasDashboardFilters(dashboardFiltersJson)
                ? 'Export queued with dashboard filters.'
                : 'Export queued.'
        );
        insert exportRecord;
        System.enqueueJob(new ExportQueueable(exportRecord.Id, dashboardFiltersJson));
        return exportRecord.Id;
    }

    @AuraEnabled(cacheable=true)
    public static CR_Types.ExportStatus getExportStatus(Id exportId) {
        Report_Export__c exportRecord = [
            SELECT Id, Status__c, Message__c, Content_Version_Id__c
            FROM Report_Export__c
            WHERE Id = :exportId
            LIMIT 1
        ];
        CR_Types.ExportStatus status = new CR_Types.ExportStatus();
        status.exportId = exportRecord.Id;
        status.status = exportRecord.Status__c;
        status.message = exportRecord.Message__c;
        status.contentVersionId = exportRecord.Content_Version_Id__c;
        return status;
    }

    @AuraEnabled
    public static List<ExportQueueItem> listRecentExports(Id reportDefinitionId, Integer maxResults) {
        Integer boundedLimit = Math.min(Math.max(maxResults == null ? 10 : maxResults, 1), 25);
        List<Report_Export__c> exportRecords = reportDefinitionId == null
            ? [
                SELECT Id, Name, Report_Definition__c, Report_Definition__r.Name, Status__c,
                    Message__c, Content_Version_Id__c, CreatedDate
                FROM Report_Export__c
                ORDER BY CreatedDate DESC
                LIMIT :boundedLimit
            ]
            : [
                SELECT Id, Name, Report_Definition__c, Report_Definition__r.Name, Status__c,
                    Message__c, Content_Version_Id__c, CreatedDate
                FROM Report_Export__c
                WHERE Report_Definition__c = :reportDefinitionId
                ORDER BY CreatedDate DESC
                LIMIT :boundedLimit
            ];

        List<ExportQueueItem> queue = new List<ExportQueueItem>();
        for (Report_Export__c exportRecord : exportRecords) {
            ExportQueueItem item = new ExportQueueItem();
            item.exportId = exportRecord.Id;
            item.name = exportRecord.Name;
            item.reportDefinitionId = exportRecord.Report_Definition__c;
            item.reportName = exportRecord.Report_Definition__r == null ? null : exportRecord.Report_Definition__r.Name;
            item.status = exportRecord.Status__c;
            item.message = exportRecord.Message__c;
            item.contentVersionId = exportRecord.Content_Version_Id__c;
            item.createdDate = exportRecord.CreatedDate;
            queue.add(item);
        }
        return queue;
    }

    // Runs the export one CPU-bounded chunk per transaction, chaining to itself until the
    // report is exhausted. Everything needed to resume (where we were in the result set, how
    // many rows/parts are already written, which file to link on the export record) rides on
    // the job's own fields — a Queueable's member state is serialized between links in the chain.
    public class ExportQueueable implements Queueable {
        private Id exportId;
        private String dashboardFiltersJson;
        private String pageToken;
        private Integer rowsSoFar;
        private Integer partsSoFar;
        private Id firstContentVersionId;

        public ExportQueueable(Id exportId) {
            this(exportId, null);
        }

        public ExportQueueable(Id exportId, String dashboardFiltersJson) {
            this(exportId, dashboardFiltersJson, null, 0, 0, null);
        }

        public ExportQueueable(
            Id exportId,
            String dashboardFiltersJson,
            String pageToken,
            Integer rowsSoFar,
            Integer partsSoFar,
            Id firstContentVersionId
        ) {
            this.exportId = exportId;
            this.dashboardFiltersJson = dashboardFiltersJson;
            this.pageToken = pageToken;
            this.rowsSoFar = rowsSoFar == null ? 0 : rowsSoFar;
            this.partsSoFar = partsSoFar == null ? 0 : partsSoFar;
            this.firstContentVersionId = firstContentVersionId;
        }

        public void execute(QueueableContext context) {
            Report_Export__c exportRecord = [
                SELECT Id, Name, Report_Definition__c, Status__c
                FROM Report_Export__c
                WHERE Id = :exportId
                LIMIT 1
            ];
            exportRecord.Status__c = 'Running';
            exportRecord.Message__c = rowsSoFar == 0
                ? 'Export running.'
                : 'Export running — ' + rowsSoFar + ' rows written so far.';
            update exportRecord;

            try {
                Report_Definition__c report = [
                    SELECT Id, Name, Definition_JSON__c
                    FROM Report_Definition__c
                    WHERE Id = :exportRecord.Report_Definition__c
                    LIMIT 1
                ];
                ExportResult er = buildCsvFiles(
                    exportRecord, report.Definition_JSON__c, dashboardFiltersJson,
                    pageToken, rowsSoFar, partsSoFar
                );

                Id firstCv = firstContentVersionId != null
                    ? firstContentVersionId
                    : (er.contentVersionIds.isEmpty() ? null : er.contentVersionIds[0]);

                if (!er.done) {
                    // Out of CPU for this transaction, but there are more rows to write.
                    // Commit the progress so far and pick up where we left off.
                    exportRecord.Message__c = 'Export running — ' + er.rowCount + ' rows written so far.';
                    update exportRecord;
                    if (!Test.isRunningTest()) {
                        // Chaining is not permitted inside a test transaction; the chunk logic
                        // itself is covered directly in CR_ExportAndMigration_Test.
                        System.enqueueJob(new ExportQueueable(
                            exportId, dashboardFiltersJson,
                            er.nextPageToken, er.rowCount, er.partCount, firstCv
                        ));
                    }
                    return;
                }

                exportRecord.Status__c = 'Complete';
                exportRecord.Content_Version_Id__c = firstCv;
                exportRecord.Message__c = buildCompletionMessage(er);
                update exportRecord;
            } catch (Exception ex) {
                exportRecord.Status__c = 'Failed';
                exportRecord.Message__c = ex.getMessage();
                update exportRecord;
            }
        }
    }

    // Builds one or more CSV files for the report, flushing a new part file
    // whenever the in-progress buffer reaches the per-part row/byte cap (or heap
    // starts to climb). This keeps peak heap bounded to roughly one part instead
    // of the whole result set, so large exports no longer abort at the old
    // ~9 MB single-file ceiling. Each part is linked to the export record so all
    // of them are reachable from its Files related list.
    @TestVisible
    private static ExportResult buildCsvFiles(Report_Export__c exportRecord, String definitionJson, String dashboardFiltersJson) {
        return buildCsvFiles(exportRecord, definitionJson, dashboardFiltersJson, null, 0, 0);
    }

    // Resumable form. Picks up at startPageToken with the running row/part totals from earlier
    // links in the chain, and returns with done = false if it ran out of CPU before finishing.
    @TestVisible
    private static ExportResult buildCsvFiles(
        Report_Export__c exportRecord,
        String definitionJson,
        String dashboardFiltersJson,
        String startPageToken,
        Integer startRowCount,
        Integer startPartCount
    ) {
        ExportResult er = new ExportResult();
        er.rowCount = startRowCount == null ? 0 : startRowCount;
        er.partCount = startPartCount == null ? 0 : startPartCount;
        String headerLine = null;
        List<String> lines = new List<String>();
        Integer partBytes = 0;
        Integer partRows = 0;
        String pageToken = startPageToken;
        Boolean outOfCpu = false;

        while (er.rowCount < maxTotalRows) {
            CR_Types.QueryResult result = CR_QueryEngine.runReport(definitionJson, pageToken, pageSize, dashboardFiltersJson);

            if (headerLine == null) {
                List<String> headers = new List<String>();
                for (CR_Types.ColumnInfo column : result.columns) {
                    headers.add(csvEscape(column.label));
                }
                headerLine = String.join(headers, ',');
                lines.add(headerLine);
                partBytes = headerLine.length() + 2;
            }

            for (Map<String, Object> row : result.rows) {
                List<String> values = new List<String>();
                for (CR_Types.ColumnInfo column : result.columns) {
                    values.add(csvEscape(String.valueOf(row.get(column.key))));
                }
                String line = String.join(values, ',');
                lines.add(line);
                partBytes += line.length() + 2; // +2 approximates the CRLF separator
                partRows++;
                er.rowCount++;

                if (partRows >= maxPartRows || partBytes >= maxPartBytes || Limits.getHeapSize() > heapFlushBytes) {
                    er.contentVersionIds.add(flushPart(exportRecord, lines, er.partCount + 1));
                    er.partCount++;
                    // Start a fresh buffer (old list/strings become collectable),
                    // repeating the header so each file opens independently.
                    lines = new List<String>{ headerLine };
                    partBytes = headerLine.length() + 2;
                    partRows = 0;
                }

                if (er.rowCount >= maxTotalRows) {
                    er.truncated = true;
                    break;
                }
            }

            if (er.truncated || String.isBlank(result.nextPageToken) || result.rows.isEmpty()) {
                break;
            }
            pageToken = result.nextPageToken;

            // Checked once per page rather than per row: a page is ~2k rows and costs a couple
            // of seconds, so the remaining budget always covers finishing the page we're on plus
            // the flush below. Yielding here is what keeps a big export off the 60s CPU ceiling.
            if (Limits.getCpuTime() > cpuBudgetMs) {
                outOfCpu = true;
                break;
            }
        }

        er.done = !outOfCpu;
        er.nextPageToken = outOfCpu ? pageToken : null;

        // Flush the trailing buffer. The header-only guard (size > 1) avoids an
        // empty extra file when the row count divides evenly into parts; the
        // partCount == 0 guard still emits a single headers-only file for an
        // empty result set — but only once the export is actually finished, so a
        // mid-chain pause never emits a stray headers-only file.
        if (lines.size() > 1 || (er.done && er.partCount == 0)) {
            er.contentVersionIds.add(flushPart(exportRecord, lines, er.partCount + 1));
            er.partCount++;
        }
        return er;
    }

    private static Id flushPart(Report_Export__c exportRecord, List<String> lines, Integer partNumber) {
        // CRLF line endings + UTF-8 BOM so Excel on Windows opens the file
        // correctly (Unicode + ASCII handled, no auto-detection issues).
        String bom = String.fromCharArray(new List<Integer>{ 65279 }); // U+FEFF BOM
        String csv = bom + String.join(lines, '\r\n');
        String title = exportRecord.Name + ' (part ' + partNumber + ')';
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title.replaceAll('[^A-Za-z0-9_ -]', '') + '.csv',
            VersionData = Blob.valueOf(csv)
        );
        insert version;
        Id contentDocumentId = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id LIMIT 1
        ].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId = exportRecord.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        return version.Id;
    }

    private static String buildCompletionMessage(ExportResult er) {
        String cap = er.truncated
            ? ' Output was capped at ' + er.rowCount + ' rows — narrow the filters to capture everything.'
            : '';
        if (er.partCount <= 1) {
            return 'Export complete (' + er.rowCount + ' rows). Open the CSV from the Files related list on this record.' + cap;
        }
        return 'Export complete (' + er.rowCount + ' rows across ' + er.partCount
            + ' CSV files). Open them from the Files related list on this record.' + cap;
    }

    private static Boolean hasDashboardFilters(String dashboardFiltersJson) {
        return !String.isBlank(dashboardFiltersJson) && dashboardFiltersJson.trim() != '[]';
    }

    private static String csvEscape(String value) {
        // Centralized in CR_CsvUtil so the export and subscription paths escape
        // identically. The literal string "null" is a legitimate value.
        return CR_CsvUtil.escape(value);
    }
}