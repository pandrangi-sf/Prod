import { LightningElement, track } from 'lwc';
import listStandardReports from '@salesforce/apex/CR_StandardReportImportService.listStandardReports';
import importStandardReport from '@salesforce/apex/CR_StandardReportImportService.importStandardReport';

const MIN_SEARCH_CHARS = 2;

export default class CrStandardReportPicker extends LightningElement {
    @track items = [];
    @track selectedReportId;
    @track searchLoading = false;
    @track importLoading = false;
    @track errorMessage;
    @track warnings = [];

    _reportSearchRequest = 0;

    get hasWarnings() {
        return this.warnings && this.warnings.length > 0;
    }

    get warningRows() {
        return (this.warnings || []).map((text, idx) => ({ id: `w_${idx}`, text }));
    }

    async handleReportSearch(event) {
        const searchTerm = (event.detail.searchTerm || '').trim();
        const requestId = ++this._reportSearchRequest;

        if (searchTerm.length < MIN_SEARCH_CHARS) {
            this.items = [];
            this.searchLoading = false;
            return;
        }

        this.searchLoading = true;
        try {
            const reports = await listStandardReports({ searchTerm });
            if (requestId !== this._reportSearchRequest) {
                return;
            }
            this.items = (reports || []).map((report) => ({
                value: report.id,
                label: report.name,
                meta: this.formatMeta(report)
            }));
            this.errorMessage = null;
        } catch (error) {
            if (requestId === this._reportSearchRequest) {
                this.items = [];
                this.errorMessage = error?.body?.message || 'Could not load standard reports.';
            }
        } finally {
            if (requestId === this._reportSearchRequest) {
                this.searchLoading = false;
            }
        }
    }

    formatMeta(report) {
        const parts = [];
        if (report.format) parts.push(report.format);
        if (report.folderName) parts.push(report.folderName);
        return parts.join(' - ');
    }

    async handleSelectionChange(event) {
        const reportId = event.detail.value;
        this.selectedReportId = reportId;
        this.warnings = [];
        if (!reportId) return;

        this.importLoading = true;
        this.errorMessage = null;
        try {
            const result = await importStandardReport({ reportId });
            this.warnings = result.warnings || [];
            this.dispatchEvent(
                new CustomEvent('import', {
                    detail: {
                        reportName: result.reportName,
                        sourceReportId: result.sourceReportId,
                        format: result.format,
                        primaryObject: result.primaryObject,
                        reportType: result.reportType,
                        definitionJson: result.definitionJson,
                        warnings: result.warnings || []
                    }
                })
            );
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Could not import report.';
        } finally {
            this.importLoading = false;
        }
    }
}