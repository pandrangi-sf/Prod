import { LightningElement, api, track } from 'lwc';
import summarizeDashboard from '@salesforce/apex/CR_AIService.summarizeDashboard';

// Phase J1: side panel that renders an AI summary. Parent opens it via the
// imperative open() API and passes a dashboardId. The panel calls
// CR_AIService.summarizeDashboard and renders the heading + body.
// Currently the only consumer is crDashboardViewer's Explain button.
export default class CrAiPanel extends LightningElement {
    @api dashboardId;

    @track _open = false;
    @track _loading = false;
    @track _heading = '';
    @track _body = '';
    @track _isStub = false;
    @track _error = '';

    @api
    async open() {
        this._open = true;
        if (!this.dashboardId) {
            this._error = 'No dashboard context provided.';
            return;
        }
        this._loading = true;
        this._error = '';
        this._heading = '';
        this._body = '';
        try {
            const result = await summarizeDashboard({ dashboardId: this.dashboardId });
            this._heading = result?.heading || 'Summary';
            this._body = result?.body || '(empty response)';
            this._isStub = !!result?.isStub;
        } catch (err) {
            this._error = err?.body?.message || err?.message || 'Could not fetch the summary.';
        } finally {
            this._loading = false;
        }
    }

    @api
    close() {
        this._open = false;
    }

    handleClose() {
        this._open = false;
    }

    get isOpen()      { return this._open; }
    get isLoading()   { return this._loading; }
    get hasError()    { return !!this._error; }
    get hasContent()  { return !this._loading && !this._error && !!this._body; }
    get isStubBadge() { return this._isStub; }
}