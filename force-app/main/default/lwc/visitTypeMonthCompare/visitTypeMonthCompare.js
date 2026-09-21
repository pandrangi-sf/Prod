import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUploadMonths from '@salesforce/apex/VisitTypeReviewController.getUploadMonths';
import getRecordsByMonth from '@salesforce/apex/VisitTypeReviewController.getRecordsByMonth';

// Rows rendered per side, per page. Each side pages independently.
const PAGE_SIZE = 500;

const COLUMNS = [
    { label: 'Visit Type', fieldName: 'EPIC_New_Pt_Visit_Type__c', type: 'text', wrapText: true },
    { label: 'PRM Report', fieldName: 'PRM_Report__c', type: 'text', initialWidth: 110 }
];

/**
 * Side-by-side comparison of two upload months.
 *
 * Note on semantics: every New_Patient_Visit_Type__c record carries exactly one
 * Upload_Month__c - the month the visit type first appeared - so the two months
 * never share a record. This page therefore compares the SHAPE of the two
 * batches (volume and how the Y/N decisions landed), not per-record changes.
 */
export default class VisitTypeMonthCompare extends LightningElement {
    columns = COLUMNS;
    monthOptions = [];
    monthA = '';
    monthB = '';
    recordsA = [];
    recordsB = [];
    loadingA = false;
    loadingB = false;
    pageA = 1;
    pageB = 1;

    @wire(getUploadMonths)
    wiredMonths({ data, error }) {
        if (data) {
            this.monthOptions = data.map((m) => ({ label: m, value: m }));
            // Default to the two most recent months: B is newest, A the one before.
            if (!this.monthB && data.length > 0) {
                this.monthB = data[0];
                this.loadingB = true;
            }
            if (!this.monthA && data.length > 1) {
                this.monthA = data[1];
                this.loadingA = true;
            }
        } else if (error) {
            this.monthOptions = [];
            this.showToast('Could not load upload months', this.reduceError(error), 'error');
        }
    }

    @wire(getRecordsByMonth, { uploadMonth: '$monthA' })
    wiredA({ data, error }) {
        if (data) {
            this.recordsA = data;
            this.loadingA = false;
            this.pageA = Math.min(this.pageA, this.totalPagesA);
        } else if (error) {
            this.recordsA = [];
            this.loadingA = false;
            this.showToast('Could not load the left month', this.reduceError(error), 'error');
        }
    }

    @wire(getRecordsByMonth, { uploadMonth: '$monthB' })
    wiredB({ data, error }) {
        if (data) {
            this.recordsB = data;
            this.loadingB = false;
            this.pageB = Math.min(this.pageB, this.totalPagesB);
        } else if (error) {
            this.recordsB = [];
            this.loadingB = false;
            this.showToast('Could not load the right month', this.reduceError(error), 'error');
        }
    }

    handleMonthAChange(event) {
        this.monthA = event.detail.value;
        this.pageA = 1;
        this.loadingA = true;
    }

    handleMonthBChange(event) {
        this.monthB = event.detail.value;
        this.pageB = 1;
        this.loadingB = true;
    }

    handlePrevA() {
        if (this.pageA > 1) {
            this.pageA -= 1;
        }
    }

    handleNextA() {
        if (this.pageA < this.totalPagesA) {
            this.pageA += 1;
        }
    }

    handlePrevB() {
        if (this.pageB > 1) {
            this.pageB -= 1;
        }
    }

    handleNextB() {
        if (this.pageB < this.totalPagesB) {
            this.pageB += 1;
        }
    }

    // ---------- stats ----------

    countYes(rows) {
        return rows.filter((r) => r.PRM_Report__c === 'Y').length;
    }

    buildStats(rows) {
        const total = rows.length;
        const yes = this.countYes(rows);
        const no = total - yes;
        const rate = total === 0 ? 0 : Math.round((yes / total) * 1000) / 10;
        return { total, yes, no, rate: `${rate}%` };
    }

    get statsA() {
        return this.buildStats(this.recordsA);
    }

    get statsB() {
        return this.buildStats(this.recordsB);
    }

    signed(value) {
        if (value > 0) {
            return `+${value}`;
        }
        return `${value}`;
    }

    get deltaTotal() {
        return this.signed(this.statsB.total - this.statsA.total);
    }

    get deltaYes() {
        return this.signed(this.statsB.yes - this.statsA.yes);
    }

    get deltaNo() {
        return this.signed(this.statsB.no - this.statsA.no);
    }

    get deltaLabel() {
        return `${this.monthB} vs ${this.monthA}`;
    }

    // ---------- paging ----------

    get pagedA() {
        const start = (this.pageA - 1) * PAGE_SIZE;
        return this.recordsA.slice(start, start + PAGE_SIZE);
    }

    get pagedB() {
        const start = (this.pageB - 1) * PAGE_SIZE;
        return this.recordsB.slice(start, start + PAGE_SIZE);
    }

    get totalPagesA() {
        return Math.max(1, Math.ceil(this.recordsA.length / PAGE_SIZE));
    }

    get totalPagesB() {
        return Math.max(1, Math.ceil(this.recordsB.length / PAGE_SIZE));
    }

    pageLabel(page, total, pages) {
        if (total === 0) {
            return 'No records';
        }
        const start = (page - 1) * PAGE_SIZE + 1;
        const end = Math.min(page * PAGE_SIZE, total);
        return `Page ${page} of ${pages}  -  ${start}-${end} of ${total}`;
    }

    get pageLabelA() {
        return this.pageLabel(this.pageA, this.recordsA.length, this.totalPagesA);
    }

    get pageLabelB() {
        return this.pageLabel(this.pageB, this.recordsB.length, this.totalPagesB);
    }

    get showPagerA() {
        return this.recordsA.length > PAGE_SIZE;
    }

    get showPagerB() {
        return this.recordsB.length > PAGE_SIZE;
    }

    get isFirstPageA() {
        return this.pageA <= 1;
    }

    get isLastPageA() {
        return this.pageA >= this.totalPagesA;
    }

    get isFirstPageB() {
        return this.pageB <= 1;
    }

    get isLastPageB() {
        return this.pageB >= this.totalPagesB;
    }

    // ---------- view state ----------

    get bothMonthsChosen() {
        return !!this.monthA && !!this.monthB;
    }

    get sameMonthChosen() {
        return this.bothMonthsChosen && this.monthA === this.monthB;
    }

    get hasRecordsA() {
        return this.recordsA.length > 0;
    }

    get hasRecordsB() {
        return this.recordsB.length > 0;
    }

    get onlyOneMonthExists() {
        return this.monthOptions.length < 2;
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
