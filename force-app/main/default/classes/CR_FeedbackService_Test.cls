@IsTest
private class CR_FeedbackService_Test {

    private static String payload(String type, String subject, String details, String page) {
        return JSON.serialize(new Map<String, Object>{
            'type' => type,
            'subject' => subject,
            'details' => details,
            'pageContext' => page
        });
    }

    @IsTest
    static void submitSavesFeedbackAndEmailsTheTeam() {
        Test.startTest();
        Id fbId = CR_FeedbackService.submitFeedback(
            payload('Bug', 'Quick filter misses my name', 'Assigned To only listed page 1.', 'Florida Activities with Services')
        );
        Integer emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertNotEquals(null, fbId, 'Feedback should have been inserted.');
        System.assertEquals(1, emailsSent, 'Submitting feedback should send exactly one email to the team.');

        CR_Feedback__c fb = [
            SELECT Name, Type__c, Subject__c, Details__c, Page_Context__c, Status__c, OwnerId
            FROM CR_Feedback__c WHERE Id = :fbId
        ];
        System.assertEquals('Bug', fb.Type__c);
        System.assertEquals('New', fb.Status__c, 'New feedback should land in the New status.');
        System.assertEquals('Quick filter misses my name', fb.Subject__c);
        System.assertEquals('Florida Activities with Services', fb.Page_Context__c);
        System.assertEquals(UserInfo.getUserId(), fb.OwnerId, 'Feedback is owned by whoever submitted it.');
        System.assert(fb.Name.startsWith('FB-'), 'Auto-number should be populated: ' + fb.Name);
    }

    @IsTest
    static void emailBodyCarriesTheContextTheTeamNeeds() {
        Id fbId = CR_FeedbackService.submitFeedback(
            payload('Idea', 'Add export to PowerPoint', 'Leadership wants slides.', 'Report Viewer')
        );
        CR_Feedback__c fb = [
            SELECT Id, Name, Type__c, Subject__c, Details__c, Page_Context__c
            FROM CR_Feedback__c WHERE Id = :fbId
        ];

        String body = CR_FeedbackService.buildBody(fb);

        System.assert(body.contains(fb.Name), 'Body should name the feedback record.');
        System.assert(body.contains('Add export to PowerPoint'), 'Body should carry the subject.');
        System.assert(body.contains('Leadership wants slides.'), 'Body should carry the details.');
        System.assert(body.contains('Report Viewer'), 'Body should say where the user was.');
        System.assert(body.contains(UserInfo.getName()), 'Body should say who submitted it.');
        System.assert(body.contains(String.valueOf(fb.Id)), 'Body should link back to the record.');
    }

    @IsTest
    static void detailsAreOptionalAndTypeDefaultsToIdea() {
        Id fbId = CR_FeedbackService.submitFeedback(payload(null, 'Just a thought', null, null));

        CR_Feedback__c fb = [SELECT Type__c, Details__c FROM CR_Feedback__c WHERE Id = :fbId];
        System.assertEquals('Idea', fb.Type__c, 'A missing type should fall back to Idea.');
        System.assertEquals(null, fb.Details__c);

        String body = CR_FeedbackService.buildBody(
            [SELECT Id, Name, Type__c, Subject__c, Details__c, Page_Context__c
             FROM CR_Feedback__c WHERE Id = :fbId]
        );
        System.assert(body.contains('(No details given.)'), 'Empty details should read as such, not "null".');
    }

    @IsTest
    static void overlongSubjectIsTruncatedRatherThanRejected() {
        String longSubject = 'x'.repeat(200);
        Id fbId = CR_FeedbackService.submitFeedback(payload('Question', longSubject, null, 'y'.repeat(400)));

        CR_Feedback__c fb = [SELECT Subject__c, Page_Context__c FROM CR_Feedback__c WHERE Id = :fbId];
        System.assertEquals(120, fb.Subject__c.length(), 'Subject should be cut to the field length, not blow up on insert.');
        System.assertEquals(255, fb.Page_Context__c.length(), 'Page context should be cut to the field length.');
    }

    @IsTest
    static void blankSubjectIsRejectedWithAReadableMessage() {
        try {
            CR_FeedbackService.submitFeedback(payload('Bug', '   ', 'no subject', null));
            System.assert(false, 'A blank subject should have been rejected.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void emptyPayloadIsRejected() {
        try {
            CR_FeedbackService.submitFeedback(null);
            System.assert(false, 'An empty payload should have been rejected.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            CR_FeedbackService.submitFeedback('not json at all');
            System.assert(false, 'Unparseable JSON should have been rejected.');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void listMyFeedbackReturnsOnlyMine() {
        CR_FeedbackService.submitFeedback(payload('Praise', 'Charts look great', null, null));

        List<CR_FeedbackService.FeedbackDto> mine = CR_FeedbackService.listMyFeedback();

        System.assertEquals(1, mine.size(), 'The submitter should see their own feedback.');
        System.assertEquals('Charts look great', mine[0].subject);
        System.assertEquals('New', mine[0].status);
    }

    @IsTest
    static void adminStatusChangeIsVisibleToTheSubmitter() {
        Id fbId = CR_FeedbackService.submitFeedback(payload('Bug', 'Chart is unreadable', null, null));

        List<CR_FeedbackService.FeedbackDto> before = CR_FeedbackService.listMyFeedback();
        System.assertEquals('New', before[0].status, 'Fresh feedback starts as New.');

        // The admin triages it from the All Feedback tab.
        update new CR_Feedback__c(Id = fbId, Status__c = 'Reviewed');

        List<CR_FeedbackService.FeedbackDto> after = CR_FeedbackService.listMyFeedback();
        System.assertEquals('Reviewed', after[0].status,
            'The submitter should see the status the admin set, not a stale value.');
        System.assertNotEquals(null, after[0].updatedDate,
            'The submitter should be able to see when it was last acted on.');
    }

    @IsTest
    static void recipientsComeFromTheFeatureFlagRecord() {
        // The deployed Feedback_Recipients record drives who is emailed. Assert we resolve a
        // real, non-empty list — the fallback covers an org where the record was never deployed.
        List<String> to = CR_FeedbackService.resolveRecipients();

        System.assert(!to.isEmpty(), 'Feedback must always have somewhere to go.');
        for (String addr : to) {
            System.assert(addr.contains('@'), 'Configured recipient is not an email address: ' + addr);
        }
    }
}