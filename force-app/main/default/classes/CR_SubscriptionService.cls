public with sharing class CR_SubscriptionService {

    // Next delivery datetime for a subscription, strictly after fromTime, in the
    // running context's time zone. Weekly matches on the day name; Monthly caps
    // the day at 28 so it lands every month. Daily rolls to tomorrow once the
    // hour has passed.
    public static Datetime computeNextRun(CR_Subscription__c sub, Datetime fromTime) {
        Integer hour = (sub.Hour_Of_Day__c == null) ? 6 : sub.Hour_Of_Day__c.intValue();
        if (hour < 0 || hour > 23) {
            hour = 6;
        }
        Date today = fromTime.date();
        String freq = String.isBlank(sub.Frequency__c) ? 'Daily' : sub.Frequency__c;

        if (freq == 'Weekly') {
            String target = String.isBlank(sub.Day_Of_Week__c) ? 'Monday' : sub.Day_Of_Week__c;
            for (Integer i = 0; i < 8; i++) {
                Datetime candidate = Datetime.newInstance(today.addDays(i), Time.newInstance(hour, 0, 0, 0));
                if (candidate > fromTime && candidate.format('EEEE') == target) {
                    return candidate;
                }
            }
            return Datetime.newInstance(today.addDays(7), Time.newInstance(hour, 0, 0, 0));
        }

        if (freq == 'Monthly') {
            Integer dom = (sub.Day_Of_Month__c == null) ? 1 : sub.Day_Of_Month__c.intValue();
            dom = Math.max(1, Math.min(dom, 28));
            Datetime candidate = Datetime.newInstance(
                Date.newInstance(today.year(), today.month(), dom), Time.newInstance(hour, 0, 0, 0)
            );
            if (candidate <= fromTime) {
                Date nextMonth = today.addMonths(1);
                candidate = Datetime.newInstance(
                    Date.newInstance(nextMonth.year(), nextMonth.month(), dom), Time.newInstance(hour, 0, 0, 0)
                );
            }
            return candidate;
        }

        // Daily (default)
        Datetime candidate = Datetime.newInstance(today, Time.newInstance(hour, 0, 0, 0));
        if (candidate <= fromTime) {
            candidate = candidate.addDays(1);
        }
        return candidate;
    }

    // Manual "send test now" for admins. Enqueues an immediate delivery without
    // touching the schedule (Next_Run_At is untouched).
    @AuraEnabled
    public static void sendNow(Id subscriptionId) {
        if (!FeatureManagement.checkPermission('Manage_Report_Subscriptions')) {
            throw new AuraHandledException('You do not have permission to manage report subscriptions.');
        }
        if (subscriptionId == null) {
            throw new AuraHandledException('Subscription Id is required.');
        }
        System.enqueueJob(new CR_SubscriptionSendQueueable(subscriptionId));
    }

    // ---- Admin UI (crSubscriptionManager) ----
    // All mutating entry points gate on Manage_Report_Subscriptions, matching sendNow.

    private static void assertManagePermission() {
        if (!FeatureManagement.checkPermission('Manage_Report_Subscriptions')) {
            throw new AuraHandledException('You do not have permission to manage report subscriptions.');
        }
    }

    @AuraEnabled
    public static List<SubscriptionSummary> listSubscriptions() {
        assertManagePermission();
        Map<Id, Integer> recipientCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Subscription__c subId, COUNT(Id) cnt
            FROM CR_Subscription_Recipient__c
            GROUP BY Subscription__c
        ]) {
            recipientCounts.put((Id) ar.get('subId'), (Integer) ar.get('cnt'));
        }
        List<SubscriptionSummary> out = new List<SubscriptionSummary>();
        for (CR_Subscription__c s : querySubscriptions(null)) {
            Integer count = recipientCounts.containsKey(s.Id) ? recipientCounts.get(s.Id) : 0;
            out.add(toSummary(s, count));
        }
        return out;
    }

    @AuraEnabled
    public static SubscriptionSummary getSubscription(Id subscriptionId) {
        assertManagePermission();
        if (subscriptionId == null) {
            throw new AuraHandledException('Subscription Id is required.');
        }
        List<CR_Subscription__c> rows = querySubscriptions(subscriptionId);
        if (rows.isEmpty()) {
            throw new AuraHandledException('Subscription not found.');
        }
        Integer count = [SELECT COUNT() FROM CR_Subscription_Recipient__c WHERE Subscription__c = :subscriptionId];
        return toSummary(rows[0], count);
    }

    @AuraEnabled
    public static List<RecipientDto> listRecipients(Id subscriptionId) {
        assertManagePermission();
        List<RecipientDto> out = new List<RecipientDto>();
        if (subscriptionId == null) {
            return out;
        }
        for (CR_Subscription_Recipient__c r : [
            SELECT Id, Recipient_Type__c, User__c, User__r.Name, Email__c, Group_Id__c, Group_Name__c
            FROM CR_Subscription_Recipient__c
            WHERE Subscription__c = :subscriptionId
            ORDER BY CreatedDate ASC
        ]) {
            RecipientDto d = new RecipientDto();
            d.id = r.Id;
            d.recipientType = r.Recipient_Type__c;
            d.userId = r.User__c;
            d.userName = (r.User__r != null) ? r.User__r.Name : null;
            d.email = r.Email__c;
            d.groupId = r.Group_Id__c;
            d.groupName = r.Group_Name__c;
            out.add(d);
        }
        // Backfill display names for Public Group recipients whose Group_Name__c
        // wasn't captured at save time (the picker only stored the Id), so the UI
        // shows "Sales Leadership" rather than a raw "00G..." Id.
        Set<Id> groupIds = new Set<Id>();
        for (RecipientDto d : out) {
            if (String.isBlank(d.groupName) && String.isNotBlank(d.groupId)) {
                try {
                    groupIds.add((Id) d.groupId);
                } catch (Exception ignored) {
                    // non-Id group reference (shouldn't happen); leave as-is
                }
            }
        }
        if (!groupIds.isEmpty()) {
            Map<Id, Group> groupsById = new Map<Id, Group>([SELECT Id, Name FROM Group WHERE Id IN :groupIds]);
            for (RecipientDto d : out) {
                if (String.isBlank(d.groupName) && String.isNotBlank(d.groupId)) {
                    Group g = groupsById.get((Id) d.groupId);
                    if (g != null) {
                        d.groupName = g.Name;
                    }
                }
            }
        }
        return out;
    }

    // Reports + dashboards the admin can attach. broadcastSafe is surfaced so the
    // UI can warn that a non-certified asset will refuse to send until certified.
    @AuraEnabled(cacheable=true)
    public static List<AssetOption> listSubscribableAssets() {
        List<AssetOption> out = new List<AssetOption>();
        for (Report_Definition__c r : [
            SELECT Id, Name, Broadcast_Safe__c FROM Report_Definition__c ORDER BY Name ASC LIMIT 1000
        ]) {
            out.add(new AssetOption(r.Id, r.Name, 'Report', r.Broadcast_Safe__c == true));
        }
        for (Dashboard__c d : [
            SELECT Id, Name, Broadcast_Safe__c FROM Dashboard__c ORDER BY Name ASC LIMIT 1000
        ]) {
            out.add(new AssetOption(d.Id, d.Name, 'Dashboard', d.Broadcast_Safe__c == true));
        }
        return out;
    }

    // Payload is a JSON string (not typed @AuraEnabled params) to dodge the
    // wire-layer inner-class deserialization that has nulled fields elsewhere
    // in this codebase (see crAllowlistManager save flow).
    @AuraEnabled
    public static Id upsertSubscription(String payloadJson) {
        assertManagePermission();
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No subscription data provided.');
        }
        SubscriptionInput input = (SubscriptionInput) JSON.deserialize(payloadJson, SubscriptionInput.class);
        CR_Subscription__c sub = new CR_Subscription__c();
        if (String.isNotBlank(input.id)) {
            sub.Id = (Id) input.id;
        }
        sub.Report_Definition__c = String.isBlank(input.reportDefinitionId) ? null : (Id) input.reportDefinitionId;
        sub.Dashboard__c = String.isBlank(input.dashboardId) ? null : (Id) input.dashboardId;
        sub.Frequency__c = String.isBlank(input.frequency) ? 'Daily' : input.frequency;
        sub.Day_Of_Week__c = input.dayOfWeek;
        sub.Day_Of_Month__c = input.dayOfMonth;
        sub.Hour_Of_Day__c = input.hourOfDay;
        sub.Active__c = input.active == true;
        sub.Include_HTML_Table__c = input.includeHtmlTable == true;
        sub.Include_CSV_Attachment__c = input.includeCsvAttachment == true;
        sub.Max_Inline_Rows__c = input.maxInlineRows;
        sub.Send_If_Empty__c = input.sendIfEmpty == true;
        sub.Filter_Override_JSON__c = input.filterOverrideJson;
        // Reject a bad filter override here (Aura context) so it never reaches the
        // send Queueable, where a malformed override either NPEs or throws an
        // AuraHandledException that is uncatchable off the Aura stack. Report-backed
        // subs get full field validation; dashboard subs get structural-only (the
        // override spans every component's dataset).
        if (String.isNotBlank(input.filterOverrideJson)) {
            List<String> filterErrors = (sub.Report_Definition__c != null)
                ? CR_QueryEngine.validateReportOverrideFilters(sub.Report_Definition__c, input.filterOverrideJson)
                : CR_QueryEngine.validateOverrideFiltersStructural(input.filterOverrideJson);
            if (!filterErrors.isEmpty()) {
                throw new AuraHandledException('Invalid filter override: ' + String.join(filterErrors, ' '));
            }
        }
        // Recompute the schedule immediately so the UI shows an accurate Next Run
        // after a frequency/hour change; inactive subs don't get scheduled.
        sub.Next_Run_At__c = sub.Active__c ? computeNextRun(sub, System.now()) : null;
        try {
            upsert sub;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return sub.Id;
    }

    @AuraEnabled
    public static void deleteSubscription(Id subscriptionId) {
        assertManagePermission();
        if (subscriptionId == null) {
            return;
        }
        // Recipients are master-detail children and cascade-delete with the parent.
        delete [SELECT Id FROM CR_Subscription__c WHERE Id = :subscriptionId];
    }

    @AuraEnabled
    public static Id upsertRecipient(String payloadJson) {
        assertManagePermission();
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No recipient data provided.');
        }
        RecipientInput input = (RecipientInput) JSON.deserialize(payloadJson, RecipientInput.class);
        if (String.isBlank(input.id) && String.isBlank(input.subscriptionId)) {
            throw new AuraHandledException('A recipient must belong to a subscription.');
        }
        CR_Subscription_Recipient__c rec = new CR_Subscription_Recipient__c();
        if (String.isNotBlank(input.id)) {
            rec.Id = (Id) input.id;
        }
        // Subscription__c is master-detail and not reparentable, so only set it on create.
        if (String.isBlank(input.id) && String.isNotBlank(input.subscriptionId)) {
            rec.Subscription__c = (Id) input.subscriptionId;
        }
        rec.Recipient_Type__c = String.isBlank(input.recipientType) ? 'User' : input.recipientType;
        rec.User__c = String.isBlank(input.userId) ? null : (Id) input.userId;
        rec.Email__c = input.email;
        rec.Group_Id__c = input.groupId;
        rec.Group_Name__c = input.groupName;
        try {
            upsert rec;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return rec.Id;
    }

    @AuraEnabled
    public static void deleteRecipient(Id recipientId) {
        assertManagePermission();
        if (recipientId == null) {
            return;
        }
        delete [SELECT Id FROM CR_Subscription_Recipient__c WHERE Id = :recipientId];
    }

    private static List<CR_Subscription__c> querySubscriptions(Id subscriptionId) {
        String soql =
            'SELECT Id, Name, Report_Definition__c, Report_Definition__r.Name,'
            + ' Dashboard__c, Dashboard__r.Name, Frequency__c, Day_Of_Week__c, Day_Of_Month__c,'
            + ' Hour_Of_Day__c, Active__c, Last_Status__c, Last_Run_At__c, Last_Message__c, Next_Run_At__c,'
            + ' Include_HTML_Table__c, Include_CSV_Attachment__c, Max_Inline_Rows__c, Send_If_Empty__c,'
            + ' Filter_Override_JSON__c'
            + ' FROM CR_Subscription__c';
        if (subscriptionId != null) {
            soql += ' WHERE Id = :subscriptionId';
        }
        soql += ' ORDER BY Name ASC LIMIT 500';
        return Database.query(soql);
    }

    private static SubscriptionSummary toSummary(CR_Subscription__c s, Integer recipientCount) {
        SubscriptionSummary dto = new SubscriptionSummary();
        dto.id = s.Id;
        dto.name = s.Name;
        dto.reportDefinitionId = s.Report_Definition__c;
        dto.dashboardId = s.Dashboard__c;
        if (s.Dashboard__c != null) {
            dto.assetType = 'Dashboard';
            dto.assetName = (s.Dashboard__r != null) ? s.Dashboard__r.Name : null;
        } else if (s.Report_Definition__c != null) {
            dto.assetType = 'Report';
            dto.assetName = (s.Report_Definition__r != null) ? s.Report_Definition__r.Name : null;
        }
        dto.frequency = s.Frequency__c;
        dto.dayOfWeek = s.Day_Of_Week__c;
        dto.dayOfMonth = s.Day_Of_Month__c;
        dto.hourOfDay = s.Hour_Of_Day__c;
        dto.active = s.Active__c;
        dto.lastStatus = s.Last_Status__c;
        dto.lastRunAt = s.Last_Run_At__c;
        dto.lastMessage = s.Last_Message__c;
        dto.nextRunAt = s.Next_Run_At__c;
        dto.includeHtmlTable = s.Include_HTML_Table__c;
        dto.includeCsvAttachment = s.Include_CSV_Attachment__c;
        dto.maxInlineRows = s.Max_Inline_Rows__c;
        dto.sendIfEmpty = s.Send_If_Empty__c;
        dto.filterOverrideJson = s.Filter_Override_JSON__c;
        dto.recipientCount = recipientCount;
        return dto;
    }

    public class SubscriptionSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String assetType;
        @AuraEnabled public String assetName;
        @AuraEnabled public Id reportDefinitionId;
        @AuraEnabled public Id dashboardId;
        @AuraEnabled public String frequency;
        @AuraEnabled public String dayOfWeek;
        @AuraEnabled public Decimal dayOfMonth;
        @AuraEnabled public Decimal hourOfDay;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String lastStatus;
        @AuraEnabled public Datetime lastRunAt;
        @AuraEnabled public String lastMessage;
        @AuraEnabled public Datetime nextRunAt;
        @AuraEnabled public Boolean includeHtmlTable;
        @AuraEnabled public Boolean includeCsvAttachment;
        @AuraEnabled public Decimal maxInlineRows;
        @AuraEnabled public Boolean sendIfEmpty;
        @AuraEnabled public String filterOverrideJson;
        @AuraEnabled public Integer recipientCount;
    }

    public class RecipientDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String recipientType;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String email;
        @AuraEnabled public String groupId;
        @AuraEnabled public String groupName;
    }

    public class AssetOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String assetType;
        @AuraEnabled public Boolean broadcastSafe;
        public AssetOption(Id id, String name, String assetType, Boolean broadcastSafe) {
            this.id = id;
            this.name = name;
            this.assetType = assetType;
            this.broadcastSafe = broadcastSafe;
        }
    }

    public class SubscriptionInput {
        public String id;
        public String reportDefinitionId;
        public String dashboardId;
        public String frequency;
        public String dayOfWeek;
        public Decimal dayOfMonth;
        public Decimal hourOfDay;
        public Boolean active;
        public Boolean includeHtmlTable;
        public Boolean includeCsvAttachment;
        public Decimal maxInlineRows;
        public Boolean sendIfEmpty;
        public String filterOverrideJson;
    }

    public class RecipientInput {
        public String id;
        public String subscriptionId;
        public String recipientType;
        public String userId;
        public String email;
        public String groupId;
        public String groupName;
    }
}