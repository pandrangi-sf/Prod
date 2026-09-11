import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference } from 'lightning/navigation';
import { applyBrandTheme } from 'c/crBrandTheme';
import submitFeedback from '@salesforce/apex/CR_FeedbackService.submitFeedback';
import listMyFeedback from '@salesforce/apex/CR_FeedbackService.listMyFeedback';

const TYPE_OPTIONS = [
    { label: 'Something is broken', value: 'Bug' },
    { label: 'Idea or improvement', value: 'Idea' },
    { label: 'Question', value: 'Question' },
    { label: "What's working well", value: 'Praise' }
];

// What each status means to the person who submitted it — the admin console's wording
// ("New / Reviewed / Closed") means nothing to a rep waiting to hear back.
const STATUS_DISPLAY = {
    New: { label: 'Waiting for review', tone: 'warning', note: 'The reporting team has it and has not looked at it yet.' },
    Reviewed: { label: 'Reviewed', tone: 'info', note: 'The reporting team has read this and is looking into it.' },
    Closed: { label: 'Closed', tone: 'success', note: 'The reporting team has wrapped this one up.' }
};

export default class CrFeedback extends LightningElement {
    @track type = 'Idea';
    @track subject = '';
    @track details = '';
    @track pageContext = '';

    @track sending = false;
    @track submitted = false;
    @track submittedName = '';
    @track myFeedback = [];

    connectedCallback() {
        applyBrandTheme(this);
        this.loadMyFeedback();
    }

    // When the tab is opened from a report (?c__report=Name), pre-fill what the feedback
    // is about so the team is not left guessing which screen the user was looking at.
    @wire(CurrentPageReference)
    capturePageContext(ref) {
        const fromUrl = ref && ref.state && ref.state.c__report;
        if (fromUrl && !this.pageContext) {
            this.pageContext = fromUrl;
        }
    }

    // Read through every time rather than via a cacheable wire: when an admin marks an item
    // Reviewed or Closed, nothing invalidates the client cache, and the submitter would keep
    // seeing "Waiting for review" for the rest of their session.
    async loadMyFeedback() {
        try {
            const rows = await listMyFeedback();
            this.myFeedback = (rows || []).map((r) => {
                const display = STATUS_DISPLAY[r.status] || STATUS_DISPLAY.New;
                return {
                    ...r,
                    statusLabel: display.label,
                    statusTone: display.tone,
                    statusNote: display.note,
                    isAnswered: r.status !== 'New',
                    updatedOn: r.updatedDate
                        ? new Date(r.updatedDate).toLocaleDateString()
                        : null
                };
            });
        } catch (e) {
            // The form itself still works if the history can't be read — don't block submitting.
            this.myFeedback = [];
        }
    }

    get typeOptions() {
        return TYPE_OPTIONS;
    }

    get hasHistory() {
        return this.myFeedback && this.myFeedback.length > 0;
    }

    handleType(e) {
        this.type = e.detail.value;
    }
    handleSubject(e) {
        this.subject = e.detail.value;
    }
    handleDetails(e) {
        this.details = e.detail.value;
    }
    handlePageContext(e) {
        this.pageContext = e.detail.value;
    }

    async handleSubmit() {
        const subjectInput = this.template.querySelector('lightning-input[data-id="subject"]');
        if (!this.subject || !this.subject.trim()) {
            this.toast('Add a subject', 'Tell us in one line what this is about.', 'warning');
            if (subjectInput) subjectInput.reportValidity();
            return;
        }

        this.sending = true;
        try {
            await submitFeedback({
                payloadJson: JSON.stringify({
                    type: this.type,
                    subject: this.subject.trim(),
                    details: this.details,
                    pageContext: this.pageContext
                })
            });
            this.submittedName = this.subject.trim();
            this.submitted = true;
            this.toast('Feedback sent', 'The Vital Reports team has been emailed. Thank you.', 'success');
            await this.loadMyFeedback();
        } catch (e) {
            this.toast('Could not send feedback', this.errorText(e), 'error');
        } finally {
            this.sending = false;
        }
    }

    handleReset() {
        this.submitted = false;
        this.subject = '';
        this.details = '';
        this.pageContext = '';
        this.type = 'Idea';
    }

    errorText(e) {
        if (!e) return 'Something went wrong. Please try again.';
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return 'Something went wrong. Please try again.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}