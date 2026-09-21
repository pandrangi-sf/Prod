/**
 * Controller for the visitTypeMonthlyReview Lightning web component.
 *
 * Lets a PRM user pick an upload month, review that month's visit types and
 * bulk-set the PRM_Report__c decision to Y or N.
 *
 * Security: "with sharing" so record visibility follows the running user.
 * Reads are gated with WITH USER_MODE (object, field and record access); the bulk update runs through
 * Security.stripInaccessible(AccessType.UPDATABLE, ...) so a user who cannot
 * edit PRM_Report__c cannot change it through this class.
 */
public with sharing class VisitTypeReviewController {

    @TestVisible
    private static final Set<String> ALLOWED_VALUES = new Set<String>{ 'Y', 'N' };

    /** Guard against handing a runaway result set back to the component. */
    @TestVisible
    private static Integer maxRows = 5000;

    /**
     * Distinct upload months, newest first, for the month picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getUploadMonths() {
        List<String> months = new List<String>();
        for (AggregateResult ar : [
            SELECT Upload_Month__c uploadMonth
            FROM New_Patient_Visit_Type__c
            WHERE Upload_Month__c != null
            WITH USER_MODE
            GROUP BY Upload_Month__c
            ORDER BY Upload_Month__c DESC
        ]) {
            months.add(String.valueOf(ar.get('uploadMonth')));
        }
        return months;
    }

    /**
     * Visit types for one upload month. Respects sharing and field-level security.
     */
    @AuraEnabled(cacheable=true)
    public static List<New_Patient_Visit_Type__c> getRecordsByMonth(String uploadMonth) {
        if (String.isBlank(uploadMonth)) {
            return new List<New_Patient_Visit_Type__c>();
        }
        Integer rowLimit = maxRows;
        return [
            SELECT Id, Name, EPIC_New_Pt_Visit_Type__c, PRM_Report__c,
                   LastModifiedBy.Name, LastModifiedDate
            FROM New_Patient_Visit_Type__c
            WHERE Upload_Month__c = :uploadMonth
            WITH USER_MODE
            ORDER BY EPIC_New_Pt_Visit_Type__c
            LIMIT :rowLimit
        ];
    }

    /**
     * Bulk-set PRM_Report__c for the selected records.
     * @param recordIds ids of New_Patient_Visit_Type__c records
     * @param value     'Y' or 'N'
     * @return number of records updated
     */
    @AuraEnabled
    public static Integer bulkUpdatePrmReport(List<Id> recordIds, String value) {
        if (recordIds == null || recordIds.isEmpty()) {
            return 0;
        }
        if (String.isBlank(value) || !ALLOWED_VALUES.contains(value)) {
            throw buildException('PRM Report must be Y or N.');
        }
        if (!Schema.sObjectType.New_Patient_Visit_Type__c.isUpdateable()) {
            throw buildException('You do not have edit access to New Patient Visit Type.');
        }

        List<New_Patient_Visit_Type__c> toUpdate = new List<New_Patient_Visit_Type__c>();
        for (Id recordId : new Set<Id>(recordIds)) {
            if (recordId != null
                && recordId.getSobjectType() == New_Patient_Visit_Type__c.SObjectType) {
                toUpdate.add(new New_Patient_Visit_Type__c(
                    Id = recordId,
                    PRM_Report__c = value
                ));
            }
        }
        if (toUpdate.isEmpty()) {
            return 0;
        }

        SObjectAccessDecision decision =
            Security.stripInaccessible(AccessType.UPDATABLE, toUpdate);

        Set<String> removed = decision.getRemovedFields().get('New_Patient_Visit_Type__c');
        if (removed != null && removed.contains('PRM_Report__c')) {
            throw buildException('You do not have edit access to the PRM Report field.');
        }

        List<New_Patient_Visit_Type__c> safeRecords =
            (List<New_Patient_Visit_Type__c>) decision.getRecords();

        try {
            update safeRecords;
        } catch (DmlException e) {
            throw buildException(e.getDmlMessage(0));
        }
        return safeRecords.size();
    }

    /** AuraHandledException only surfaces a useful message when it is set explicitly. */
    private static AuraHandledException buildException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}