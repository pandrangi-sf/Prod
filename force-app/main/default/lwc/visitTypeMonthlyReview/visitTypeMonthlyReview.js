import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUploadMonths from '@salesforce/apex/VisitTypeReviewController.getUploadMonths';
import getRecordsByMonth from '@salesforce/apex/VisitTypeReviewController.getRecordsByMonth';
import bulkUpdatePrmReport from '@salesforce/apex/VisitTypeReviewController.bulkUpdatePrmReport';

// Mirrors VisitTypeReviewController.maxRows. If a month returns exactly this
// many rows the list is almost certainly truncated. Keep the two in step.
const ROW_LIMIT = 5000;

// Rows rendered per page. Paging keeps the datatable light instead of putting
// several thousand rows in the DOM at once.
const PAGE_SIZE = 1000;

const FILTER_ALL = 'ALL';

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
    prmFilter = FILTER_ALL;
    pageNumber = 1;

    // Holds the raw wire result so refreshApex() can invalidate the client
    // cache after a bulk update. An imperative call to a cacheable Apex method
    // is served from the Lightning client cache, which is why the list used to
    // keep showing pre-update values until the page was reloaded.
    wiredRecordsResult;

    prmFilterOptions = [
        { label: 'All', value: FILTER_ALL },
        { label: 'N - not in report', value: 'N' },
        { label: 'Y - in report', value: 'Y' }
    ];

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

    @wire(getRecordsByMonth, { uploadMonth: '$selectedMonth' })
    wiredRecords(result) {
        // Keep the whole result (data + error) - refreshApex needs this object,
        // not the destructured data.
        this.wiredRecordsResult = result;

        if (!this.selectedMonth) {
            this.records = [];
            this.hasQueried = false;
            this.isLoading = false;
            return;
        }

        const { data, error } = result;

        if (data) {
            // lightning-datatable cannot resolve dotted paths such as
            // LastModifiedBy.Name, so flatten it to a plain property.
            this.records = data.map((row) => ({
                ...row,
                lastModifiedByName: row.LastModifiedBy ? row.LastModifiedBy.Name : ''
            }));
            this.hasQueried = true;
            this.isLoading = false;
            this.clampPage();
        } else if (error) {
            this.records = [];
            this.hasQueried = true;
            this.isLoading = false;
            this.showToast('Could not load records', this.reduceError(error), 'error');
        }
    }

    handleMonthChange(event) {
        this.selectedMonth = event.detail.value;
        this.clearSelection();
        this.pageNumber = 1;
        // The wire re-provisions on the new month; show the spinner until it does.
        this.isLoading = true;
    }

    handlePrmFilterChange(event) {
        this.prmFilter = event.detail.value;
        this.pageNumber = 1;
        // Rows leaving the view must not stay selected - a hidden selected row
        // would otherwise be included in the next bulk update.
        this.clearSelection();
    }

    handleRowSelection(event) {
        // The datatable only reports the current page, so merge its selection
        // with ids picked on other pages instead of replacing the whole list.
        const pageIds = new Set(this.pagedRecords.map((row) => row.Id));
        const onPage = event.detail.selectedRows.map((row) => row.Id);
        const offPage = this.selectedIds.filter((id) => !pageIds.has(id));
        this.selectedIds = [...offPage, ...onPage];
    }

    handleFirstPage() {
        this.pageNumber = 1;
    }

    handlePreviousPage() {
        if (this.pageNumber > 1) {
            this.pageNumber -= 1;
        }
    }

    handleNextPage() {
        if (this.pageNumber < this.totalPages) {
            this.pageNumber += 1;
        }
    }

    handleLastPage() {
        this.pageNumber = this.totalPages;
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
            // refreshApex busts the cacheable-Apex client cache and re-provisions
            // the wire, so the table shows the values that were just written.
            await refreshApex(this.wiredRecordsResult);
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

    clampPage() {
        const pages = this.totalPages;
        if (this.pageNumber > pages) {
            this.pageNumber = pages;
        }
        if (this.pageNumber < 1) {
            this.pageNumber = 1;
        }
    }

    get visibleRecords() {
        if (this.prmFilter === FILTER_ALL) {
            return this.records;
        }
        return this.records.filter((row) => row.PRM_Report__c === this.prmFilter);
    }

    get pagedRecords() {
        const start = (this.pageNumber - 1) * PAGE_SIZE;
        return this.visibleRecords.slice(start, start + PAGE_SIZE);
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.visibleRecords.length / PAGE_SIZE));
    }

    get showPager() {
        return this.visibleRecords.length > PAGE_SIZE;
    }

    get isFirstPage() {
        return this.pageNumber <= 1;
    }

    get isLastPage() {
        return this.pageNumber >= this.totalPages;
    }

    get pageLabel() {
        const total = this.visibleRecords.length;
        if (total === 0) {
            return 'Page 0 of 0';
        }
        const start = (this.pageNumber - 1) * PAGE_SIZE + 1;
        const end = Math.min(this.pageNumber * PAGE_SIZE, total);
        return `Page ${this.pageNumber} of ${this.totalPages}  -  showing ${start}-${end} of ${total}`;
    }

    get hasSelection() {
        return this.selectedIds.length > 0;
    }

    get isActionDisabled() {
        return !this.hasSelection || this.isLoading;
    }

    get selectedCountLabel() {
        const count = this.selectedIds.length;
        if (count === 0) {
            return '0 selected';
        }
        // Selections survive paging, so say so - the buttons act on all of them.
        return `${count} selected (across all pages)`;
    }

    get recordCountLabel() {
        const shown = this.visibleRecords.length;
        const total = this.records.length;
        if (this.prmFilter === FILTER_ALL) {
            return `${total} record${total === 1 ? '' : 's'}`;
        }
        return `${shown} of ${total} record${total === 1 ? '' : 's'} (PRM Report = ${this.prmFilter})`;
    }

    get hasMonth() {
        return !!this.selectedMonth;
    }

    get hasRecords() {
        return this.records.length > 0;
    }

    get hasVisibleRecords() {
        return this.visibleRecords.length > 0;
    }

    get showEmptyState() {
        return this.hasQueried && !this.isLoading && this.visibleRecords.length === 0;
    }

    get emptyStateMessage() {
        if (this.hasRecords) {
            return `No ${this.selectedMonth} records have PRM Report = ${this.prmFilter}.`;
        }
        return `No New Patient Visit Type records found for ${this.selectedMonth}.`;
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
