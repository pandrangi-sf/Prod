// Admin-facing CRUD + connection test for AI provider configuration. Reads
// and writes CR_AI_Provider__c (runtime data, admin-editable via the Manage
// AI Providers tab). Mirrors the CR_HomeTileService pattern.
//
// The actual API key never lives here — it's stored in a Salesforce Named
// Credential whose name this object references. testConnection() does a one-
// token probe against the provider so admins can confirm the credential works.
public with sharing class CR_AIProviderService {

    public class AdminProvider {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String provider { get; set; }
        @AuraEnabled public String model { get; set; }
        @AuraEnabled public Integer maxTokens { get; set; }
        @AuraEnabled public String namedCredential { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
        @AuraEnabled public Boolean isDefault { get; set; }
    }

    public class TestResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public Integer status { get; set; }
        @AuraEnabled public String model { get; set; }
    }

    @TestVisible private static final String MANAGE_PERMISSION_API_NAME = 'Manage_AI_Providers';
    @TestVisible private static final Integer PROBE_MAX_TOKENS = 1;
    @TestVisible private static final String ANTHROPIC_VERSION = '2023-06-01';

    @AuraEnabled(cacheable=true)
    public static Boolean canManageProviders() {
        return FeatureManagement.checkPermission(MANAGE_PERMISSION_API_NAME);
    }

    @AuraEnabled
    public static List<AdminProvider> listProviders() {
        assertManage();
        List<AdminProvider> out = new List<AdminProvider>();
        for (CR_AI_Provider__c p : [
            SELECT Id, Name, Provider__c, Model__c, Max_Tokens__c,
                   Named_Credential_Name__c, Is_Active__c, Is_Default__c
            FROM CR_AI_Provider__c
            ORDER BY Is_Default__c DESC, Is_Active__c DESC, Name
        ]) {
            AdminProvider a = new AdminProvider();
            a.id = p.Id;
            a.label = p.Name;
            a.provider = p.Provider__c;
            a.model = p.Model__c;
            a.maxTokens = p.Max_Tokens__c == null ? null : p.Max_Tokens__c.intValue();
            a.namedCredential = p.Named_Credential_Name__c;
            a.isActive = p.Is_Active__c;
            a.isDefault = p.Is_Default__c;
            out.add(a);
        }
        return out;
    }

    @AuraEnabled
    public static Id saveProvider(String payloadJson) {
        assertManage();
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No provider data provided.');
        }
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        String label = (String) m.get('label');
        if (String.isBlank(label)) {
            throw new AuraHandledException('Provider name is required.');
        }
        CR_AI_Provider__c p = new CR_AI_Provider__c();
        String idStr = (String) m.get('id');
        if (String.isNotBlank(idStr)) {
            p.Id = (Id) idStr;
        }
        p.Name = label.left(80);
        String provider = (String) m.get('provider');
        p.Provider__c = String.isBlank(provider) ? 'Anthropic' : provider;
        p.Model__c = (String) m.get('model');
        p.Named_Credential_Name__c = (String) m.get('namedCredential');
        Object maxTok = m.get('maxTokens');
        p.Max_Tokens__c = (maxTok == null || String.isBlank(String.valueOf(maxTok)))
            ? null
            : Decimal.valueOf(String.valueOf(maxTok));
        Object active = m.get('isActive');
        p.Is_Active__c = active == null ? true : Boolean.valueOf(String.valueOf(active));
        Object dflt = m.get('isDefault');
        p.Is_Default__c = dflt == null ? false : Boolean.valueOf(String.valueOf(dflt));

        // If this record is being marked default, clear the flag on others so
        // exactly one record carries it. Same pattern admins expect from
        // "default" toggles on any config object.
        if (p.Is_Default__c) {
            List<CR_AI_Provider__c> others = [
                SELECT Id, Is_Default__c FROM CR_AI_Provider__c
                WHERE Is_Default__c = true AND Id != :p.Id
            ];
            for (CR_AI_Provider__c o : others) {
                o.Is_Default__c = false;
            }
            if (!others.isEmpty()) {
                update others;
            }
        }
        upsert p;
        return p.Id;
    }

    @AuraEnabled
    public static void deleteProvider(Id providerId) {
        assertManage();
        if (providerId == null) {
            throw new AuraHandledException('Provider Id is required.');
        }
        delete [SELECT Id FROM CR_AI_Provider__c WHERE Id = :providerId];
    }

    // Sends a 1-token probe to the provider's chat endpoint via its Named
    // Credential. Returns the result instead of throwing so the UI can show a
    // green / red badge without try/catch boilerplate.
    @AuraEnabled
    public static TestResult testConnection(Id providerId) {
        assertManage();
        TestResult r = new TestResult();
        if (providerId == null) {
            r.success = false;
            r.message = 'Provider Id is required.';
            return r;
        }
        CR_AI_Provider__c p = [
            SELECT Provider__c, Model__c, Named_Credential_Name__c
            FROM CR_AI_Provider__c WHERE Id = :providerId LIMIT 1
        ];
        r.model = p.Model__c;
        if (String.isBlank(p.Named_Credential_Name__c)) {
            r.success = false;
            r.message = 'No Named Credential set on this provider. Create one in Setup, then paste its name here.';
            return r;
        }
        if (p.Provider__c != 'Anthropic') {
            r.success = false;
            r.message = 'Only Anthropic is wired up today.';
            return r;
        }
        try {
            HttpResponse res = sendAnthropicProbe(p.Named_Credential_Name__c, p.Model__c);
            r.status = res.getStatusCode();
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                r.success = true;
                r.message = 'Connected — model "' + p.Model__c + '" responded successfully.';
            } else {
                r.success = false;
                r.message = 'HTTP ' + res.getStatusCode() + ': ' + truncate(res.getBody(), 300);
            }
        } catch (Exception e) {
            r.success = false;
            r.message = 'Callout failed: ' + e.getMessage();
        }
        return r;
    }

    @TestVisible
    private static HttpResponse sendAnthropicProbe(String namedCredName, String model) {
        Map<String, Object> body = new Map<String, Object>{
            'model' => String.isBlank(model) ? 'claude-haiku-4-5-20251001' : model,
            'max_tokens' => PROBE_MAX_TOKENS,
            'messages' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => 'ping' }
            }
        };
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredName + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-version', ANTHROPIC_VERSION);
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000);
        return new Http().send(req);
    }

    // Idempotent seed from the legacy CR_AI_Settings__mdt 'Default' record into
    // CR_AI_Provider__c. Runs in deployed-Apex (system) context so it works
    // regardless of the caller's FLS — same trick as CR_HomeTileService.seedFromCatalog().
    public static Integer seedFromSettings() {
        List<CR_AI_Settings__mdt> cmt = [
            SELECT Provider__c, Model__c, Max_Tokens__c, Named_Credential__c
            FROM CR_AI_Settings__mdt WHERE DeveloperName = 'Default' LIMIT 1
        ];
        if (cmt.isEmpty()) {
            return 0;
        }
        CR_AI_Settings__mdt s = cmt[0];
        List<CR_AI_Provider__c> existing = [
            SELECT Id FROM CR_AI_Provider__c WHERE Name = 'Default (from CMT)' LIMIT 1
        ];
        CR_AI_Provider__c p = existing.isEmpty() ? new CR_AI_Provider__c() : existing[0];
        p.Name = 'Default (from CMT)';
        p.Provider__c = String.isBlank(s.Provider__c) ? 'Anthropic' : s.Provider__c;
        p.Model__c = s.Model__c;
        p.Max_Tokens__c = s.Max_Tokens__c;
        p.Named_Credential_Name__c = s.Named_Credential__c;
        p.Is_Active__c = true;
        p.Is_Default__c = true;
        upsert p;
        return 1;
    }

    private static void assertManage() {
        if (!FeatureManagement.checkPermission(MANAGE_PERMISSION_API_NAME)) {
            throw new AuraHandledException('You do not have permission to manage AI providers.');
        }
    }

    private static String truncate(String s, Integer max) {
        if (s == null) return '';
        return s.length() > max ? s.substring(0, max) + '…' : s;
    }
}