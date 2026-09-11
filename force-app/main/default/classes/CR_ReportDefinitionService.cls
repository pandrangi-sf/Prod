public with sharing class CR_ReportDefinitionService {
    @AuraEnabled
    public static Id saveReport(
        Id reportDefinitionId,
        String name,
        String datasetKey,
        String definitionJson,
        String folder,
        String category,
        Boolean isPublic,
        Decimal lastKnownVersion,
        String description
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('Report name is required.');
        }
        // Building is gated by object CRUD: Apex DML runs in system mode for
        // CRUD by default, so without this an insert/update would succeed even
        // for a view-only user.
        if (reportDefinitionId == null && !Schema.sObjectType.Report_Definition__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to create reports.');
        }
        if (reportDefinitionId != null && !Schema.sObjectType.Report_Definition__c.isUpdateable()) {
            throw new AuraHandledException('You do not have permission to edit reports.');
        }
        if (definitionJson != null && definitionJson.length() > 130000) {
            throw new AuraHandledException(
                'Report definition is too large (' + definitionJson.length()
                + ' characters). The Definition_JSON__c field caps at 131,072. '
                + 'Reduce filters, formulas, or buckets, or split the report.'
            );
        }
        CR_Types.ValidationResult validation = CR_QueryEngine.validateDefinition(definitionJson);
        if (!validation.valid) {
            throw new AuraHandledException(String.join(validation.errors, '\n'));
        }

        rejectIfDuplicateName(name, reportDefinitionId);

        Report_Definition__c record;
        if (reportDefinitionId == null) {
            record = new Report_Definition__c();
        } else {
            record = [
                SELECT Id, Version__c
                FROM Report_Definition__c
                WHERE Id = :reportDefinitionId
                LIMIT 1
            ];
            if (lastKnownVersion != null && record.Version__c != null
                && record.Version__c != lastKnownVersion) {
                // The [CR_CONFLICT] prefix is a stable marker the LWC matches on
                // to render a sticky reload-required toast. Don't change it without
                // updating crReportBuilder.save() and crDashboardBuilder.save().
                throw new AuraHandledException(
                    '[CR_CONFLICT] This report was modified by another user since you loaded it. ' +
                    'Reload to see the latest changes before saving.'
                );
            }
        }

        record.Name = name;
        record.Developer_Name__c = normalizeDeveloperName(name);
        record.Root_Object__c = inferRootObject(definitionJson, datasetKey);
        record.Dataset_Key__c = datasetKey;
        record.Definition_JSON__c = definitionJson;
        record.Folder__c = folder;
        record.Folder_Ref__c = CR_FolderService.resolveFolderId(folder);
        record.Category__c = category;
        record.Description__c = description;
        record.Is_Public__c = isPublic == true;
        record.Version__c = record.Version__c == null ? 1 : record.Version__c + 1;

        if (reportDefinitionId == null) {
            insert record;
        } else {
            update record;
        }
        return record.Id;
    }

    @AuraEnabled
    public static Id saveJoinedReport(
        Id reportDefinitionId,
        String name,
        String joinedConfigJson,
        String folder,
        String category,
        Boolean isPublic,
        Decimal lastKnownVersion,
        String description
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('Report name is required.');
        }
        if (reportDefinitionId == null && !Schema.sObjectType.Report_Definition__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to create reports.');
        }
        if (reportDefinitionId != null && !Schema.sObjectType.Report_Definition__c.isUpdateable()) {
            throw new AuraHandledException('You do not have permission to edit reports.');
        }
        if (joinedConfigJson != null && joinedConfigJson.length() > 130000) {
            throw new AuraHandledException(
                'Joined config is too large (' + joinedConfigJson.length()
                + ' characters). Joined_Config_JSON__c caps at 131,072.'
            );
        }
        // Phase 1 v2: Joined Reports are out of scope (CR_JoinedQueryEngine removed).
        // Joined_Config_JSON__c field is retained but write-only — no UI exposes it,
        // and the structural validator returns to Phase 1.5. Inline JSON shape check
        // here keeps the API contract safe without dragging CR_JoinedQueryEngine in.
        if (joinedConfigJson != null) {
            try {
                JSON.deserializeUntyped(joinedConfigJson);
            } catch (Exception ex) {
                throw new AuraHandledException('Joined_Config_JSON__c must be valid JSON: ' + ex.getMessage());
            }
        }

        rejectIfDuplicateName(name, reportDefinitionId);

        Report_Definition__c record;
        if (reportDefinitionId == null) {
            record = new Report_Definition__c();
        } else {
            record = [
                SELECT Id, Version__c, Report_Type__c
                FROM Report_Definition__c
                WHERE Id = :reportDefinitionId
                LIMIT 1
            ];
            if (lastKnownVersion != null && record.Version__c != null
                && record.Version__c != lastKnownVersion) {
                throw new AuraHandledException(
                    '[CR_CONFLICT] This report was modified by another user since you loaded it. ' +
                    'Reload to see the latest changes before saving.'
                );
            }
        }

        // Pull joinKey + first block's primary object for searchable metadata so
        // Root_Object__c stays useful even though there are multiple datasets.
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(joinedConfigJson);
        String firstBlockObject = inferFirstBlockObject(config);

        record.Name = name;
        record.Developer_Name__c = normalizeDeveloperName(name);
        record.Report_Type__c = 'Joined';
        record.Joined_Config_JSON__c = joinedConfigJson;
        record.Description__c = description;
        // Definition_JSON__c is unused for joined reports but the field is required-ish
        // by some downstream tools; write an empty placeholder rather than null.
        if (String.isBlank(record.Definition_JSON__c)) {
            record.Definition_JSON__c = '{}';
        }
        record.Root_Object__c = firstBlockObject;
        record.Dataset_Key__c = (String) config.get('joinKey');
        record.Folder__c = folder;
        record.Folder_Ref__c = CR_FolderService.resolveFolderId(folder);
        record.Category__c = category;
        record.Is_Public__c = isPublic == true;
        record.Version__c = record.Version__c == null ? 1 : record.Version__c + 1;

        if (reportDefinitionId == null) {
            insert record;
        } else {
            update record;
        }
        return record.Id;
    }

    private static String inferFirstBlockObject(Map<String, Object> config) {
        List<Object> blocks = config.get('blocks') instanceof List<Object>
            ? (List<Object>) config.get('blocks')
            : new List<Object>();
        if (blocks.isEmpty()) return null;
        Map<String, Object> firstBlock = blocks[0] instanceof Map<String, Object>
            ? (Map<String, Object>) blocks[0]
            : new Map<String, Object>();
        Object def = firstBlock.get('definition');
        Map<String, Object> defMap = def instanceof Map<String, Object>
            ? (Map<String, Object>) def
            : (def instanceof String ? (Map<String, Object>) JSON.deserializeUntyped((String) def) : new Map<String, Object>());
        Object datasetObj = defMap.get('dataset');
        Map<String, Object> datasetMap = datasetObj instanceof Map<String, Object>
            ? (Map<String, Object>) datasetObj
            : new Map<String, Object>();
        Object obj = datasetMap.get('objectApiName');
        return obj == null ? null : String.valueOf(obj);
    }

    @AuraEnabled
    public static void deleteReport(Id reportDefinitionId) {
        if (reportDefinitionId == null) {
            throw new AuraHandledException('Report Definition Id is required.');
        }
        if (!Schema.sObjectType.Report_Definition__c.isDeletable()) {
            throw new AuraHandledException('You do not have permission to delete reports.');
        }
        List<Report_Definition__c> records = [
            SELECT Id FROM Report_Definition__c WHERE Id = :reportDefinitionId LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('Report not found or already deleted.');
        }
        delete records;
    }

    // Lets the viewer hide New/Edit/Delete when the user is view-only. The Apex
    // save/delete methods enforce this server-side too; this is UX so users
    // don't see buttons that would only error.
    @AuraEnabled(cacheable=true)
    public static Boolean canBuildReports() {
        return Schema.sObjectType.Report_Definition__c.isCreateable();
    }

    @AuraEnabled(cacheable=true)
    public static CR_Types.ReportDefinitionRecord loadReport(Id reportDefinitionId) {
        if (reportDefinitionId == null) {
            throw new AuraHandledException('Report Definition Id is required.');
        }
        Report_Definition__c record = [
            SELECT Id, Name, Dataset_Key__c, Definition_JSON__c, Folder__c, Category__c,
                Is_Public__c, Version__c, Last_Run_At__c, Last_Run_Status__c, Root_Object__c,
                CreatedDate, CreatedBy.Name, Description__c
            FROM Report_Definition__c
            WHERE Id = :reportDefinitionId
            LIMIT 1
        ];
        return toDto(record);
    }

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ReportDefinitionRecord> listReports(String searchTerm) {
        String likeTerm = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';
        List<Report_Definition__c> records = [
            SELECT Id, Name, Dataset_Key__c, Definition_JSON__c, Folder__c, Category__c,
                Is_Public__c, Version__c, Last_Run_At__c, Last_Run_Status__c, Root_Object__c,
                CreatedDate, CreatedBy.Name, Description__c
            FROM Report_Definition__c
            WHERE Name LIKE :likeTerm
            ORDER BY LastModifiedDate DESC
            LIMIT 200
        ];

        List<CR_Types.ReportDefinitionRecord> results = new List<CR_Types.ReportDefinitionRecord>();
        for (Report_Definition__c record : records) {
            results.add(toDto(record));
        }
        return results;
    }

    // Whitelist of sort fields the LWC dropdowns expose. Keep in sync with the
    // SORT_OPTIONS constant in crReportViewer.js. (crJoinedReportViewer
    // deferred to Phase 1.5 — see phase-1.5-deferred/ directory.)
    private static final Set<String> SORTABLE_FIELDS = new Set<String>{
        'Name', 'CreatedDate', 'LastModifiedDate', 'Last_Run_At__c'
    };

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ReportDefinitionRecord> listReportsOrdered(String searchTerm, String sortBy, String sortDir) {
        return queryReportsOrdered(searchTerm, sortBy, sortDir, null);
    }

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ReportDefinitionRecord> listJoinedReportsOrdered(String searchTerm, String sortBy, String sortDir) {
        return queryReportsOrdered(searchTerm, sortBy, sortDir, 'Joined');
    }

    private static List<CR_Types.ReportDefinitionRecord> queryReportsOrdered(
        String searchTerm,
        String sortBy,
        String sortDir,
        String reportTypeFilter
    ) {
        String likeTerm = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';
        String orderField = SORTABLE_FIELDS.contains(sortBy) ? sortBy : 'LastModifiedDate';
        String orderDirection = String.isNotBlank(sortDir) && sortDir.equalsIgnoreCase('ASC') ? 'ASC' : 'DESC';
        // Last_Run_At__c can be null for never-run reports; push nulls last so the
        // "Recently Run" sort doesn't bury freshly run reports under unrun ones.
        String nullsClause = orderField == 'Last_Run_At__c' ? ' NULLS LAST' : '';

        String typeClause = String.isBlank(reportTypeFilter) ? '' : ' AND Report_Type__c = :reportTypeFilter';
        String soql =
            'SELECT Id, Name, Dataset_Key__c, Definition_JSON__c, Folder__c, Category__c,'
            + ' Is_Public__c, Version__c, Last_Run_At__c, Last_Run_Status__c, Root_Object__c,'
            + ' CreatedDate, CreatedBy.Name, Description__c'
            + ' FROM Report_Definition__c'
            + ' WHERE Name LIKE :likeTerm' + typeClause
            + ' ORDER BY ' + orderField + ' ' + orderDirection + nullsClause
            + ' LIMIT 200';

        List<Report_Definition__c> records = Database.query(soql);
        List<CR_Types.ReportDefinitionRecord> results = new List<CR_Types.ReportDefinitionRecord>();
        for (Report_Definition__c record : records) {
            results.add(toDto(record));
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ReportDefinitionRecord> listJoinedReports(String searchTerm) {
        String likeTerm = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';
        List<Report_Definition__c> records = [
            SELECT Id, Name, Dataset_Key__c, Definition_JSON__c, Folder__c, Category__c,
                Is_Public__c, Version__c, Last_Run_At__c, Last_Run_Status__c, Root_Object__c,
                CreatedDate, CreatedBy.Name, Description__c
            FROM Report_Definition__c
            WHERE Name LIKE :likeTerm AND Report_Type__c = 'Joined'
            ORDER BY LastModifiedDate DESC
            LIMIT 200
        ];

        List<CR_Types.ReportDefinitionRecord> results = new List<CR_Types.ReportDefinitionRecord>();
        for (Report_Definition__c record : records) {
            results.add(toDto(record));
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.DatasetOption> listDatasets() {
        List<CR_Types.DatasetOption> options = new List<CR_Types.DatasetOption>();
        for (CR_Dataset__mdt metadata : [
            SELECT DeveloperName, MasterLabel, Description__c, SObject_API_Name__c, Mode__c
            FROM CR_Dataset__mdt
            ORDER BY MasterLabel
        ]) {
            CR_Types.DatasetOption option = new CR_Types.DatasetOption();
            option.datasetKey = metadata.DeveloperName;
            option.label = metadata.MasterLabel;
            option.description = metadata.Description__c;
            option.sobjectApiName = metadata.SObject_API_Name__c;
            option.mode = String.isBlank(metadata.Mode__c) ? 'hybrid' : metadata.Mode__c;
            options.add(option);
        }
        return options;
    }

    private static CR_Types.ReportDefinitionRecord toDto(Report_Definition__c record) {
        CR_Types.ReportDefinitionRecord dto = new CR_Types.ReportDefinitionRecord();
        dto.id = record.Id;
        dto.name = record.Name;
        dto.datasetKey = record.Dataset_Key__c;
        dto.definitionJson = record.Definition_JSON__c;
        dto.folder = record.Folder__c;
        dto.category = record.Category__c;
        dto.isPublic = record.Is_Public__c;
        dto.version = record.Version__c;
        dto.lastRunAt = record.Last_Run_At__c;
        dto.lastRunStatus = record.Last_Run_Status__c;
        dto.rootObject = record.Root_Object__c;
        dto.createdByName = record.CreatedBy == null ? null : record.CreatedBy.Name;
        dto.createdDate = record.CreatedDate;
        dto.description = record.Description__c;
        return dto;
    }

    // Reject saves whose Name collides with another Report_Definition__c. Single
    // namespace across Tabular/Summary/Matrix/Joined — users shouldn't have to
    // remember which type a report was saved as. Developer_Name__c has a unique
    // schema constraint but normalizeDeveloperName appends a random suffix that
    // defeats it, so enforce the rule here instead.
    private static void rejectIfDuplicateName(String name, Id reportDefinitionId) {
        List<Report_Definition__c> existingByName = reportDefinitionId == null
            ? [SELECT Id FROM Report_Definition__c WHERE Name = :name LIMIT 1]
            : [SELECT Id FROM Report_Definition__c WHERE Name = :name AND Id != :reportDefinitionId LIMIT 1];
        if (!existingByName.isEmpty()) {
            throw new AuraHandledException(
                'A report named "' + name + '" already exists. Pick a different name.'
            );
        }
    }

    private static String normalizeDeveloperName(String name) {
        String value = String.isBlank(name) ? 'Custom_Report' : name.replaceAll('[^A-Za-z0-9]+', '_');
        value = value.replaceAll('^_+', '').replaceAll('_+$', '');
        if (String.isBlank(value)) {
            value = 'Custom_Report';
        }
        if (value.length() > 80) {
            value = value.substring(0, 80);
        }
        return value + '_' + String.valueOf(Crypto.getRandomInteger());
    }

    private static String inferRootObject(String definitionJson, String datasetKey) {
        try {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(definitionJson);
            Object dataset = definition.get('dataset');
            if (dataset instanceof Map<String, Object>) {
                Map<String, Object> datasetMap = (Map<String, Object>) dataset;
                for (String key : new List<String>{ 'primaryObject', 'objectApiName', 'factObject' }) {
                    Object value = datasetMap.get(key);
                    if (value != null && !String.isBlank(String.valueOf(value))) {
                        return String.valueOf(value);
                    }
                }
            }
        } catch (Exception ex) {
            return datasetKey;
        }
        return datasetKey;
    }
}