@isTest
private class NPIRegistryControllerTest {

    private class MockNPISuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{'
                + '"result_count": 1,'
                + '"results": [{'
                + '  "enumeration_type": "NPI-1",'
                + '  "number": 1234567890,'
                + '  "basic": {'
                + '    "first_name": "JOHN",'
                + '    "last_name": "DOE",'
                + '    "middle_name": "M",'
                + '    "credential": "MD",'
                + '    "sex": "M",'
                + '    "status": "A",'
                + '    "enumeration_date": "2005-05-23",'
                + '    "last_updated": "2023-01-15",'
                + '    "sole_proprietor": "NO"'
                + '  },'
                + '  "addresses": [{'
                + '    "address_purpose": "LOCATION",'
                + '    "address_1": "123 MAIN ST",'
                + '    "address_2": "SUITE 100",'
                + '    "city": "ORLANDO",'
                + '    "state": "FL",'
                + '    "postal_code": "328010000",'
                + '    "telephone_number": "407-555-1234",'
                + '    "fax_number": "407-555-5678"'
                + '  }, {'
                + '    "address_purpose": "MAILING",'
                + '    "address_1": "PO BOX 999",'
                + '    "city": "ORLANDO",'
                + '    "state": "FL",'
                + '    "postal_code": "328020000",'
                + '    "telephone_number": "407-555-1234"'
                + '  }],'
                + '  "taxonomies": [{'
                + '    "code": "207R00000X",'
                + '    "desc": "Internal Medicine",'
                + '    "primary": true,'
                + '    "state": "FL",'
                + '    "license": "ME12345"'
                + '  }],'
                + '  "identifiers": [{'
                + '    "identifier": "A12345",'
                + '    "desc": "Medicare",'
                + '    "state": "FL",'
                + '    "issuer": "CMS"'
                + '  }]'
                + '}]'
                + '}');
            return res;
        }
    }

    private class MockNPINoResults implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"result_count": 0, "results": []}');
            return res;
        }
    }

    private class MockNPIError implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    @TestSetup
    static void setupTestData() {
        Contact validContact = new Contact(
            FirstName = 'Test',
            LastName = 'Provider',
            NPI__c = '1234567890',
            Affiliation__c = 'Unaffiliated',
            Affiliation_Group__c = 'Independent',
            Provider_Type__c = 'PCP',
            Credentials__c = 'MD',
            Gender__c = 'Male'
        );
        insert validContact;

        Contact blankNpiContact = new Contact(
            FirstName = 'No',
            LastName = 'NPI',
            Affiliation__c = 'Unaffiliated',
            Affiliation_Group__c = 'Independent',
            Provider_Type__c = 'PCP',
            Credentials__c = 'MD',
            Gender__c = 'Male'
        );
        insert blankNpiContact;

        Contact badNpiContact = new Contact(
            FirstName = 'Bad',
            LastName = 'Format',
            NPI__c = '12345',
            Affiliation__c = 'Unaffiliated',
            Affiliation_Group__c = 'Independent',
            Provider_Type__c = 'PCP',
            Credentials__c = 'MD',
            Gender__c = 'Male'
        );
        insert badNpiContact;
    }

    @isTest
    static void testSuccessfulLookup() {
        Contact con = [SELECT Id FROM Contact WHERE LastName = 'Provider' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockNPISuccess());

        Test.startTest();
        NPIRegistryController.NPIResult result = NPIRegistryController.getProviderByNPI(con.Id);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Lookup should succeed');
        System.assertEquals('JOHN', result.firstName);
        System.assertEquals('DOE', result.lastName);
        System.assertEquals('MD', result.credential);
        System.assertEquals('NPI-1', result.enumerationType);
        System.assertEquals('A', result.status);
        System.assertEquals(2, result.addresses.size(), 'Should have 2 addresses');
        System.assertEquals('LOCATION', result.addresses[0].addressPurpose);
        System.assertEquals(1, result.taxonomies.size(), 'Should have 1 taxonomy');
        System.assertEquals(true, result.taxonomies[0].isPrimary);
        System.assertEquals(1, result.identifiers.size(), 'Should have 1 identifier');
    }

    @isTest
    static void testBlankNPI() {
        Contact con = [SELECT Id FROM Contact WHERE LastName = 'NPI' LIMIT 1];

        Test.startTest();
        NPIRegistryController.NPIResult result = NPIRegistryController.getProviderByNPI(con.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('No NPI number found'), result.errorMessage);
    }

    @isTest
    static void testInvalidNPIFormat() {
        Contact con = [SELECT Id FROM Contact WHERE LastName = 'Format' LIMIT 1];

        Test.startTest();
        NPIRegistryController.NPIResult result = NPIRegistryController.getProviderByNPI(con.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Invalid NPI format'), result.errorMessage);
    }

    @isTest
    static void testNoResultsFromAPI() {
        Contact con = [SELECT Id FROM Contact WHERE LastName = 'Provider' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockNPINoResults());

        Test.startTest();
        NPIRegistryController.NPIResult result = NPIRegistryController.getProviderByNPI(con.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('No provider found'), result.errorMessage);
    }

    @isTest
    static void testAPIError() {
        Contact con = [SELECT Id FROM Contact WHERE LastName = 'Provider' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockNPIError());

        Test.startTest();
        NPIRegistryController.NPIResult result = NPIRegistryController.getProviderByNPI(con.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('status 500'), result.errorMessage);
    }
}