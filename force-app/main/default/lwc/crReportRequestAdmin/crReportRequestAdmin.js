import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listAllRequests from '@salesforce/apex/CR_ReportRequestService.listAllRequests';
import updateStatus from '@salesforce/apex/CR_ReportRequestService.updateStatus';
import buildFromRequest from '@salesforce/apex/CR_ReportRequestService.buildFromRequest';

export default class CrReportRequestAdmin extends NavigationMixin(LightningElement) {
    @track requests = [];
    @track selected = null;
    @track adminNotes = '';
    @track busy = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.busy = true;
        try {
            this.requests = (await listAllRequests()).map((r) => ({
                ...r,
                tone: this.tone(r.status),
                rowClass: 'rr-row' + (this.selected && this.selected.id === r.id ? ' rr-row_active' : '')
            }));
        } catch (e) {
            this.toast(this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    get hasRequests() {
        return this.requests.length > 0;
    }
    get hasSelection() {
        return !!this.selected;
    }
    get hasResultingReport() {
        return !!(this.selected && this.selected.resultingReportId);
    }
    get buildLabel() {
        return this.hasResultingReport ? 'Open draft in Builder' : 'Build from request';
    }

    handleSelect(event) {
        const id = event.currentTarget.dataset.id;
        this.selected = this.requests.find((r) => r.id === id) || null;
        this.adminNotes = (this.selected && this.selected.adminNotes) || '';
        this.requests = this.requests.map((r) => ({
            ...r,
            rowClass: 'rr-row' + (r.id === id ? ' rr-row_active' : '')
        }));
    }

    handleNotes(event) {
        this.adminNotes = event.target.value;
    }

    // Create (or reuse) a draft report from the request, then open the Report Builder
    // on it so the admin can finish + save. Builder hydrates via ?c__reportId.
    async handleBuild() {
        if (!this.selected) return;
        this.busy = true;
        try {
            const reportId = await buildFromRequest({ requestId: this.selected.id });
            this.toast('Draft report ready — opening the Report Builder.', 'success');
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Report_Builder' },
                state: { c__reportId: reportId }
            });
            await this.load();
        } catch (e) {
            this.toast(this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleInProgress() {
        this.setStatus('In Progress');
    }
    handleComplete() {
        this.setStatus('Completed');
    }
    handleReject() {
        this.setStatus('Rejected');
    }

    async setStatus(status) {
        if (!this.selected) return;
        this.busy = true;
        try {
            await updateStatus({ requestId: this.selected.id, status, adminNotes: this.adminNotes });
            this.toast(`Request marked ${status}.`, 'success');
            this.selected = null;
            await this.load();
        } catch (e) {
            this.toast(this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    openReport() {
        if (this.selected && this.selected.resultingReportId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selected.resultingReportId,
                    objectApiName: 'Report_Definition__c',
                    actionName: 'view'
                }
            });
        }
    }

    tone(status) {
        if (status === 'Completed') return 'success';
        if (status === 'Rejected') return 'error';
        if (status === 'In Progress') return 'warning';
        return 'neutral';
    }
    toast(message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Report Requests', message, variant }));
    }
    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}