import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getVisitSummary from '@salesforce/apex/ProviderVisitSummaryController.getVisitSummary';

const NOTES_TRUNCATE = 120;
const ALL = '__ALL__';

export default class ProviderVisitSummary extends NavigationMixin(LightningElement) {
    @api recordId;

    // Design attributes hold the configured defaults; the date-window toggle
    // drives activeMonths, because an @api property must not be reassigned
    // from inside the component.
    // Defaults to all time: most Florida visit history predates the 2025 move to
    // Visit Report records, and a 24 month default hid it entirely.
    @api monthsBack = 0;
    @api rowLimit = 500;
    // LWC forbids a public Boolean defaulting to true, so this stays undefined
    // and is treated as enabled unless App Builder sets it false.
    @api showNotes;

    activeMonths = 0;
    activeRowLimit = 500;

    purposeFilter = ALL;
    typeFilter = ALL;
    sourceFilter = ALL;
    searchTerm = '';
    notesExpanded = false;

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

    @wire(getVisitSummary, {
        providerId: '$recordId',
        monthsBack: '$activeMonths',
        rowLimit: '$activeRowLimit'
    })
    wiredSummary(result) {
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

    get showNotesColumn() {
        return this.showNotes === undefined || this.showNotes === true || this.showNotes === 'true';
    }

    get columns() {
        const cols = [
            { label: 'Visit Date', fieldName: 'visitDate', type: 'date-local', initialWidth: 115,
              typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
            { label: 'Subject', fieldName: 'subject', type: 'text', wrapText: true },
            { label: 'Type', fieldName: 'visitType', type: 'text', initialWidth: 105 },
            { label: 'Purpose', fieldName: 'purpose', type: 'text', initialWidth: 160 },
            { label: 'Audience', fieldName: 'audience', type: 'text', initialWidth: 150 },
            { label: 'Location', fieldName: 'location', type: 'text', initialWidth: 160 }
        ];
        if (this.showNotesColumn) {
            cols.push({ label: 'Notes', fieldName: 'notesDisplay', type: 'text', wrapText: true });
        }
        cols.push(
            // Button, not a url column: NavigationMixin builds the target at click
            // time so no org URL is ever hard-coded.
            { label: 'Visit Report', type: 'button', initialWidth: 125,
              typeAttributes: { label: { fieldName: 'targetName' }, variant: 'base',
                                name: 'openTarget' } },
            { label: 'Logged By', fieldName: 'loggedBy', type: 'text', initialWidth: 145 },
            { label: 'Source', fieldName: 'source', type: 'text', initialWidth: 145 }
        );
        return cols;
    }

    // ---- tiles -----------------------------------------------------------

    get totalCount() {
        return this.summary ? this.summary.totalCount : 0;
    }

    get last12Count() {
        return this.summary ? this.summary.last12Count : 0;
    }

    get purposeCount() {
        return this.summary ? this.summary.purposeCount : 0;
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

    // ---- purpose breakdown ----------------------------------------------

    get purposes() {
        if (!this.summary || !this.summary.purposes) {
            return [];
        }
        return this.summary.purposes.map((p) => ({
            ...p,
            key: p.name,
            barStyle: `width: ${p.percent}%`,
            label: `${p.name} (${p.count})`
        }));
    }

    get hasPurposes() {
        return this.purposes.length > 0;
    }

    // ---- rows and client-side filters ------------------------------------

    get rows() {
        if (!this.summary || !this.summary.rows) {
            return [];
        }
        const term = (this.searchTerm || '').trim().toLowerCase();
        return this.summary.rows
            .filter((r) => this.purposeFilter === ALL || r.purpose === this.purposeFilter)
            .filter((r) => this.typeFilter === ALL || r.visitType === this.typeFilter)
            .filter((r) => this.sourceFilter === ALL || r.source === this.sourceFilter)
            .filter((r) => {
                if (!term) {
                    return true;
                }
                // Search spans subject and notes: reps put the useful detail in either.
                return `${r.subject || ''} ${r.notes || ''}`.toLowerCase().includes(term);
            })
            .map((r) => {
                const notes = r.notes || '';
                const truncated = notes.length > NOTES_TRUNCATE;
                return {
                    ...r,
                    notesDisplay: this.notesExpanded || !truncated
                        ? notes
                        : `${notes.substring(0, NOTES_TRUNCATE)}…`,
                    notesTruncated: truncated
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
        if (this.summary && this.summary.totalCount > 0) {
            return 'No visits match the current filters.';
        }
        return 'No visit reports recorded for this provider';
    }

    get filteredCountLabel() {
        const shown = this.rows.length;
        const total = this.totalCount;
        if (shown === total) {
            return `${total} visit${total === 1 ? '' : 's'}`;
        }
        return `${shown} of ${total} visits`;
    }

    get isTruncated() {
        return this.summary ? this.summary.truncated === true : false;
    }

    get truncationMessage() {
        return `Only the first ${this.activeRowLimit} visits were loaded. Narrow the date window to see a complete set.`;
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
            { label: 'All time', value: '0' },
            { label: 'Last 24 months', value: '24' },
            { label: 'Last 12 months', value: '12' }
        ];
    }

    get dateWindowValue() {
        return String(this.activeMonths);
    }

    get purposeOptions() {
        const options = [{ label: 'All purposes', value: ALL }];
        this.purposes.forEach((p) => options.push({ label: p.label, value: p.name }));
        return options;
    }

    get activityOnlyCount() {
        return this.summary ? this.summary.activityOnlyCount : 0;
    }

    get hasLegacyRows() {
        return this.activityOnlyCount > 0;
    }

    get legacyNotice() {
        return `${this.activityOnlyCount} of these visits were recorded on the activity itself, before this region moved to Visit Report records. They are marked "Activity only".`;
    }

    get sourceOptions() {
        return [
            { label: 'All sources', value: ALL },
            { label: 'Visit Report record', value: 'Visit Report record' },
            { label: 'Activity only', value: 'Activity only' }
        ];
    }

    get typeOptions() {
        const options = [{ label: 'All types', value: ALL }];
        if (this.summary && this.summary.rows) {
            const seen = new Set();
            this.summary.rows.forEach((r) => {
                if (r.visitType && !seen.has(r.visitType)) {
                    seen.add(r.visitType);
                    options.push({ label: r.visitType, value: r.visitType });
                }
            });
        }
        return options;
    }

    // ---- handlers --------------------------------------------------------

    handleDateWindowChange(event) {
        // Server-side parameter: changing it re-provisions the wire.
        this.loading = true;
        this.activeMonths = parseInt(event.detail.value, 10);
    }

    handlePurposeChange(event) {
        this.purposeFilter = event.detail.value;
    }

    handleTypeChange(event) {
        this.typeFilter = event.detail.value;
    }

    handleSourceChange(event) {
        this.sourceFilter = event.detail.value;
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
        if (event.detail.action.name === 'openTarget') {
            this.navigateToTarget(event.detail.row.targetId);
        }
    }

    handleCardLinkClick(event) {
        this.navigateToTarget(event.currentTarget.dataset.id);
    }

    navigateToVisitReport(targetId) {
        if (!targetId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: targetId, actionName: 'view' }
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
