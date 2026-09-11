/**
 * Feedback: any Vital Reports user can send the reporting team a bug, idea, question,
 * or a note about what's working. Every submission is saved as a CR_Feedback__c record
 * (so nothing is lost if mail fails) and emailed to the reporting team.
 *
 * Recipients live in the CR_Report_Feature_Flag__mdt record "Feedback_Recipients"
 * (Settings_JSON__c = {"to":[...]}) so the list can be changed in Setup without a deploy.
 * Setting that record's Is_Enabled__c to false stops the emails but still saves the feedback.
 *
 * Deliberately free of CRUD/FLS describe gates: this object is created by the same deploy
 * that runs these tests, and a brand-new object grant is not yet visible to describe during
 * that run — gating on it would fail the deploy that introduces it. Access is enforced by
 * the perm sets (object + tab) and by `with sharing` on reads.
 */
public with sharing class CR_FeedbackService {

    private static final String RECIPIENT_FLAG = 'Feedback_Recipients';
    // Used only if the custom metadata record is missing (e.g. a scratch org).
    private static final List<String> FALLBACK_RECIPIENTS = new List<String>{
        'sai.pandrangi@orlandohealth.com',
        'brendan.murphy@orlandohealth.com'
    };

    @AuraEnabled
    public static Id submitFeedback(String payloadJson) {
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No feedback to submit.');
        }
        FeedbackInput input;
        try {
            input = (FeedbackInput) JSON.deserialize(payloadJson, FeedbackInput.class);
        } catch (Exception e) {
            throw new AuraHandledException('That feedback could not be read. Please try again.');
        }
        if (String.isBlank(input.subject)) {
            throw new AuraHandledException('Add a short subject so we know what this is about.');
        }

        CR_Feedback__c fb = new CR_Feedback__c(
            Status__c = 'New',
            Type__c = String.isBlank(input.type) ? 'Idea' : input.type,
            Subject__c = input.subject.length() > 120 ? input.subject.substring(0, 120) : input.subject,
            Details__c = input.details,
            Page_Context__c = truncate(input.pageContext, 255)
        );
        try {
            insert fb;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }

        // Re-query for the auto-number Name (FB-#####) — it is not populated on the
        // in-memory record right after insert, which would put "null" in the subject line.
        fb = [
            SELECT Id, Name, Type__c, Subject__c, Details__c, Page_Context__c, CreatedDate
            FROM CR_Feedback__c WHERE Id = :fb.Id LIMIT 1
        ];
        notifyTeam(fb);
        return fb.Id;
    }

    // NOT cacheable on purpose: an admin changing a feedback's status does not invalidate the
    // Lightning client cache, so a cacheable version would keep showing the submitter "New"
    // long after their item was reviewed. This is called once per page load — cheap enough to
    // always read through.
    @AuraEnabled
    public static List<FeedbackDto> listMyFeedback() {
        List<FeedbackDto> out = new List<FeedbackDto>();
        for (CR_Feedback__c f : [
            SELECT Id, Name, Type__c, Subject__c, Details__c, Status__c,
                   CreatedDate, LastModifiedDate
            FROM CR_Feedback__c
            WHERE OwnerId = :UserInfo.getUserId()
            ORDER BY CreatedDate DESC
            LIMIT 25
        ]) {
            FeedbackDto d = new FeedbackDto();
            d.id = f.Id;
            d.name = f.Name;
            d.type = f.Type__c;
            d.subject = f.Subject__c;
            d.details = f.Details__c;
            d.status = f.Status__c;
            d.createdDate = f.CreatedDate;
            // Surfaced to the submitter as "Reviewed on ..." / "Closed on ..." so an admin's
            // status change is visible on their side, not just in the admin console.
            d.updatedDate = f.LastModifiedDate;
            out.add(d);
        }
        return out;
    }

    // ---------- notification ----------

    // Fail-soft by design: the feedback record is already committed, so a mail failure
    // (deliverability off in a sandbox, no email capacity, bad address) must never surface
    // to the user as a failed submission.
    private static void notifyTeam(CR_Feedback__c fb) {
        try {
            List<String> to = resolveRecipients();
            if (to.isEmpty()) return;

            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(to);
            m.setSubject('[Vital Reports] ' + typeLabel(fb.Type__c) + ' from ' + UserInfo.getName() + ': ' + fb.Subject__c);
            m.setPlainTextBody(buildBody(fb));
            m.setSaveAsActivity(false);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m }, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CR_FeedbackService email suppressed: ' + e.getMessage());
        }
    }

    @TestVisible
    private static String buildBody(CR_Feedback__c fb) {
        String link = '';
        try {
            link = URL.getOrgDomainUrl().toExternalForm() + '/' + fb.Id;
        } catch (Exception e) {
            link = String.valueOf(fb.Id);
        }
        List<String> lines = new List<String>{
            fb.Name + ' — ' + typeLabel(fb.Type__c),
            '',
            'From:    ' + UserInfo.getName() + ' (' + UserInfo.getUserEmail() + ')',
            'Subject: ' + fb.Subject__c
        };
        if (String.isNotBlank(fb.Page_Context__c)) {
            lines.add('Where:   ' + fb.Page_Context__c);
        }
        lines.add('');
        lines.add(String.isBlank(fb.Details__c) ? '(No details given.)' : fb.Details__c);
        lines.add('');
        lines.add('Open in Salesforce: ' + link);
        return String.join(lines, '\n');
    }

    // Recipients come from the Feedback_Recipients feature-flag record so they can be
    // changed in Setup. Is_Enabled__c = false turns the emails off without code changes.
    @TestVisible
    private static List<String> resolveRecipients() {
        List<CR_Report_Feature_Flag__mdt> flags = [
            SELECT Is_Enabled__c, Settings_JSON__c
            FROM CR_Report_Feature_Flag__mdt
            WHERE Feature_Key__c = :RECIPIENT_FLAG
            LIMIT 1
        ];
        if (flags.isEmpty()) {
            return FALLBACK_RECIPIENTS;
        }
        if (flags[0].Is_Enabled__c == false) {
            return new List<String>();
        }
        List<String> to = new List<String>();
        try {
            Map<String, Object> settings =
                (Map<String, Object>) JSON.deserializeUntyped(flags[0].Settings_JSON__c);
            Object addrs = settings.get('to');
            if (addrs instanceof List<Object>) {
                for (Object a : (List<Object>) addrs) {
                    String addr = String.valueOf(a).trim();
                    if (String.isNotBlank(addr)) to.add(addr);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CR_FeedbackService bad recipient JSON: ' + e.getMessage());
        }
        return to.isEmpty() ? FALLBACK_RECIPIENTS : to;
    }

    private static String typeLabel(String type) {
        if (type == 'Bug') return 'Something is broken';
        if (type == 'Question') return 'Question';
        if (type == 'Praise') return 'Working well';
        return 'Idea';
    }

    private static String truncate(String s, Integer max) {
        if (String.isBlank(s)) return null;
        return s.length() > max ? s.substring(0, max) : s;
    }

    // ---------- DTOs ----------
    public class FeedbackInput {
        public String type;
        public String subject;
        public String details;
        public String pageContext;
    }

    public class FeedbackDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String subject;
        @AuraEnabled public String details;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime updatedDate;
    }
}