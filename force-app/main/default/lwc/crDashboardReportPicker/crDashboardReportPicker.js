import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listReports from '@salesforce/apex/CR_ReportDefinitionService.listReports';

// "Created by Me" ("mine") was removed: the report DTO carries no CreatedById,
// so the filter returned true for every report (a no-op). Re-add it only once
// the server exposes the owner id for a real comparison.
const SCOPES = [
    { value: 'recent',  label: 'Recent' },
    { value: 'private', label: 'Private Reports' },
    { value: 'public',  label: 'Public Reports' },
    { value: 'all',     label: 'All Reports' }
];

const RECENT_DAYS = 30;

export default class CrDashboardReportPicker extends LightningElement {
    @track scope = 'recent';
    @track searchTerm = '';
    @track allReports = [];
    @track loading = true;
    @track selectedReport = null;

    scopes = SCOPES;

    @wire(listReports, { searchTerm: '' })
    wiredReports({ data, error }) {
        if (data) {
            this.allReports = data;
            this.loading = false;
        } else if (error) {
            this.loading = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not load reports',
                message: error?.body?.message || error?.message || 'Unknown error',
                variant: 'error'
            }));
        }
    }

    get scopeOptions() {
        return SCOPES.map((s) => ({
            ...s,
            class: s.value === this.scope
                ? 'scope-item scope-item_active'
                : 'scope-item'
        }));
    }

    // Filter the wired report list down to the active scope + search term.
    get visibleReports() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        const since = Date.now() - RECENT_DAYS * 24 * 60 * 60 * 1000;
        return (this.allReports || [])
            .filter((r) => {
                switch (this.scope) {
                    case 'recent': {
                        const created = r.createdDate ? Date.parse(r.createdDate) : 0;
                        const lastRun = r.lastRunAt ? Date.parse(r.lastRunAt) : 0;
                        return Math.max(created, lastRun) >= since;
                    }
                    case 'private': return r.isPublic === false;
                    case 'public':  return r.isPublic === true;
                    default:        return true;
                }
            })
            .filter((r) => !term || (r.name || '').toLowerCase().includes(term))
            .map((r) => ({
                ...r,
                rowClass: this.selectedReport && this.selectedReport.id === r.id
                    ? 'report-row report-row_selected'
                    : 'report-row',
                folderLabel: r.folder || '—',
                createdLabel: r.createdByName ? `${r.createdByName}` : '—',
                createdDateLabel: r.createdDate ? this.formatDate(r.createdDate) : ''
            }));
    }

    get hasNoResults() {
        return !this.loading && this.visibleReports.length === 0;
    }

    get nextDisabled() {
        return !this.selectedReport;
    }

    handleScopeClick(event) {
        const value = event.currentTarget.dataset.value;
        if (value) this.scope = value;
    }

    handleSearch(event) {
        this.searchTerm = event.detail.value;
    }

    handleRowClick(event) {
        const id = event.currentTarget.dataset.id;
        const report = this.allReports.find((r) => r.id === id);
        if (report) this.selectedReport = report;
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleNext() {
        if (!this.selectedReport) return;
        this.dispatchEvent(new CustomEvent('select', {
            detail: { report: this.selectedReport }
        }));
    }

    formatDate(iso) {
        try {
            const d = new Date(iso);
            return d.toLocaleDateString();
        } catch {
            return '';
        }
    }
}