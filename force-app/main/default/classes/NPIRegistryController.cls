public with sharing class NPIRegistryController {

    private static final String API_BASE = 'https://npiregistry.cms.hhs.gov/api/?version=2.1&number=';

    @AuraEnabled(cacheable=true)
    public static NPIResult getProviderByNPI(Id recordId) {
        NPIResult result = new NPIResult();

        try {
            Contact con = [SELECT NPI__c FROM Contact WHERE Id = :recordId LIMIT 1];

            if (String.isBlank(con.NPI__c)) {
                result.success = false;
                result.errorMessage = 'No NPI number found on this Contact record.';
                return result;
            }

            String npiNumber = con.NPI__c.trim();

            if (!Pattern.matches('\\d{10}', npiNumber)) {
                result.success = false;
                result.errorMessage = 'Invalid NPI format. NPI must be exactly 10 digits.';
                return result;
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(API_BASE + EncodingUtil.urlEncode(npiNumber, 'UTF-8'));
            req.setMethod('GET');
            req.setTimeout(15000);

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                result.success = false;
                result.errorMessage = 'NPPES API returned status ' + res.getStatusCode() + '.';
                return result;
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Integer resultCount = (Integer) body.get('result_count');

            if (resultCount == null || resultCount == 0) {
                result.success = false;
                result.errorMessage = 'No provider found for NPI ' + npiNumber + '.';
                return result;
            }

            List<Object> results = (List<Object>) body.get('results');
            Map<String, Object> provider = (Map<String, Object>) results[0];

            result.success = true;
            result.npiNumber = npiNumber;
            result.enumerationType = (String) provider.get('enumeration_type');

            Map<String, Object> basic = (Map<String, Object>) provider.get('basic');
            if (basic != null) {
                result.firstName = (String) basic.get('first_name');
                result.lastName = (String) basic.get('last_name');
                result.middleName = (String) basic.get('middle_name');
                result.credential = (String) basic.get('credential');
                result.gender = (String) basic.get('sex');
                result.status = (String) basic.get('status');
                result.enumerationDate = (String) basic.get('enumeration_date');
                result.lastUpdated = (String) basic.get('last_updated');
                result.sole_proprietor = (String) basic.get('sole_proprietor');
                result.organizationName = (String) basic.get('organization_name');
                result.organizationalSubpart = (String) basic.get('organizational_subpart');
            }

            List<Object> addresses = (List<Object>) provider.get('addresses');
            if (addresses != null) {
                result.addresses = new List<NPIAddress>();
                for (Object addrObj : addresses) {
                    Map<String, Object> addr = (Map<String, Object>) addrObj;
                    NPIAddress npiAddr = new NPIAddress();
                    npiAddr.addressPurpose = (String) addr.get('address_purpose');
                    npiAddr.addressLine1 = (String) addr.get('address_1');
                    npiAddr.addressLine2 = (String) addr.get('address_2');
                    npiAddr.city = (String) addr.get('city');
                    npiAddr.state = (String) addr.get('state');
                    npiAddr.postalCode = (String) addr.get('postal_code');
                    npiAddr.telephoneNumber = (String) addr.get('telephone_number');
                    npiAddr.faxNumber = (String) addr.get('fax_number');
                    result.addresses.add(npiAddr);
                }
            }

            List<Object> taxonomies = (List<Object>) provider.get('taxonomies');
            if (taxonomies != null) {
                result.taxonomies = new List<NPITaxonomy>();
                for (Object taxObj : taxonomies) {
                    Map<String, Object> tax = (Map<String, Object>) taxObj;
                    NPITaxonomy npiTax = new NPITaxonomy();
                    npiTax.code = (String) tax.get('code');
                    npiTax.taxonomyDescription = (String) tax.get('desc');
                    npiTax.isPrimary = (Boolean) tax.get('primary');
                    npiTax.state = (String) tax.get('state');
                    npiTax.license = (String) tax.get('license');
                    result.taxonomies.add(npiTax);
                }
            }

            List<Object> identifiers = (List<Object>) provider.get('identifiers');
            if (identifiers != null) {
                result.identifiers = new List<NPIIdentifier>();
                for (Object idObj : identifiers) {
                    Map<String, Object> ident = (Map<String, Object>) idObj;
                    NPIIdentifier npiId = new NPIIdentifier();
                    npiId.identifier = (String) ident.get('identifier');
                    npiId.identifierType = (String) ident.get('desc');
                    npiId.state = (String) ident.get('state');
                    npiId.issuer = (String) ident.get('issuer');
                    result.identifiers.add(npiId);
                }
            }

        } catch (System.CalloutException ce) {
            result.success = false;
            result.errorMessage = 'Unable to reach the NPPES Registry. Please try again later.';
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'An unexpected error occurred: ' + e.getMessage();
        }

        return result;
    }

    public class NPIResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String npiNumber;
        @AuraEnabled public String enumerationType;
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String middleName;
        @AuraEnabled public String credential;
        @AuraEnabled public String gender;
        @AuraEnabled public String status;
        @AuraEnabled public String enumerationDate;
        @AuraEnabled public String lastUpdated;
        @AuraEnabled public String sole_proprietor;
        @AuraEnabled public String organizationName;
        @AuraEnabled public String organizationalSubpart;
        @AuraEnabled public List<NPIAddress> addresses;
        @AuraEnabled public List<NPITaxonomy> taxonomies;
        @AuraEnabled public List<NPIIdentifier> identifiers;
    }

    public class NPIAddress {
        @AuraEnabled public String addressPurpose;
        @AuraEnabled public String addressLine1;
        @AuraEnabled public String addressLine2;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String telephoneNumber;
        @AuraEnabled public String faxNumber;
    }

    public class NPITaxonomy {
        @AuraEnabled public String code;
        @AuraEnabled public String taxonomyDescription;
        @AuraEnabled public Boolean isPrimary;
        @AuraEnabled public String state;
        @AuraEnabled public String license;
    }

    public class NPIIdentifier {
        @AuraEnabled public String identifier;
        @AuraEnabled public String identifierType;
        @AuraEnabled public String state;
        @AuraEnabled public String issuer;
    }
}