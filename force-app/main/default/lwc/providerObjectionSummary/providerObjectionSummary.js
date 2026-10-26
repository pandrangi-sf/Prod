import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getObjectionSummary from '@salesforce/apex/ProviderObjectionSummaryController.getObjectionSummary';

const NOTES_TRUNCATE = 120;

// Column order set by the PRM team: what/when first, then where and what was
// raised, then the detail, then who recorded it. Case and Status follow the
// objection for rows logged as Provider Objection Cases; Source closes the row.
const COLUMNS_BEFORE_NOTES = [
    // Button rather than a url column: NavigationMixin builds the target at
    // click time, so no org URL is ever hard-coded.
    { label: 'Visit Report', type: 'button', initialWidth: 110,
      typeAttributes: { label: { fieldName: 'visitReportName' }, variant: 'base',
                        name: 'openVisitReport' } },
    { label: 'Visit Date', fieldName: 'visitDate', type: 'date-local', initialWidth: 110,
      sortable: true, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
    { label: 'Facility', fieldName: 'facility', type: 'text', initialWidth: 140, wrapText: true, sortable: true },
    { label: 'Objection', fieldName: 'objection', type: 'text', initialWidth: 130, wrapText: true, sortable: true },
    // Blank and disabled on legacy rows, which have no Case.
    { label: 'Case', type: 'button', initialWidth: 95,
      typeAttributes: { label: { fieldName: 'caseNumber' }, variant: 'base', name: 'openCase',
                        disabled: { fieldName: 'noCase' } } },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 100, sortable: true }
];

// Fixed width: left to share what the other columns leave, it was squeezed to
// one word per line on a normal desktop screen.
const NOTES_COLUMN = { label: 'Notes', fieldName: 'notesDisplay', type: 'text', initialWidth: 300,
                       wrapText: true, sortable: true };

const COLUMNS_AFTER_NOTES = [
    { label: 'Created By', fieldName: 'createdByName', type: 'text', initialWidth: 125, wrapText: true, sortable: true },
    // Datetime, so the time is shown alongside the date.
    { label: 'Created Date', fieldName: 'createdDate', type: 'date', initialWidth: 160,
      sortable: true, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
                                        hour: '2-digit', minute: '2-digit' } },
    { label: 'Source', fieldName: 'source', type: 'text', initialWidth: 110, sortable: true }
];

const BADGE_BY_SOURCE = {
    Case: 'slds-badge slds-theme_info',
    'Legacy activity': 'slds-badge slds-theme_warning'
};
const DEFAULT_BADGE = 'slds-badge slds-theme_success';

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
    // The wire is cacheable, so its first answer can be from earlier in the
    // session; one server read per load keeps a just-logged Case from missing.
    fetchedFresh = false;
    refreshHandlerId;

    connectedCallback() {
        const months = parseInt(this.monthsBack, 10);
        this.activeMonths = Number.isFinite(months) ? months : 0;
        const limit = parseInt(this.rowLimit, 10);
        this.activeRowLimit = Number.isFinite(limit) ? limit : 500;
        // Log a Visit ends with a record page refresh; re-read so its new Cases
        // appear without the user clicking Refresh. Passing `this` fails here with
        // "Invalid contextElement" (the security layer hands the API a proxy), so
        // the host element is used. The tab must still load if the API refuses
        // it, so registration failure is swallowed: Refresh and the per-load
        // fresh read still work without it.
        try {
            this.refreshHandlerId = registerRefreshHandler(this.template.host, this.refreshHandler);
        } catch (e) {
            this.refreshHandlerId = undefined;
        }
    }

    disconnectedCallback() {
        if (this.refreshHandlerId) {
            unregisterRefreshHandler(this.refreshHandlerId);
        }
    }

    // Arrow function so `this` is the component whichever way the API calls it.
    refreshHandler = () => {
        if (!this.wiredResult) {
            return Promise.resolve(true);
        }
        return refreshApex(this.wiredResult).then(() => true);
    };

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
            if (!this.fetchedFresh) {
                this.fetchedFresh = true;
                refreshApex(this.wiredResult);
            }
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
                noCase: !r.caseId,
                badgeClass: BADGE_BY_SOURCE[r.source] || DEFAULT_BADGE
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
        const { action, row } = event.detail;
        if (action.name === 'openVisitReport') {
            this.navigateToRecord(row.visitReportId);
        } else if (action.name === 'openCase') {
            this.navigateToRecord(row.caseId);
        }
    }

    handleCardLinkClick(event) {
        this.navigateToRecord(event.currentTarget.dataset.id);
    }

    navigateToRecord(recordId) {
        if (!recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
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
