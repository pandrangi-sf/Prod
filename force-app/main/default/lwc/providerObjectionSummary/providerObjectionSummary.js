import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getObjectionSummary from '@salesforce/apex/ProviderObjectionSummaryController.getObjectionSummary';

const NOTES_TRUNCATE = 120;

// Column order set by the PRM team: what/when first, then where and what was
// raised, then the detail, then who recorded it.
const COLUMNS_BEFORE_NOTES = [
    // Button rather than a url column: NavigationMixin builds the target at
    // click time, so no org URL is ever hard-coded.
    { label: 'Visit Report', type: 'button', initialWidth: 125,
      typeAttributes: { label: { fieldName: 'visitReportName' }, variant: 'base',
                        name: 'openVisitReport' } },
    { label: 'Visit Date', fieldName: 'visitDate', type: 'date-local', initialWidth: 120,
      sortable: true, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
    { label: 'Facility', fieldName: 'facility', type: 'text', initialWidth: 160, sortable: true },
    { label: 'Objection', fieldName: 'objection', type: 'text', initialWidth: 160, sortable: true }
];

const NOTES_COLUMN = { label: 'Notes', fieldName: 'notesDisplay', type: 'text', wrapText: true, sortable: true };

const COLUMNS_AFTER_NOTES = [
    { label: 'Created By', fieldName: 'createdByName', type: 'text', initialWidth: 150, sortable: true },
    // Datetime, so the time is shown alongside the date.
    { label: 'Created Date', fieldName: 'createdDate', type: 'date', initialWidth: 175,
      sortable: true, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
                                        hour: '2-digit', minute: '2-digit' } }
];

export default class ProviderObjectionSummary extends NavigationMixin(LightningElement) {
    @api recordId;

    // Defaults to all time. There is no date filter on this list any more, so a
    // rolling window would silently hide older objections with no way to reveal
    // them. Still configurable per placement in App Builder.
    @api monthsBack = 0;
    @api rowLimit = 500;
    // Kept because the component is already placed on PRMProviderLayout and
    // Salesforce refuses to drop a design property that is in use. LWC forbids a
    // public Boolean defaulting to true, so undefined means enabled.
    @api showNotes;

    activeMonths = 0;
    activeRowLimit = 500;
    notesExpanded = false;

    // Apex already returns newest visit first; this mirrors that as the starting
    // state so the header arrow matches what is on screen.
    sortedBy = 'visitDate';
    sortDirection = 'desc';

    summary;
    error;
    loading = true;
    wiredResult;

    connectedCallback() {
        const months = parseInt(this.monthsBack, 10);
        this.activeMonths = Number.isFinite(months) ? months : 0;
        const limit = parseInt(this.rowLimit, 10);
        this.activeRowLimit = Number.isFinite(limit) ? limit : 500;
    }

    @wire(getObjectionSummary, {
        providerId: '$recordId',
        monthsBack: '$activeMonths',
        rowLimit: '$activeRowLimit'
    })
    wiredSummary(result) {
        // Retained so the refresh action can re-provision a cacheable wire.
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.summary = data;
            this.error = undefined;
            this.loading = false;
        } else if (error) {
            this.summary = undefined;
            this.error = this.reduceError(error);
            this.loading = false;
        }
    }

    get showNotesColumn() {
        return this.showNotes === undefined || this.showNotes === true || this.showNotes === 'true';
    }

    get columns() {
        return this.showNotesColumn
            ? [...COLUMNS_BEFORE_NOTES, NOTES_COLUMN, ...COLUMNS_AFTER_NOTES]
            : [...COLUMNS_BEFORE_NOTES, ...COLUMNS_AFTER_NOTES];
    }

    get isPhone() {
        return FORM_FACTOR === 'Small';
    }

    get isDesktop() {
        return !this.isPhone;
    }

    get rows() {
        if (!this.summary || !this.summary.rows) {
            return [];
        }
        const mapped = this.summary.rows.map((r) => {
            const notes = r.notes || '';
            const truncated = notes.length > NOTES_TRUNCATE;
            return {
                ...r,
                notesDisplay: this.notesExpanded || !truncated
                    ? notes
                    : `${notes.substring(0, NOTES_TRUNCATE)}…`,
                notesTruncated: truncated,
                badgeClass: r.source === 'Legacy activity'
                    ? 'slds-badge slds-theme_warning'
                    : 'slds-badge slds-theme_success'
            };
        });
        return this.sortRows(mapped);
    }

    /**
     * Client-side sort over the loaded rows. Blanks always sort last regardless
     * of direction, so an empty Facility or a missing note never pushes real
     * data off the top of the list.
     */
    sortRows(rows) {
        const field = this.sortedBy;
        if (!field) {
            return rows;
        }
        const direction = this.sortDirection === 'asc' ? 1 : -1;
        return [...rows].sort((a, b) => {
            let left = a[field];
            let right = b[field];
            const leftBlank = left === null || left === undefined || left === '';
            const rightBlank = right === null || right === undefined || right === '';
            if (leftBlank && rightBlank) {
                return 0;
            }
            if (leftBlank) {
                return 1;
            }
            if (rightBlank) {
                return -1;
            }
            if (typeof left === 'string' && typeof right === 'string') {
                left = left.toLowerCase();
                right = right.toLowerCase();
            }
            if (left === right) {
                return 0;
            }
            return (left > right ? 1 : -1) * direction;
        });
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.loading && !this.error && this.rows.length === 0;
    }

    get countLabel() {
        const total = this.rows.length;
        return `${total} objection${total === 1 ? '' : 's'}`;
    }

    get isTruncated() {
        return this.summary ? this.summary.truncated === true : false;
    }

    get truncationMessage() {
        return `Only the first ${this.activeRowLimit} objections were loaded.`;
    }

    get anyNotesTruncated() {
        return this.rows.some((r) => r.notesTruncated);
    }

    get notesToggleLabel() {
        return this.notesExpanded ? 'Collapse notes' : 'Expand notes';
    }

    handleToggleNotes() {
        this.notesExpanded = !this.notesExpanded;
    }

    async handleRefresh() {
        this.loading = true;
        try {
            await refreshApex(this.wiredResult);
        } catch (e) {
            this.error = this.reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'openVisitReport') {
            this.navigateToVisitReport(event.detail.row.visitReportId);
        }
    }

    handleCardLinkClick(event) {
        this.navigateToVisitReport(event.currentTarget.dataset.id);
    }

    navigateToVisitReport(visitReportId) {
        if (!visitReportId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: visitReportId, actionName: 'view' }
        });
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
}
