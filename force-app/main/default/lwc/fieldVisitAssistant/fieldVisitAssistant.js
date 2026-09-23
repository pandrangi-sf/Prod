import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCatalog from '@salesforce/apex/CR_FieldAssistant.getCatalog';
import searchProviders from '@salesforce/apex/CR_FieldAssistant.searchProviders';
import extractVisit from '@salesforce/apex/CR_FieldAssistant.extractVisit';
import saveVisit from '@salesforce/apex/CR_FieldAssistant.saveVisit';

const GREETING = 'Just finished a visit? Tell me how it went and I will write up the report.';

export default class FieldVisitAssistant extends LightningElement {
    // Set by the utility bar; it titles the docked item with this.
    @api label = 'Log a Visit';

    @track messages = [];
    @track draft;
    @track providerOptions = [];

    transcript = '';
    providerId;
    providerTerm = '';
    recordTypeId;
    catalog;

    listening = false;
    busy = false;
    confirming = false;
    editing = false;

    recognition;
    providerTimer;
    messageSeq = 0;

    connectedCallback() {
        this.say('bot', GREETING);
    }

    @wire(getCatalog)
    wiredCatalog({ data, error }) {
        if (data) {
            this.catalog = data;
            if (data.recordTypes && data.recordTypes.length) {
                this.recordTypeId = data.recordTypes[0].id;
            }
            if (!data.aiConfigured) {
                this.say(
                    'bot',
                    'Heads up: no AI provider is configured yet, so I cannot draft reports. ' +
                        'An admin needs to add a CR_AI_Provider__c record first.'
                );
            }
        } else if (error) {
            this.say('bot', this.readError(error));
        }
    }

    // ---------- conversation ----------

    say(from, text) {
        this.messageSeq += 1;
        this.messages = [
            ...this.messages,
            {
                id: `m${this.messageSeq}`,
                text,
                cssClass: from === 'bot' ? 'bubble bubble_bot' : 'bubble bubble_user'
            }
        ];
    }

    renderedCallback() {
        const log = this.template.querySelector('.log');
        if (log) {
            log.scrollTop = log.scrollHeight;
        }
    }

    // ---------- derived state ----------

    get aiUnavailable() {
        return this.catalog && !this.catalog.aiConfigured;
    }

    get sendDisabled() {
        return this.busy || !this.transcript || this.transcript.trim().length < 10 || this.aiUnavailable;
    }

    get micLabel() {
        return this.listening ? 'Stop' : 'Speak';
    }

    get micVariant() {
        return this.listening ? 'brand' : 'neutral';
    }

    get speechUnsupported() {
        return !(window.SpeechRecognition || window.webkitSpeechRecognition);
    }

    get showComposer() {
        return !this.confirming;
    }

    get showDetails() {
        return this.confirming && this.editing && this.draft;
    }

    get detailsLabel() {
        return this.editing ? 'Hide details' : 'Edit details';
    }

    get recordTypeOptions() {
        const rts = this.catalog && this.catalog.recordTypes ? this.catalog.recordTypes : [];
        return rts.map((e) => ({ label: e.name, value: e.id }));
    }

    get visitTypeOptions() {
        return this.options(this.catalog && this.catalog.visitTypes);
    }
    get categoryOptions() {
        return this.options(this.catalog && this.catalog.categories);
    }
    get purposeOptions() {
        return this.options(this.catalog && this.catalog.purposes);
    }
    get audienceOptions() {
        return this.options(this.catalog && this.catalog.audiences);
    }
    get mealOptions() {
        return this.options(this.catalog && this.catalog.mealOptions);
    }

    options(values) {
        return (values || []).map((v) => ({ label: v, value: v }));
    }

    // ---------- dictation ----------

    handleTranscript(event) {
        this.transcript = event.target.value;
    }

    toggleMic() {
        if (this.listening) {
            this.stopMic();
        } else {
            this.startMic();
        }
    }

    startMic() {
        const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!Recognition) {
            this.say('bot', 'Dictation is not available in this browser — type it instead.');
            return;
        }
        this.recognition = new Recognition();
        this.recognition.continuous = true;
        this.recognition.interimResults = false;
        this.recognition.lang = 'en-US';

        this.recognition.onresult = (event) => {
            let heard = '';
            for (let i = event.resultIndex; i < event.results.length; i++) {
                heard += event.results[i][0].transcript;
            }
            this.transcript = `${this.transcript} ${heard}`.trim();
        };
        this.recognition.onerror = (event) => {
            this.say('bot', `Dictation stopped: ${event.error}`);
            this.listening = false;
        };
        this.recognition.onend = () => {
            this.listening = false;
        };

        this.recognition.start();
        this.listening = true;
    }

    stopMic() {
        if (this.recognition) {
            this.recognition.stop();
        }
        this.listening = false;
    }

    disconnectedCallback() {
        this.stopMic();
    }

    // ---------- draft ----------

    handleSend() {
        const said = this.transcript.trim();
        this.stopMic();
        this.say('user', said);
        this.transcript = '';
        this.busy = true;

        extractVisit({ transcript: said })
            .then((result) => {
                this.draft = { ...result };
                this.confirming = true;
                this.say('bot', this.summarise(result));
                if (result.confidenceNotes && result.confidenceNotes.length) {
                    this.say('bot', `Worth checking: ${result.confidenceNotes.join(' ')}`);
                }
                if (result.providerName) {
                    this.providerTerm = result.providerName;
                    this.lookupProvider(result.providerName);
                }
            })
            .catch((e) => {
                this.say('bot', this.readError(e));
            })
            .finally(() => {
                this.busy = false;
            });
    }

    /** One short paragraph a rep can check at a glance, rather than nine form fields. */
    summarise(d) {
        const parts = [];
        const who = d.providerName ? ` with ${d.providerName}` : '';
        const when = d.visitDate ? ` on ${d.visitDate}` : '';
        parts.push(`Got it — ${d.category || 'visit'}${who}${when}, ${d.visitType || 'in person'}.`);

        if (d.objections && d.objections.length) {
            parts.push(`Objections: ${d.objections.map((o) => o.name).join(', ')}.`);
        }
        if (d.services && d.services.length) {
            parts.push(`Services: ${d.services.join(', ')}.`);
        }
        if (d.collateral && d.collateral.length) {
            parts.push(`Collateral: ${d.collateral.join(', ')}.`);
        }
        return parts.join(' ');
    }

    // ---------- provider ----------

    handleProviderTerm(event) {
        this.providerTerm = event.target.value;
        window.clearTimeout(this.providerTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.providerTimer = window.setTimeout(() => this.lookupProvider(this.providerTerm), 300);
    }

    lookupProvider(term) {
        searchProviders({ term })
            .then((rows) => {
                this.providerOptions = rows.map((r) => ({ label: r.name, value: r.id }));
                if (rows.length === 1) {
                    this.providerId = rows[0].id;
                }
            })
            .catch(() => {
                this.providerOptions = [];
            });
    }

    handleProviderSelect(event) {
        this.providerId = event.detail.value;
    }

    handleRecordType(event) {
        this.recordTypeId = event.detail.value;
    }

    // ---------- edit + save ----------

    toggleDetails() {
        this.editing = !this.editing;
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.draft = { ...this.draft, [field]: event.detail.value };
    }

    handleDiscard() {
        this.clearDraft();
        this.say('bot', 'Dropped that one. Tell me about another visit when you are ready.');
    }

    handleSave() {
        this.busy = true;
        saveVisit({
            draftJson: JSON.stringify(this.draft),
            providerId: this.providerId,
            recordTypeId: this.recordTypeId
        })
            .then((result) => {
                const bits = [];
                if (result.objectionsCreated) {
                    bits.push(`${result.objectionsCreated} objection(s)`);
                }
                if (result.servicesCreated) {
                    bits.push(`${result.servicesCreated} service(s)`);
                }
                if (result.collateralCreated) {
                    bits.push(`${result.collateralCreated} collateral`);
                }
                const detail = bits.length ? ` with ${bits.join(', ')}` : '';

                this.say('bot', `Saved${detail}. Anything else?`);
                this.dispatchEvent(new ShowToastEvent({ title: 'Visit saved', variant: 'success' }));
                this.clearDraft();
            })
            .catch((e) => {
                this.say('bot', this.readError(e));
            })
            .finally(() => {
                this.busy = false;
            });
    }

    clearDraft() {
        this.draft = undefined;
        this.confirming = false;
        this.editing = false;
        this.providerId = undefined;
        this.providerTerm = '';
        this.providerOptions = [];
    }

    readError(e) {
        if (!e) {
            return 'Something went wrong.';
        }
        if (e.body && e.body.message) {
            return e.body.message;
        }
        return e.message || 'Something went wrong.';
    }
}
