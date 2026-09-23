/**
 * Field visit capture assistant. A rep dictates what happened after a provider
 * visit; Claude turns that into a structured Visit_Report__c draft which the rep
 * reviews and saves. Nothing is written until saveVisit() is called explicitly.
 *
 * The draft is produced with structured outputs: the JSON Schema sent to the model
 * is built from this org's own picklists and Objection__c / Service__c /
 * Collateral__c catalogs, so the model can only return values that already exist
 * here. That removes the usual free-text-to-picklist mapping problem.
 *
 * Reuses the CR_AI_Provider__c + Named Credential configuration that
 * CR_AIProviderService administers; the API key never leaves the Named Credential.
 */
public with sharing class CR_FieldAssistant {

    private static final String ANTHROPIC_VERSION = '2023-06-01';
    private static final String DEFAULT_MODEL = 'claude-opus-5';
    private static final Integer DEFAULT_MAX_TOKENS = 4096;

    // ---------- DTOs ----------

    public class ProviderOption {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
    }

    public class CatalogEntry {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
    }

    public class Catalog {
        @AuraEnabled public List<String> visitTypes { get; set; }
        @AuraEnabled public List<String> categories { get; set; }
        @AuraEnabled public List<String> purposes { get; set; }
        @AuraEnabled public List<String> audiences { get; set; }
        @AuraEnabled public List<String> mealOptions { get; set; }
        @AuraEnabled public List<CatalogEntry> objections { get; set; }
        @AuraEnabled public List<CatalogEntry> services { get; set; }
        @AuraEnabled public List<CatalogEntry> collateral { get; set; }
        @AuraEnabled public List<CatalogEntry> recordTypes { get; set; }
        @AuraEnabled public Boolean aiConfigured { get; set; }
    }

    public class DraftObjection {
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String comments { get; set; }
    }

    public class VisitDraft {
        @AuraEnabled public String subject { get; set; }
        @AuraEnabled public String visitDate { get; set; }
        @AuraEnabled public String visitType { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public String purpose { get; set; }
        @AuraEnabled public String audience { get; set; }
        @AuraEnabled public String notes { get; set; }
        @AuraEnabled public Boolean leftVoicemail { get; set; }
        @AuraEnabled public String mealWithVisit { get; set; }
        @AuraEnabled public Boolean tandemVisit { get; set; }
        @AuraEnabled public String providerName { get; set; }
        @AuraEnabled public List<DraftObjection> objections { get; set; }
        @AuraEnabled public List<String> services { get; set; }
        @AuraEnabled public List<String> collateral { get; set; }
        @AuraEnabled public List<String> confidenceNotes { get; set; }
    }

    public class SaveResult {
        @AuraEnabled public Id visitReportId { get; set; }
        @AuraEnabled public Id taskId { get; set; }
        @AuraEnabled public Integer objectionsCreated { get; set; }
        @AuraEnabled public Integer servicesCreated { get; set; }
        @AuraEnabled public Integer collateralCreated { get; set; }
    }

    // ---------- catalog ----------

    @AuraEnabled(cacheable=true)
    public static Catalog getCatalog() {
        Catalog c = new Catalog();
        c.visitTypes = picklistValues(Visit_Report__c.Visit_Type__c);
        c.categories = picklistValues(Visit_Report__c.Category__c);
        c.purposes = picklistValues(Visit_Report__c.Purpose__c);
        c.audiences = picklistValues(Visit_Report__c.Audience__c);
        c.mealOptions = picklistValues(Visit_Report__c.Meal_With_Visit__c);
        c.objections = entries([SELECT Id, Name FROM Objection__c ORDER BY Name LIMIT 500]);
        c.services = entries([SELECT Id, Name FROM Service__c ORDER BY Name LIMIT 500]);
        c.collateral = entries([SELECT Id, Name FROM Collateral__c ORDER BY Name LIMIT 500]);
        c.recordTypes = visitRecordTypes();
        c.aiConfigured = activeProvider() != null;
        return c;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProviderOption> searchProviders(String term) {
        List<ProviderOption> out = new List<ProviderOption>();
        if (String.isBlank(term) || term.length() < 2) {
            return out;
        }
        String likeTerm = '%' + String.escapeSingleQuotes(term.trim()) + '%';
        for (Contact ct : [SELECT Id, Name FROM Contact WHERE Name LIKE :likeTerm ORDER BY Name LIMIT 20]) {
            ProviderOption p = new ProviderOption();
            p.id = ct.Id;
            p.name = ct.Name;
            out.add(p);
        }
        return out;
    }

    private static List<String> picklistValues(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }

    /**
     * Visit_Report__c picklists are scoped by record type: a value that describe()
     * reports as valid is still rejected on insert if the record type excludes it.
     * The rep picks a record type, and saveVisit() always sets one.
     */
    private static List<CatalogEntry> visitRecordTypes() {
        List<CatalogEntry> out = new List<CatalogEntry>();
        for (Schema.RecordTypeInfo rt : Visit_Report__c.SObjectType.getDescribe().getRecordTypeInfos()) {
            if (rt.isAvailable() && !rt.isMaster()) {
                CatalogEntry e = new CatalogEntry();
                e.id = rt.getRecordTypeId();
                e.name = rt.getName();
                out.add(e);
            }
        }
        return out;
    }

    private static List<CatalogEntry> entries(List<SObject> rows) {
        List<CatalogEntry> out = new List<CatalogEntry>();
        for (SObject row : rows) {
            CatalogEntry e = new CatalogEntry();
            e.id = (Id) row.get('Id');
            e.name = (String) row.get('Name');
            out.add(e);
        }
        return out;
    }

    // ---------- extraction ----------

    @AuraEnabled
    public static VisitDraft extractVisit(String transcript) {
        if (String.isBlank(transcript)) {
            throw new AuraHandledException('Nothing was dictated.');
        }
        CR_AI_Provider__c cfg = activeProvider();
        if (cfg == null) {
            throw new AuraHandledException(
                'No active AI provider is configured. Add a CR_AI_Provider__c record ' +
                'pointing at a Named Credential before using the assistant.'
            );
        }

        Catalog c = getCatalog();
        String responseText = callAnthropic(cfg, systemPrompt(), transcript, schemaFor(c));
        return parseDraft(responseText);
    }

    @TestVisible
    private static String systemPrompt() {
        return
            'You turn a field representative\'s spoken recap of a provider visit into a ' +
            'structured visit report for a healthcare provider relations team.\n\n' +
            'Rules:\n' +
            '- Only use values supplied by the response schema. Never invent an objection, ' +
            'service or collateral name.\n' +
            '- Record only what the rep actually said. Do not infer an objection from a ' +
            'neutral remark, and leave lists empty when nothing was mentioned.\n' +
            '- notes: a tidied version of what the rep said, in their own words. Do not ' +
            'summarise away specifics such as names, dates, numbers or commitments.\n' +
            '- subject: a short title, e.g. "Quarterly meeting - Dr. Patel".\n' +
            '- visitDate: ISO yyyy-MM-dd. Resolve relative dates against today. If no date ' +
            'was stated, use today.\n' +
            '- providerName: the provider as the rep named them, or null if unnamed. Do not ' +
            'guess a full name from a partial one.\n' +
            '- confidenceNotes: anything you were unsure about, so the rep can check it ' +
            'before saving. Empty when everything was clear.';
    }

    /**
     * JSON Schema for the draft, with enums drawn from this org's own values so the
     * model cannot return anything that would fail on save. A catalog with no records
     * degrades to a plain string rather than an empty enum, which is invalid schema.
     */
    @TestVisible
    private static Map<String, Object> schemaFor(Catalog c) {
        Map<String, Object> props = new Map<String, Object>{
            'subject' => type('string'),
            'visitDate' => nullableString(),
            'visitType' => enumOrString(c.visitTypes),
            'category' => enumOrString(c.categories),
            'purpose' => enumOrString(c.purposes),
            'audience' => enumOrString(c.audiences),
            'notes' => type('string'),
            'leftVoicemail' => type('boolean'),
            'mealWithVisit' => enumOrString(c.mealOptions),
            'tandemVisit' => type('boolean'),
            'providerName' => nullableString(),
            'objections' => new Map<String, Object>{
                'type' => 'array',
                'items' => new Map<String, Object>{
                    'type' => 'object',
                    'additionalProperties' => false,
                    'required' => new List<String>{ 'name', 'comments' },
                    'properties' => new Map<String, Object>{
                        'name' => enumOrString(names(c.objections)),
                        'comments' => nullableString()
                    }
                }
            },
            'services' => arrayOf(enumOrString(names(c.services))),
            'collateral' => arrayOf(enumOrString(names(c.collateral))),
            'confidenceNotes' => arrayOf(type('string'))
        };

        return new Map<String, Object>{
            'type' => 'object',
            'additionalProperties' => false,
            'required' => new List<String>(props.keySet()),
            'properties' => props
        };
    }

    private static List<String> names(List<CatalogEntry> rows) {
        List<String> out = new List<String>();
        for (CatalogEntry e : rows) {
            out.add(e.name);
        }
        return out;
    }

    private static Map<String, Object> type(String t) {
        return new Map<String, Object>{ 'type' => t };
    }

    private static Map<String, Object> nullableString() {
        return new Map<String, Object>{ 'type' => new List<String>{ 'string', 'null' } };
    }

    private static Map<String, Object> arrayOf(Map<String, Object> items) {
        return new Map<String, Object>{ 'type' => 'array', 'items' => items };
    }

    private static Map<String, Object> enumOrString(List<String> values) {
        if (values == null || values.isEmpty()) {
            return type('string');
        }
        return new Map<String, Object>{ 'enum' => values };
    }

    // ---------- callout ----------

    @TestVisible
    private static CR_AI_Provider__c activeProvider() {
        List<CR_AI_Provider__c> rows = [
            SELECT Id, Provider__c, Model__c, Max_Tokens__c, Named_Credential_Name__c
            FROM CR_AI_Provider__c
            WHERE Is_Active__c = true AND Provider__c != 'Disabled'
            ORDER BY Is_Default__c DESC, Name
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Named_Credential_Name__c)) {
            return null;
        }
        return rows[0];
    }

    @TestVisible
    private static String callAnthropic(
        CR_AI_Provider__c cfg,
        String systemText,
        String userContent,
        Map<String, Object> schema
    ) {
        Integer maxTokens = (cfg.Max_Tokens__c == null)
            ? DEFAULT_MAX_TOKENS
            : cfg.Max_Tokens__c.intValue();
        String model = String.isBlank(cfg.Model__c) ? DEFAULT_MODEL : cfg.Model__c;

        Map<String, Object> body = new Map<String, Object>{
            'model' => model,
            'max_tokens' => maxTokens,
            // Extraction is a shallow task; low effort keeps the rep waiting less.
            'output_config' => new Map<String, Object>{
                'effort' => 'low',
                'format' => new Map<String, Object>{
                    'type' => 'json_schema',
                    'schema' => schema
                }
            },
            // The system block and schema are identical on every call, so caching
            // them keeps the per-call input cost to roughly the transcript alone.
            'system' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => systemText + '\n\nToday is ' + String.valueOf(Date.today()) + '.',
                    'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' }
                }
            },
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => userContent }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.Named_Credential_Name__c + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-version', ANTHROPIC_VERSION);
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        Integer status = res.getStatusCode();
        if (status < 200 || status >= 300) {
            throw new AuraHandledException(
                'AI provider returned HTTP ' + status + ': ' + truncate(res.getBody(), 300)
            );
        }
        return extractText(res.getBody());
    }

    @TestVisible
    private static String extractText(String responseBody) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            // A refusal is an HTTP 200 with no usable content; surface it as itself.
            if ('refusal'.equals(root.get('stop_reason'))) {
                throw new AuraHandledException('The AI provider declined to process that recording.');
            }
            if (root.get('content') instanceof List<Object>) {
                for (Object blk : (List<Object>) root.get('content')) {
                    if (blk instanceof Map<String, Object>) {
                        Map<String, Object> bm = (Map<String, Object>) blk;
                        if ('text'.equals(bm.get('type')) && bm.get('text') != null) {
                            return String.valueOf(bm.get('text'));
                        }
                    }
                }
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            // fall through
        }
        throw new AuraHandledException('AI provider returned an unrecognized response.');
    }

    @TestVisible
    private static VisitDraft parseDraft(String rawJson) {
        try {
            return (VisitDraft) JSON.deserialize(rawJson, VisitDraft.class);
        } catch (Exception e) {
            throw new AuraHandledException('Could not read the drafted visit: ' + e.getMessage());
        }
    }

    // ---------- save ----------

    @AuraEnabled
    public static SaveResult saveVisit(String draftJson, Id providerId, Id recordTypeId) {
        VisitDraft d = parseDraft(draftJson);
        Id rtId = recordTypeId;
        if (rtId == null) {
            List<CatalogEntry> rts = visitRecordTypes();
            if (rts.isEmpty()) {
                throw new AuraHandledException('No Visit Report record type is available to you.');
            }
            rtId = rts[0].id;
        }

        Visit_Report__c vr = new Visit_Report__c(
            RecordTypeId = rtId,
            Subject__c = d.subject,
            Notes__c = d.notes,
            Visit_Type__c = d.visitType,
            Category__c = d.category,
            Purpose__c = d.purpose,
            Audience__c = d.audience,
            Visit_Date__c = parseDate(d.visitDate),
            Left_Voicemail__c = d.leftVoicemail == true,
            Meal_With_Visit__c = d.mealWithVisit,
            Tandem_Visit__c = d.tandemVisit == true
        );
        insert vr;

        SaveResult result = new SaveResult();
        result.visitReportId = vr.Id;
        result.objectionsCreated = 0;
        result.servicesCreated = 0;
        result.collateralCreated = 0;

        // Task is what ties the visit to the provider — Visit_Report__c has no
        // Contact lookup of its own.
        if (providerId != null) {
            Task t = new Task(
                WhoId = providerId,
                Visit_Report__c = vr.Id,
                Subject = String.isBlank(d.subject) ? 'Provider visit' : d.subject,
                ActivityDate = parseDate(d.visitDate),
                Status = 'Completed',
                Description = d.notes
            );
            insert t;
            result.taskId = t.Id;
        }

        List<SObject> children = new List<SObject>();

        if (d.objections != null && !d.objections.isEmpty()) {
            Map<String, Id> byName = idsByName([SELECT Id, Name FROM Objection__c LIMIT 500]);
            for (DraftObjection o : d.objections) {
                Id oid = byName.get(o.name);
                if (oid != null) {
                    children.add(new Visit_Objection__c(
                        Visit_Report__c = vr.Id,
                        Objection__c = oid,
                        Comments__c = o.comments
                    ));
                    result.objectionsCreated++;
                }
            }
        }

        if (d.services != null && !d.services.isEmpty()) {
            Map<String, Id> byName = idsByName([SELECT Id, Name FROM Service__c LIMIT 500]);
            for (String s : d.services) {
                Id sid = byName.get(s);
                if (sid != null) {
                    children.add(new Visit_Service__c(Visit_Report__c = vr.Id, Service__c = sid));
                    result.servicesCreated++;
                }
            }
        }

        if (d.collateral != null && !d.collateral.isEmpty()) {
            Map<String, Id> byName = idsByName([SELECT Id, Name FROM Collateral__c LIMIT 500]);
            for (String col : d.collateral) {
                Id cid = byName.get(col);
                if (cid != null) {
                    children.add(new Visit_Collateral__c(Visit_Report__c = vr.Id, Collateral__c = cid));
                    result.collateralCreated++;
                }
            }
        }

        if (!children.isEmpty()) {
            insert children;
        }
        return result;
    }

    private static Map<String, Id> idsByName(List<SObject> rows) {
        Map<String, Id> out = new Map<String, Id>();
        for (SObject row : rows) {
            out.put((String) row.get('Name'), (Id) row.get('Id'));
        }
        return out;
    }

    private static Date parseDate(String iso) {
        if (String.isBlank(iso)) {
            return Date.today();
        }
        try {
            return Date.valueOf(iso);
        } catch (Exception e) {
            return Date.today();
        }
    }

    private static String truncate(String s, Integer max) {
        if (s == null) {
            return '';
        }
        return s.length() <= max ? s : s.substring(0, max);
    }
}
