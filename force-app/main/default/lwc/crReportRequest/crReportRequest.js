import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import submitRequest from '@salesforce/apex/CR_ReportRequestService.submitRequest';
import listMyRequests from '@salesforce/apex/CR_ReportRequestService.listMyRequests';

const PRIORITY_OPTIONS = [
    { label: 'Low', value: 'Low' },
    { label: 'Normal', value: 'Normal' },
    { label: 'High', value: 'High' }
];

export default class CrReportRequest extends LightningElement {
    @track primaryObject;
    @track datasetKey;
    @track requestedObjectLabel;
    @track datasetJson;     // builder-native dataset definition (object + fields)
    @track fieldsSummary;
    @track reportTitle = '';
    @track filterNote = '';
    @track description = '';
    @track priority = 'Normal';
    @track busy = false;
    @track myRequests = [];

    priorityOptions = PRIORITY_OPTIONS;

    connectedCallback() {
        this.loadMine();
    }

    get hasFields() {
        return !!this.datasetJson && !!this.fieldsSummary;
    }
    // An object is chosen but no fields yet — prompt the user to pick at least one.
    get objectButNoFields() {
        return !!this.datasetJson && !this.fieldsSummary;
    }
    get canSubmit() {
        return this.hasFields && !this.busy;
    }
    get hasRequests() {
        return this.myRequests.length > 0;
    }

    // Object + fields chosen via the (allowlist-restricted) object/field selector.
    // Capture the full builder-native dataset definition so admins can one-click
    // "Build from request" into the Report Builder later.
    handleFieldsChange(event) {
        this.datasetJson = (event.detail && event.detail.json) || null;
        try {
            const def = (event.detail && event.detail.definition) || JSON.parse(this.datasetJson || '{}');
            const paths = def.fieldPaths || [];
            const labels = def.fieldLabels || {};
            this.fieldsSummary = paths.length ? paths.map((p) => labels[p] || p).join(', ') : null;
            this.primaryObject = def.primaryObject || def.objectApiName || null;
            this.requestedObjectLabel = this.primaryObject;
            this.datasetKey = def.datasetKey || this.primaryObject;
        } catch (e) {
            this.fieldsSummary = null;
        }
    }

    handleField(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
    }

    async handleSubmit() {
        if (!this.primaryObject) {
            this.toast('Pick an object/dataset for the report first.', 'warning');
            return;
        }
        if (!this.datasetJson) {
            this.toast('Select at least one field for the report.', 'warning');
            return;
        }
        this.busy = true;
        const fullDescription = (this.description || '')
            + (this.filterNote ? `\n\nFilters / criteria requested:\n${this.filterNote}` : '');
        try {
            await submitRequest({
                payloadJson: JSON.stringify({
                    reportTitle: this.reportTitle,
                    requestedObject: this.requestedObjectLabel || this.primaryObject,
                    datasetKey: this.datasetKey,
                    datasetJson: this.datasetJson,
                    filtersJson: null,
                    fieldsSummary: this.fieldsSummary,
                    description: fullDescription,
                    priority: this.priority
                })
            });
            this.toast('Request submitted — the reporting team has been notified.', 'success');
            this.resetForm();
            await this.loadMine();
        } catch (e) {
            this.toast(this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    resetForm() {
        this.primaryObject = null;
        this.datasetKey = null;
        this.datasetJson = null;
        this.fieldsSummary = null;
        this.reportTitle = '';
        this.filterNote = '';
        this.description = '';
        this.priority = 'Normal';
    }

    async loadMine() {
        try {
            this.myRequests = (await listMyRequests()).map((r) => ({ ...r, tone: this.tone(r.status) }));
        } catch (e) {
            // non-fatal — the form still works without the history list
        }
    }

    tone(status) {
        if (status === 'Completed') return 'success';
        if (status === 'Rejected') return 'error';
        if (status === 'In Progress') return 'warning';
        return 'neutral';
    }

    toast(message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Report Request', message, variant }));
    }
    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}