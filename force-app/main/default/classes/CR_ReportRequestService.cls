/**
 * Report Request workflow: users (Custom_Reporting_User) submit a request for a new
 * report by picking an allowlisted object + fields + filters; admins are notified
 * (bell + email), triage from a worklist, optionally one-click "Build from request"
 * (creates a draft Report_Definition__c the Report Builder hydrates), and on Completion
 * the finished report is auto-shared to the requester's folder.
 *
 * Admin entry points gate on the Manage_Report_Requests custom permission. Notifications
 * are fail-soft: a notification/email failure never blocks the underlying DML.
 */
public with sharing class CR_ReportRequestService {

    private static final String NOTIF_TYPE = 'Vital_Reports_Report_Request';
    private static final String ADMIN_PERMSET = 'Custom_Reporting_Admin';

    // ---------- Requester (any user with object access) ----------

    @AuraEnabled
    public static Id submitRequest(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No request data provided.');
        }
        RequestInput input = (RequestInput) JSON.deserialize(payloadJson, RequestInput.class);
        if (String.isBlank(input.requestedObject)) {
            throw new AuraHandledException('Pick an object/dataset for the report.');
        }
        CR_Report_Request__c req = new CR_Report_Request__c(
            Status__c = 'New',
            Priority__c = String.isBlank(input.priority) ? 'Normal' : input.priority,
            Requested_Object__c = input.requestedObject,
            Dataset_Key__c = input.datasetKey,
            Dataset_JSON__c = input.datasetJson,
            Filters_JSON__c = input.filtersJson,
            Fields_Summary__c = input.fieldsSummary,
            Report_Title__c = input.reportTitle,
            Description__c = input.description
        );
        try {
            insert req;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        // Re-query so the auto-number Name (RR-#####) is populated — it isn't on the
        // in-memory record right after insert, which made the admin bell read "null".
        req = [
            SELECT Id, Name, Report_Title__c, Requested_Object__c, OwnerId
            FROM CR_Report_Request__c WHERE Id = :req.Id LIMIT 1
        ];
        notifyAdmins(req);
        return req.Id;
    }

    @AuraEnabled
    public static List<RequestDto> listMyRequests() {
        List<RequestDto> out = new List<RequestDto>();
        for (CR_Report_Request__c r : [
            SELECT Id, Name, Status__c, Priority__c, Requested_Object__c, Report_Title__c,
                   Fields_Summary__c, Description__c, Admin_Notes__c, Resulting_Report__c,
                   Resulting_Report__r.Name, CreatedDate
            FROM CR_Report_Request__c
            WHERE OwnerId = :UserInfo.getUserId()
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]) {
            out.add(toDto(r));
        }
        return out;
    }

    // ---------- Admin (Manage_Report_Requests) ----------

    @AuraEnabled
    public static List<RequestDto> listAllRequests() {
        assertManage();
        List<RequestDto> out = new List<RequestDto>();
        for (CR_Report_Request__c r : [
            SELECT Id, Name, Status__c, Priority__c, Requested_Object__c, Report_Title__c,
                   Fields_Summary__c, Filters_JSON__c, Description__c, Admin_Notes__c,
                   Resulting_Report__c, Resulting_Report__r.Name, OwnerId, Owner.Name, CreatedDate
            FROM CR_Report_Request__c
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            RequestDto d = toDto(r);
            d.requesterName = (r.Owner != null) ? r.Owner.Name : null;
            d.filtersJson = r.Filters_JSON__c;
            out.add(d);
        }
        return out;
    }

    @AuraEnabled
    public static void updateStatus(Id requestId, String status, String adminNotes) {
        assertManage();
        if (requestId == null || String.isBlank(status)) {
            throw new AuraHandledException('Request Id and status are required.');
        }
        CR_Report_Request__c req = [
            SELECT Id, Name, Status__c, OwnerId, Report_Title__c, Requested_Object__c,
                   Resulting_Report__c, Admin_Notes__c
            FROM CR_Report_Request__c WHERE Id = :requestId LIMIT 1
        ];
        req.Status__c = status;
        if (adminNotes != null) {
            req.Admin_Notes__c = adminNotes;
        }
        update req;

        if (status == 'Completed') {
            if (req.Resulting_Report__c != null) {
                autoShareToRequester(req.Resulting_Report__c, req.OwnerId);
            }
            notifyRequester(req, 'completed');
        } else if (status == 'Rejected') {
            notifyRequester(req, 'rejected');
        }
    }

    // Link an already-built report to the request (admin attaches their work).
    @AuraEnabled
    public static void linkReport(Id requestId, Id reportDefinitionId) {
        assertManage();
        update new CR_Report_Request__c(Id = requestId, Resulting_Report__c = reportDefinitionId);
    }

    // One-click "Build from request": create a draft Report_Definition__c from the
    // request's captured dataset/fields/filters, link it, flip to In Progress, and
    // return the new report Id so the LWC can open the Report Builder on it
    // (?c__reportId=...). The builder hydrates the draft like any saved report.
    @AuraEnabled
    public static Id buildFromRequest(Id requestId) {
        assertManage();
        CR_Report_Request__c req = [
            SELECT Id, Report_Title__c, Requested_Object__c, Dataset_Key__c,
                   Dataset_JSON__c, Filters_JSON__c, Resulting_Report__c, Status__c
            FROM CR_Report_Request__c WHERE Id = :requestId LIMIT 1
        ];
        if (req.Resulting_Report__c != null) {
            // Already built — just return the existing draft.
            return req.Resulting_Report__c;
        }
        if (String.isBlank(req.Dataset_JSON__c)) {
            throw new AuraHandledException('This request has no captured dataset to build from.');
        }
        Map<String, Object> datasetDef;
        try {
            datasetDef = (Map<String, Object>) JSON.deserializeUntyped(req.Dataset_JSON__c);
        } catch (Exception e) {
            throw new AuraHandledException('The request dataset could not be parsed.');
        }

        String rootObject = str(datasetDef.get('primaryObject'));
        if (String.isBlank(rootObject)) rootObject = str(datasetDef.get('objectApiName'));

        String definitionJson = assembleDefinitionJson(datasetDef, req.Filters_JSON__c);

        String title = String.isBlank(req.Report_Title__c)
            ? 'Requested report (' + req.Requested_Object__c + ')'
            : req.Report_Title__c;

        Report_Definition__c rd = new Report_Definition__c(
            Name = title.length() > 80 ? title.substring(0, 80) : title,
            Developer_Name__c = 'ReqRpt_' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            Root_Object__c = rootObject,
            Dataset_Key__c = req.Dataset_Key__c,
            Definition_JSON__c = definitionJson,
            Category__c = 'Requested',
            Is_Public__c = false,
            Version__c = 1
        );
        try {
            insert rd;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        req.Resulting_Report__c = rd.Id;
        if (req.Status__c == 'New') req.Status__c = 'In Progress';
        update req;
        return rd.Id;
    }

    // ---------- helpers ----------

    private static void assertManage() {
        if (!FeatureManagement.checkPermission('Manage_Report_Requests')) {
            throw new AuraHandledException('You do not have permission to manage report requests.');
        }
    }

    private static RequestDto toDto(CR_Report_Request__c r) {
        RequestDto d = new RequestDto();
        d.id = r.Id;
        d.name = r.Name;
        d.status = r.Status__c;
        d.priority = r.Priority__c;
        d.requestedObject = r.Requested_Object__c;
        d.reportTitle = r.Report_Title__c;
        d.fieldsSummary = r.Fields_Summary__c;
        d.description = r.Description__c;
        d.adminNotes = r.Admin_Notes__c;
        d.resultingReportId = r.Resulting_Report__c;
        d.resultingReportName = (r.Resulting_Report__r != null) ? r.Resulting_Report__r.Name : null;
        d.createdDate = r.CreatedDate;
        return d;
    }

    // Wrap the captured dataset definition + filters in the report-definition envelope
    // the Report Builder / CR_QueryEngine understand.
    private static String assembleDefinitionJson(Map<String, Object> datasetDef, String filtersJson) {
        List<Object> fields = new List<Object>();
        Object fieldPathsObj = datasetDef.get('fieldPaths');
        Map<String, Object> labels = datasetDef.get('fieldLabels') instanceof Map<String, Object>
            ? (Map<String, Object>) datasetDef.get('fieldLabels') : new Map<String, Object>();
        if (fieldPathsObj instanceof List<Object>) {
            for (Object p : (List<Object>) fieldPathsObj) {
                String path = String.valueOf(p);
                fields.add(new Map<String, Object>{
                    'path' => path,
                    'label' => labels.containsKey(path) ? labels.get(path) : path
                });
            }
        }
        Object filters;
        try {
            filters = String.isBlank(filtersJson) ? new List<Object>() : JSON.deserializeUntyped(filtersJson);
        } catch (Exception e) {
            filters = new List<Object>();
        }
        Map<String, Object> def = new Map<String, Object>{
            'dataset' => datasetDef,
            'fields' => fields,
            'filters' => filters,
            'groupings' => new List<Object>(),
            'aggregations' => new List<Object>(),
            'formulas' => new List<Object>(),
            'summaryFormulas' => new List<Object>(),
            'buckets' => new List<Object>(),
            'sort' => new List<Object>{ new Map<String, Object>{ 'field' => 'Id', 'direction' => 'ASC' } },
            'pagination' => new Map<String, Object>{ 'pageSize' => 100, 'strategy' => 'keyset' },
            'chart' => new Map<String, Object>{ 'type' => 'bar' },
            'drillDown' => new Map<String, Object>{ 'enabled' => true }
        };
        return JSON.serialize(def);
    }

    // Grant the requester direct access to the finished report via a managed share, so
    // they can open/run it without moving it out of the folder the admin chose. OWD on
    // Report_Definition__c is Public Read Only, so only an Edit share exceeds the default
    // (a Read share would be rejected). Fail-soft + allOrNone=false: a duplicate/own-record
    // share never blocks completion.
    private static void autoShareToRequester(Id reportId, Id requesterId) {
        if (reportId == null || requesterId == null) return;
        try {
            Database.insert(new List<Report_Definition__Share>{
                new Report_Definition__Share(
                    ParentId = reportId,
                    UserOrGroupId = requesterId,
                    AccessLevel = 'Edit',
                    RowCause = 'Manual'
                )
            }, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CR_ReportRequestService autoshare suppressed: ' + e.getMessage());
        }
    }

    private static void notifyAdmins(CR_Report_Request__c req) {
        Set<Id> adminIds = resolveAdminUserIds();
        if (adminIds.isEmpty()) return;
        String title = 'New report request: ' + req.Name;
        String body = (String.isBlank(req.Report_Title__c) ? req.Requested_Object__c : req.Report_Title__c)
            + ' — requested by ' + UserInfo.getName();
        sendBell(adminIds, title, body, req.Id);
        sendEmails(emailsForUsers(adminIds), title, body
            + '\n\nOpen Manage Report Requests in Vital Reports to triage.');
    }

    private static void notifyRequester(CR_Report_Request__c req, String kind) {
        if (req.OwnerId == null) return;
        Boolean done = kind == 'completed';
        String title = done
            ? 'Your report request is ready: ' + req.Name
            : 'Your report request was not approved: ' + req.Name;
        String body = done
            ? 'The reporting team completed "' + (String.isBlank(req.Report_Title__c) ? req.Requested_Object__c : req.Report_Title__c) + '".'
                + (String.isBlank(req.Admin_Notes__c) ? '' : ' Note: ' + req.Admin_Notes__c)
            : 'Request ' + req.Name + ' was rejected.'
                + (String.isBlank(req.Admin_Notes__c) ? '' : ' Reason: ' + req.Admin_Notes__c);
        sendBell(new Set<Id>{ req.OwnerId }, title, body, req.Id);
        sendEmails(emailsForUsers(new Set<Id>{ req.OwnerId }), title, body);
    }

    private static Set<Id> resolveAdminUserIds() {
        Set<Id> ids = new Set<Id>();
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSet.Name = :ADMIN_PERMSET AND Assignee.IsActive = true
        ]) {
            ids.add(a.AssigneeId);
        }
        return ids;
    }

    private static List<String> emailsForUsers(Set<Id> userIds) {
        List<String> emails = new List<String>();
        for (User u : [SELECT Email FROM User WHERE Id IN :userIds AND IsActive = true AND Email != null]) {
            emails.add(u.Email);
        }
        return emails;
    }

    private static void sendBell(Set<Id> userIds, String title, String body, Id targetId) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIF_TYPE LIMIT 1
            ];
            if (types.isEmpty() || userIds.isEmpty()) return;
            Set<String> recipients = new Set<String>();
            for (Id uid : userIds) recipients.add(String.valueOf(uid));
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setTitle(title);
            n.setBody(body == null ? '' : (body.length() > 750 ? body.substring(0, 750) : body));
            n.setNotificationTypeId(types[0].Id);
            n.setTargetId(targetId);
            n.send(recipients);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CR_ReportRequestService bell suppressed: ' + e.getMessage());
        }
    }

    private static void sendEmails(List<String> toAddresses, String subject, String body) {
        if (toAddresses == null || toAddresses.isEmpty()) return;
        try {
            List<Messaging.SingleEmailMessage> msgs = new List<Messaging.SingleEmailMessage>();
            for (String addr : toAddresses) {
                Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
                m.setToAddresses(new List<String>{ addr });
                m.setSubject(subject);
                m.setPlainTextBody(body);
                m.setSaveAsActivity(false);
                msgs.add(m);
            }
            Messaging.sendEmail(msgs, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CR_ReportRequestService email suppressed: ' + e.getMessage());
        }
    }

    private static String str(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    // ---------- DTOs ----------
    public class RequestInput {
        public String reportTitle;
        public String requestedObject;
        public String datasetKey;
        public String datasetJson;
        public String filtersJson;
        public String fieldsSummary;
        public String description;
        public String priority;
    }

    public class RequestDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String priority;
        @AuraEnabled public String requestedObject;
        @AuraEnabled public String reportTitle;
        @AuraEnabled public String fieldsSummary;
        @AuraEnabled public String filtersJson;
        @AuraEnabled public String description;
        @AuraEnabled public String adminNotes;
        @AuraEnabled public String requesterName;
        @AuraEnabled public Id resultingReportId;
        @AuraEnabled public String resultingReportName;
        @AuraEnabled public Datetime createdDate;
    }
}