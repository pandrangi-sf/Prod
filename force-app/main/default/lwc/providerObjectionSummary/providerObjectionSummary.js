import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getObjectionSummary from '@salesforce/apex/ProviderObjectionSummaryController.getObjectionSummary';

const NOTES_TRUNCATE = 120;
const ALL = '__ALL__';
const ALL_TIME = 0;

export default class ProviderObjectionSummary extends NavigationMixin(LightningElement) {
    @api recordId;

    // Design attributes. These are the configured defaults; the date-window
    // toggle drives activeMonths instead, because an @api property must not be
    // reassigned from inside the component.
    @api monthsBack = 24;
    @api rowLimit = 500;
    // LWC forbids a public Boolean defaulting to true, so this is left
    // undefined and treated as enabled unless App Builder sets it false.
    @api showNotes;

    activeMonths = 24;
    activeRowLimit = 500;

    categoryFilter = ALL;
    searchTerm = '';
    notesExpanded = false;

    summary;
    error;
    loading = true;
    wiredResult;

    connectedCallback() {
        const configuredMonths = parseInt(this.monthsBack, 10);
        this.activeMonths = Number.isFinite(configuredMonths) ? configuredMonths : 24;
        const configuredLimit = parseInt(this.rowLimit, 10);
        this.activeRowLimit = Number.isFinite(configuredLimit) ? configuredLimit : 500;
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

    // ---- layout ----------------------------------------------------------

    get isPhone() {
        return FORM_FACTOR === 'Small';
    }

    get isDesktop() {
        return !this.isPhone;
    }

    get columns() {
        const cols = [
            { label: 'Visit Date', fieldName: 'visitDate', type: 'date-local', initialWidth: 120,
              typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
            { label: 'Objection', fieldName: 'objection', type: 'text', initialWidth: 170 },
            { label: 'Facility', fieldName: 'facility', type: 'text', initialWidth: 130 }
        ];
        if (this.showNotesColumn) {
            cols.push({ label: 'Notes', fieldName: 'notesDisplay', type: 'text', wrapText: true });
        }
        cols.push(
            // A button rather than a url column: the target is produced by
            // NavigationMixin at click time, so no org URL is ever hard-coded.
            { label: 'Visit Report', type: 'button', initialWidth: 130,
              typeAttributes: { label: { fieldName: 'visitReportName' }, variant: 'base',
                                name: 'openVisitReport' } },
            { label: 'Logged By', fieldName: 'loggedBy', type: 'text', initialWidth: 150 },
            { label: 'Source', fieldName: 'source', type: 'text', initialWidth: 130 }
        );
        return cols;
    }

    get showNotesColumn() {
        return this.showNotes === undefined || this.showNotes === true || this.showNotes === 'true';
    }

    // ---- tiles -----------------------------------------------------------

    get totalCount() {
        return this.summary ? this.summary.totalCount : 0;
    }

    get last12Count() {
        return this.summary ? this.summary.last12Count : 0;
    }

    get categoryCount() {
        return this.summary ? this.summary.categoryCount : 0;
    }

    get mostRecentLabel() {
        if (!this.summary || !this.summary.mostRecentDate) {
            return '—';
        }
        return this.summary.mostRecentDate;
    }

    get mostRecentBy() {
        if (!this.summary || !this.summary.mostRecentBy) {
            return '';
        }
        return `by ${this.summary.mostRecentBy}`;
    }

    // ---- category breakdown ---------------------------------------------

    get categories() {
        if (!this.summary || !this.summary.categories) {
            return [];
        }
        return this.summary.categories.map((c) => ({
            ...c,
            key: c.name,
            // Inline width is the only way to size a share bar per row.
            barStyle: `width: ${c.percent}%`,
            label: `${c.name} (${c.count})`
        }));
    }

    get hasCategories() {
        return this.categories.length > 0;
    }

    // ---- rows and client-side filters ------------------------------------

    get rows() {
        if (!this.summary || !this.summary.rows) {
            return [];
        }
        const term = (this.searchTerm || '').trim().toLowerCase();
        return this.summary.rows
            .filter((r) => this.categoryFilter === ALL || r.objection === this.categoryFilter)
            .filter((r) => {
                if (!term) {
                    return true;
                }
                return (r.notes || '').toLowerCase().includes(term);
            })
            .map((r) => {
                const notes = r.notes || '';
                const truncated = notes.length > NOTES_TRUNCATE;
                return {
                    ...r,
                    notesDisplay: this.notesExpanded || !truncated
                        ? notes
                        : `${notes.substring(0, NOTES_TRUNCATE)}…`,
                    notesTruncated: truncated,
                    isLegacy: r.source === 'Legacy activity',
                    badgeClass: r.source === 'Legacy activity'
                        ? 'slds-badge slds-theme_warning'
                        : 'slds-badge slds-theme_success'
                };
            });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.loading && !this.error && this.rows.length === 0;
    }

    get emptyMessage() {
        // Distinguish "this provider has none" from "your filters hid them all".
        if (this.summary && this.summary.totalCount > 0) {
            return 'No objections match the current filters.';
        }
        return 'No objections recorded for this provider';
    }

    get filteredCountLabel() {
        const shown = this.rows.length;
        const total = this.totalCount;
        if (shown === total) {
            return `${total} objection${total === 1 ? '' : 's'}`;
        }
        return `${shown} of ${total} objections`;
    }

    get isTruncated() {
        return this.summary ? this.summary.truncated === true : false;
    }

    get truncationMessage() {
        return `Only the first ${this.activeRowLimit} objections were loaded. Narrow the date window to see a complete set.`;
    }

    get anyNotesTruncated() {
        return this.rows.some((r) => r.notesTruncated);
    }

    get notesToggleLabel() {
        return this.notesExpanded ? 'Collapse notes' : 'Expand notes';
    }

    // ---- filter options --------------------------------------------------

    get dateWindowOptions() {
        return [
            { label: 'Last 24 months', value: String(24) },
            { label: 'Show all', value: String(ALL_TIME) }
        ];
    }

    get dateWindowValue() {
        return String(this.activeMonths);
    }

    get categoryOptions() {
        const options = [{ label: 'All objections', value: ALL }];
        this.categories.forEach((c) => options.push({ label: c.label, value: c.name }));
        return options;
    }

    // ---- handlers --------------------------------------------------------

    handleDateWindowChange(event) {
        // Server-side parameter: changing it re-provisions the wire.
        this.loading = true;
        this.activeMonths = parseInt(event.detail.value, 10);
    }

    handleCategoryChange(event) {
        this.categoryFilter = event.detail.value;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
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

    // ---- errors ----------------------------------------------------------

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
