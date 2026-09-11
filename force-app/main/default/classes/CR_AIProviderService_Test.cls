@isTest
private class CR_AIProviderService_Test {

    private static User adminUser() {
        User u = baseUser('craiadm');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Custom_Reporting_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    private static User plainUser() {
        return baseUser('craiusr');
    }

    private static User baseUser(String aliasSeed) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crai',
                Email = aliasSeed + '@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'AITester',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = aliasSeed + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    // Tiny Http mock so testConnection() can be exercised without a real
    // callout. Returns 200 with a minimal Anthropic-ish body.
    private class AnthropicOkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody('{"id":"msg_1","model":"claude-test","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"output_tokens":1}}');
            return r;
        }
    }

    private class AnthropicErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(401);
            r.setBody('{"error":{"message":"invalid api key"}}');
            return r;
        }
    }

    @isTest
    static void adminCanCrudProviders() {
        User admin = adminUser();
        Test.startTest();
        System.runAs(admin) {
            System.assertEquals(true, CR_AIProviderService.canManageProviders());

            Id id = CR_AIProviderService.saveProvider(JSON.serialize(new Map<String, Object>{
                'label' => 'Anthropic Prod',
                'provider' => 'Anthropic',
                'model' => 'claude-sonnet-4-6',
                'namedCredential' => 'Anthropic',
                'maxTokens' => 1024,
                'isActive' => true,
                'isDefault' => true
            }));
            System.assertNotEquals(null, id);

            List<CR_AIProviderService.AdminProvider> all = CR_AIProviderService.listProviders();
            System.assertEquals(1, all.size());
            System.assertEquals('Anthropic Prod', all[0].label);
            System.assertEquals(true, all[0].isDefault);

            // Mark a second provider default — first one must lose default.
            Id id2 = CR_AIProviderService.saveProvider(JSON.serialize(new Map<String, Object>{
                'label' => 'Anthropic Dev', 'provider' => 'Anthropic',
                'namedCredential' => 'Anthropic_Dev', 'isActive' => true, 'isDefault' => true
            }));
            System.assertEquals(1, [SELECT COUNT() FROM CR_AI_Provider__c WHERE Is_Default__c = true],
                'exactly one default at a time');
            System.assertEquals(false, [SELECT Is_Default__c FROM CR_AI_Provider__c WHERE Id = :id].Is_Default__c);

            CR_AIProviderService.deleteProvider(id);
            System.assertEquals(0, [SELECT COUNT() FROM CR_AI_Provider__c WHERE Id = :id]);
        }
        Test.stopTest();
    }

    @isTest
    static void nonManagerIsBlocked() {
        User plain = plainUser();
        Test.startTest();
        System.runAs(plain) {
            System.assertEquals(false, CR_AIProviderService.canManageProviders());
            Boolean threw = false;
            try {
                CR_AIProviderService.saveProvider(JSON.serialize(new Map<String, Object>{ 'label' => 'Nope' }));
            } catch (Exception e) {
                threw = true;
            }
            System.assert(threw, 'saveProvider must be blocked without Manage_AI_Providers');
        }
        Test.stopTest();
    }

    @isTest
    static void testConnection_successAndError() {
        User admin = adminUser();
        CR_AI_Provider__c p = new CR_AI_Provider__c(
            Name = 'Probe Provider',
            Provider__c = 'Anthropic',
            Model__c = 'claude-haiku-4-5-20251001',
            Named_Credential_Name__c = 'Anthropic',
            Is_Active__c = true,
            Is_Default__c = true
        );
        insert p;

        Test.startTest();
        System.runAs(admin) {
            Test.setMock(HttpCalloutMock.class, new AnthropicOkMock());
            CR_AIProviderService.TestResult ok = CR_AIProviderService.testConnection(p.Id);
            System.assertEquals(true, ok.success, ok.message);
            System.assertEquals(200, ok.status);
        }
        Test.stopTest();

        // Second probe with an error mock — outside startTest/stopTest since a
        // single test can register only one HttpCalloutMock per Test.start window.
        Test.setMock(HttpCalloutMock.class, new AnthropicErrorMock());
        System.runAs(admin) {
            CR_AIProviderService.TestResult bad = CR_AIProviderService.testConnection(p.Id);
            System.assertEquals(false, bad.success);
            System.assertEquals(401, bad.status);
        }
    }

    @isTest
    static void testConnection_blankCredential_returnsHelpful() {
        User admin = adminUser();
        CR_AI_Provider__c p = new CR_AI_Provider__c(
            Name = 'Unconfigured', Provider__c = 'Anthropic',
            Model__c = 'claude-sonnet-4-6', Is_Active__c = true
        );
        insert p;
        Test.startTest();
        System.runAs(admin) {
            CR_AIProviderService.TestResult r = CR_AIProviderService.testConnection(p.Id);
            System.assertEquals(false, r.success);
            System.assert(r.message.contains('Named Credential'), 'message should mention Named Credential');
        }
        Test.stopTest();
    }

    @isTest
    static void seedFromSettings_isIdempotent() {
        Test.startTest();
        Integer first = CR_AIProviderService.seedFromSettings();
        Integer second = CR_AIProviderService.seedFromSettings();
        Test.stopTest();
        System.assert(first >= 0, 'seed returns non-negative');
        System.assertEquals(first, second, 'second run does not duplicate');
    }
}