// Returns the dataset peek panel's payload — what the user sees when they
// hover over a curated dataset before committing to picking it. Pulls
// together three signals that already exist somewhere in the org but aren't
// surfaced together: dataset metadata, current row count, and last refresh
// timestamp.
public with sharing class CR_DatasetCatalogService {

    public class DatasetPeek {
        @AuraEnabled public String datasetKey { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String sobjectApiName { get; set; }
        @AuraEnabled public String mode { get; set; }
        @AuraEnabled public Long rowCount { get; set; }
        @AuraEnabled public Datetime lastRefreshAt { get; set; }
        @AuraEnabled public String objectLabel { get; set; }
        @AuraEnabled public Boolean accessible { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static DatasetPeek getDatasetPeek(String datasetKey) {
        if (String.isBlank(datasetKey)) {
            throw new AuraHandledException('Dataset key is required.');
        }
        CR_Dataset__mdt md = CR_Dataset__mdt.getInstance(datasetKey);
        if (md == null) {
            throw new AuraHandledException('Dataset not found: ' + datasetKey);
        }

        DatasetPeek peek = new DatasetPeek();
        peek.datasetKey = datasetKey;
        peek.label = md.Label;
        peek.description = md.Description__c;
        peek.sobjectApiName = md.SObject_API_Name__c;
        peek.mode = md.Mode__c;

        // Object metadata is best-effort — a dataset pointing at an object the
        // running user can't see should still render a peek panel (with
        // accessible=false) rather than blowing up the picker.
        if (!String.isBlank(md.SObject_API_Name__c)) {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(md.SObject_API_Name__c);
            if (sot != null) {
                Schema.DescribeSObjectResult d = sot.getDescribe();
                peek.objectLabel = d.getLabel();
                peek.accessible = d.isAccessible() && d.isQueryable();
                if (peek.accessible) {
                    try {
                        peek.rowCount = Database.countQuery(
                            'SELECT COUNT() FROM ' + String.escapeSingleQuotes(md.SObject_API_Name__c)
                        );
                    } catch (Exception ex) {
                        // Some objects (e.g. external objects, certain managed
                        // packages) reject COUNT(). Don't fail the peek; just
                        // omit the row count.
                    }
                    // LastModifiedDate as a proxy for "last refresh" — works
                    // for Fact_* tables maintained by the nightly ETL because
                    // the batch's UPSERT bumps it on every run. For non-fact
                    // tables it's still useful as "was this touched recently?"
                    try {
                        List<SObject> latest = Database.query(
                            'SELECT LastModifiedDate FROM ' +
                            String.escapeSingleQuotes(md.SObject_API_Name__c) +
                            ' ORDER BY LastModifiedDate DESC LIMIT 1'
                        );
                        if (!latest.isEmpty()) {
                            peek.lastRefreshAt = (Datetime) latest[0].get('LastModifiedDate');
                        }
                    } catch (Exception ex) {
                        // Same tolerance as above.
                    }
                }
            }
        }
        return peek;
    }
}