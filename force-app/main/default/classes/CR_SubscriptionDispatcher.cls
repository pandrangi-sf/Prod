public with sharing class CR_SubscriptionDispatcher implements Schedulable {

    // Bounded so a single hourly run stays well under the 50-jobs-per-transaction
    // enqueue limit. Overflow simply rolls to the next hourly tick.
    @TestVisible private static Integer maxPerRun = 45;

    public void execute(SchedulableContext context) {
        dispatchDue();
    }

    // Initializes any active subscription that has no Next_Run_At yet (e.g. just
    // created), then dispatches the ones that are due — enqueuing a delivery and
    // advancing Next_Run_At so they can't be picked up twice. Returns the number
    // dispatched. Runs as the scheduling user on the cron path, so no gate here.
    public static Integer dispatchDue() {
        Datetime now = System.now();

        List<CR_Subscription__c> uninitialized = [
            SELECT Id, Frequency__c, Day_Of_Week__c, Day_Of_Month__c, Hour_Of_Day__c, Next_Run_At__c
            FROM CR_Subscription__c
            WHERE Active__c = true AND Next_Run_At__c = null
            LIMIT 200
        ];
        if (!uninitialized.isEmpty()) {
            for (CR_Subscription__c sub : uninitialized) {
                sub.Next_Run_At__c = CR_SubscriptionService.computeNextRun(sub, now);
            }
            update uninitialized;
        }

        List<CR_Subscription__c> due = [
            SELECT Id, Frequency__c, Day_Of_Week__c, Day_Of_Month__c, Hour_Of_Day__c, Next_Run_At__c
            FROM CR_Subscription__c
            WHERE Active__c = true AND Next_Run_At__c != null AND Next_Run_At__c <= :now
            ORDER BY Next_Run_At__c ASC
            LIMIT :maxPerRun
        ];
        List<CR_Subscription__c> toAdvance = new List<CR_Subscription__c>();
        for (CR_Subscription__c sub : due) {
            System.enqueueJob(new CR_SubscriptionSendQueueable(sub.Id));
            sub.Next_Run_At__c = CR_SubscriptionService.computeNextRun(sub, now);
            toAdvance.add(sub);
        }
        if (!toAdvance.isEmpty()) {
            update toAdvance;
        }
        return due.size();
    }

    @AuraEnabled
    public static String scheduleHourly() {
        if (!FeatureManagement.checkPermission('Manage_Report_Subscriptions')) {
            throw new AuraHandledException('You do not have permission to schedule report subscriptions.');
        }
        return System.schedule('Vital Reports Subscription Dispatcher', '0 0 * * * ?', new CR_SubscriptionDispatcher());
    }
}