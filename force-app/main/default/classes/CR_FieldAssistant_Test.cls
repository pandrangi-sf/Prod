/**
 * Covers the two halves of the assistant that can be exercised without a live
 * provider: the schema built from org catalogs, and the parse-then-save path.
 * The callout itself is mocked, so these tests pass with no Named Credential.
 */
@IsTest
private class CR_FieldAssistant_Test {

    private class DraftMock implements HttpCalloutMock {
        private String payload;
        DraftMock(String payload) {
            this.payload = payload;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(
                '{"stop_reason":"end_turn","content":[{"type":"text","text":' +
                JSON.serialize(payload) + '}]}'
            );
            return res;
        }
    }

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(429);
            res.setBody('{"error":{"message":"rate limited"}}');
            return res;
        }
    }

    private static Id visitRecordTypeId() {
        for (Schema.RecordTypeInfo rt : Visit_Report__c.SObjectType.getDescribe().getRecordTypeInfos()) {
            if (rt.isAvailable() && !rt.isMaster()) {
                return rt.getRecordTypeId();
            }
        }
        return null;
    }

    // Six active validation rules gate new provider Contacts in this org.
    private static Contact newProvider(String lastName) {
        return new Contact(
            FirstName = 'Test',
            LastName = lastName,
            Affiliation__c = 'Unaffiliated',
            Affiliation_Group__c = 'Independent',
            Credentials__c = 'MD',
            Gender__c = 'Female',
            Provider_Type__c = 'PCP'
        );
    }

    private static Objection__c seedObjection() {
        Objection__c o = new Objection__c(Name = 'Referral turnaround');
        insert o;
        return o;
    }

    private static CR_AI_Provider__c seedProvider() {
        CR_AI_Provider__c p = new CR_AI_Provider__c(
            Provider__c = 'Anthropic',
            Model__c = 'claude-opus-5',
            Max_Tokens__c = 2048,
            Named_Credential_Name__c = 'Anthropic_API',
            Is_Active__c = true,
            Is_Default__c = true
        );
        insert p;
        return p;
    }

    private static String draftJson(String objectionName) {
        return JSON.serialize(new Map<String, Object>{
            'subject' => 'Quarterly meeting - Dr. Patel',
            'visitDate' => String.valueOf(Date.today()),
            'visitType' => 'In Person',
            'category' => 'Quarterly Meeting',
            'purpose' => 'Referral Development',
            'audience' => 'Physician',
            'notes' => 'Discussed referral turnaround times.',
            'leftVoicemail' => false,
            'mealWithVisit' => 'Yes',
            'tandemVisit' => false,
            'providerName' => 'Dr. Patel',
            'objections' => new List<Object>{
                new Map<String, Object>{ 'name' => objectionName, 'comments' => 'Wants faster scheduling.' }
            },
            'services' => new List<String>(),
            'collateral' => new List<String>(),
            'confidenceNotes' => new List<String>{ 'Date was not stated explicitly.' }
        });
    }

    @IsTest
    static void catalogExposesPicklistsAndConfigFlag() {
        Test.startTest();
        CR_FieldAssistant.Catalog c = CR_FieldAssistant.getCatalog();
        Test.stopTest();

        Assert.isFalse(c.visitTypes.isEmpty(), 'Visit types should come from the picklist');
        Assert.isFalse(c.categories.isEmpty(), 'Categories should come from the picklist');
        Assert.isFalse(c.aiConfigured, 'No provider record exists, so AI is not configured');
    }

    @IsTest
    static void schemaUsesOrgValuesAsEnums() {
        seedObjection();

        Test.startTest();
        CR_FieldAssistant.Catalog c = CR_FieldAssistant.getCatalog();
        Map<String, Object> schema = CR_FieldAssistant.schemaFor(c);
        Test.stopTest();

        Map<String, Object> props = (Map<String, Object>) schema.get('properties');
        Map<String, Object> visitType = (Map<String, Object>) props.get('visitType');
        Assert.isNotNull(visitType.get('enum'), 'visitType should be constrained to an enum');

        Map<String, Object> objections = (Map<String, Object>) props.get('objections');
        Map<String, Object> items = (Map<String, Object>) objections.get('items');
        Map<String, Object> itemProps = (Map<String, Object>) items.get('properties');
        Map<String, Object> nameProp = (Map<String, Object>) itemProps.get('name');
        List<Object> allowed = (List<Object>) nameProp.get('enum');
        Assert.isTrue(allowed.contains('Referral turnaround'), 'Objection catalog should drive the enum');
        Assert.areEqual(false, schema.get('additionalProperties'), 'Schema must be closed');
    }

    @IsTest
    static void emptyCatalogDegradesToStringNotEmptyEnum() {
        // No Service__c records: an empty enum would be invalid JSON Schema.
        Test.startTest();
        CR_FieldAssistant.Catalog c = CR_FieldAssistant.getCatalog();
        Map<String, Object> schema = CR_FieldAssistant.schemaFor(c);
        Test.stopTest();

        Map<String, Object> props = (Map<String, Object>) schema.get('properties');
        Map<String, Object> services = (Map<String, Object>) props.get('services');
        Map<String, Object> items = (Map<String, Object>) services.get('items');
        if (c.services.isEmpty()) {
            Assert.areEqual('string', items.get('type'), 'Empty catalog should fall back to string');
        } else {
            Assert.isNotNull(items.get('enum'), 'Populated catalog should produce an enum');
        }
    }

    @IsTest
    static void extractVisitRequiresConfiguredProvider() {
        Test.startTest();
        try {
            CR_FieldAssistant.extractVisit('Saw Dr Patel today.');
            Assert.fail('Should refuse to run without a provider');
        } catch (Exception e) {
            Assert.isTrue(e instanceof AuraHandledException, 'Expected an AuraHandledException');
        }
        Test.stopTest();
    }

    @IsTest
    static void extractVisitParsesModelOutput() {
        Objection__c o = seedObjection();
        seedProvider();
        Test.setMock(HttpCalloutMock.class, new DraftMock(draftJson(o.Name)));

        Test.startTest();
        CR_FieldAssistant.VisitDraft d = CR_FieldAssistant.extractVisit('Saw Dr Patel today.');
        Test.stopTest();

        Assert.areEqual('In Person', d.visitType, 'Visit type should round-trip');
        Assert.areEqual(1, d.objections.size(), 'One objection should be parsed');
        Assert.areEqual('Referral turnaround', d.objections[0].name, 'Objection name should round-trip');
        Assert.areEqual(1, d.confidenceNotes.size(), 'Confidence notes should survive parsing');
    }

    @IsTest
    static void calloutFailureSurfacesAsUserError() {
        seedProvider();
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
        try {
            CR_FieldAssistant.extractVisit('Saw Dr Patel today.');
            Assert.fail('A 429 should not be swallowed');
        } catch (Exception e) {
            Assert.isTrue(e instanceof AuraHandledException, 'Expected an AuraHandledException');
        }
        Test.stopTest();
    }

    @IsTest
    static void saveVisitWritesReportTaskAndObjection() {
        Objection__c o = seedObjection();
        Contact provider = newProvider('Patel');
        insert provider;

        Test.startTest();
        CR_FieldAssistant.SaveResult r = CR_FieldAssistant.saveVisit(
            draftJson(o.Name), provider.Id, visitRecordTypeId());
        Test.stopTest();

        Assert.isNotNull(r.visitReportId, 'A visit report should be created');
        Assert.isNotNull(r.taskId, 'A task should link the visit to the provider');
        Assert.areEqual(1, r.objectionsCreated, 'The objection should be linked');

        Visit_Report__c vr = [
            SELECT Subject__c, Visit_Type__c, Meal_With_Visit__c, Visit_Date__c
            FROM Visit_Report__c WHERE Id = :r.visitReportId
        ];
        Assert.areEqual('In Person', vr.Visit_Type__c, 'Visit type should persist');
        Assert.areEqual('Yes', vr.Meal_With_Visit__c, 'The Yes/No picklist should persist');

        Task t = [SELECT WhoId, Visit_Report__c FROM Task WHERE Id = :r.taskId];
        Assert.areEqual(provider.Id, t.WhoId, 'Task should point at the provider');
        Assert.areEqual(r.visitReportId, t.Visit_Report__c, 'Task should point at the visit report');

        Assert.areEqual(1, [SELECT COUNT() FROM Visit_Objection__c WHERE Visit_Report__c = :r.visitReportId],
            'One junction row should exist');
    }

    @IsTest
    static void saveVisitIgnoresUnknownCatalogNames() {
        Test.startTest();
        CR_FieldAssistant.SaveResult r = CR_FieldAssistant.saveVisit(
            draftJson('Not A Real Objection'), null, visitRecordTypeId());
        Test.stopTest();

        Assert.isNotNull(r.visitReportId, 'The report should still save');
        Assert.areEqual(0, r.objectionsCreated, 'An unmatched objection must not be invented');
        Assert.isNull(r.taskId, 'No provider means no task');
    }

    @IsTest
    static void searchProvidersNeedsTwoCharacters() {
        insert newProvider('Patel');

        Test.startTest();
        List<CR_FieldAssistant.ProviderOption> none = CR_FieldAssistant.searchProviders('P');
        List<CR_FieldAssistant.ProviderOption> some = CR_FieldAssistant.searchProviders('Pat');
        Test.stopTest();

        Assert.isTrue(none.isEmpty(), 'A single character should not search');
        Assert.isFalse(some.isEmpty(), 'Two or more characters should match');
    }
}
