import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUploadMonths from '@salesforce/apex/VisitTypeReviewController.getUploadMonths';
import getRecordsByMonth from '@salesforce/apex/VisitTypeReviewController.getRecordsByMonth';
import bulkUpdatePrmReport from '@salesforce/apex/VisitTypeReviewController.bulkUpdatePrmReport';

// Mirrors the LIMIT in VisitTypeReviewController.getRecordsByMonth. If a month
// returns exactly this many rows the list is almost certainly truncated.
const ROW_LIMIT = 2000;

const COLUMNS = [
    { label: 'Visit Type', fieldName: 'EPIC_New_Pt_Visit_Type__c', type: 'text', wrapText: true },
    { label: 'PRM Report', fieldName: 'PRM_Report__c', type: 'text', initialWidth: 120 },
    { label: 'Last Modified By', fieldName: 'lastModifiedByName', type: 'text', initialWidth: 180 },
    {
        label: 'Last Modified Date',
        fieldName: 'LastModifiedDate',
        type: 'date',
        initialWidth: 200,
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    }
];

export default class VisitTypeMonthlyReview extends LightningElement {
    columns = COLUMNS;
    monthOptions = [];
    selectedMonth = '';
    records = [];
    selectedIds = [];
    isLoading = false;
    hasQueried = false;

    @wire(getUploadMonths)
    wiredMonths({ data, error }) {
        if (data) {
            // Apex already returns newest first; preserve that order.
            this.monthOptions = data.map((m) => ({ label: m, value: m }));
        } else if (error) {
            this.monthOptions = [];
            this.showToast('Could not load upload months', this.reduceError(error), 'error');
        }
    }

    handleMonthChange(event) {
        this.selectedMonth = event.detail.value;
        this.clearSelection();
        this.loadRecords();
    }

    async loadRecords() {
        if (!this.selectedMonth) {
            return;
        }
        this.isLoading = true;
        try {
            const data = await getRecordsByMonth({ uploadMonth: this.selectedMonth });
            // lightning-datatable cannot resolve dotted paths such as
            // LastModifiedBy.Name, so flatten it to a plain property.
            this.records = data.map((row) => ({
                ...row,
                lastModifiedByName: row.LastModifiedBy ? row.LastModifiedBy.Name : ''
            }));
            this.hasQueried = true;
        } catch (error) {
            this.records = [];
            this.hasQueried = true;
            this.showToast('Could not load records', this.reduceError(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.Id);
    }

    handleMarkY() {
        this.bulkUpdate('Y');
    }

    handleMarkN() {
        this.bulkUpdate('N');
    }

    async bulkUpdate(value) {
        if (this.selectedIds.length === 0) {
            return;
        }
        const recordIds = [...this.selectedIds];
        this.isLoading = true;
        try {
            const updated = await bulkUpdatePrmReport({ recordIds, value });
            await this.loadRecords();
            this.clearSelection();
            this.showToast('Success', `Updated ${updated} record(s) to ${value}`, 'success');
        } catch (error) {
            this.showToast('Update failed', this.reduceError(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    clearSelection() {
        this.selectedIds = [];
        const table = this.template.querySelector('lightning-datatable');
        if (table) {
            table.selectedRows = [];
        }
    }

    get hasSelection() {
        return this.selectedIds.length > 0;
    }

    get isActionDisabled() {
        return !this.hasSelection || this.isLoading;
    }

    get selectedCountLabel() {
        return `${this.selectedIds.length} selected`;
    }

    get recordCountLabel() {
        const count = this.records.length;
        return `${count} record${count === 1 ? '' : 's'}`;
    }

    get hasMonth() {
        return !!this.selectedMonth;
    }

    get hasRecords() {
        return this.records.length > 0;
    }

    get showEmptyState() {
        return this.hasQueried && !this.isLoading && this.records.length === 0;
    }

    get isTruncated() {
        return this.records.length >= ROW_LIMIT;
    }

    get truncationMessage() {
        return `Showing the first ${ROW_LIMIT} records for ${this.selectedMonth}. This month has more rows than that, so the list below is truncated.`;
    }

    reduceError(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        if (error.message) {
            return error.message;
        }
        return 'Unknown error';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
