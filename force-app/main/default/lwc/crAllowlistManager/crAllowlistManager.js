import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import listAllCandidates from '@salesforce/apex/CR_AllowlistService.listAllCandidates';
import saveAllowlist from '@salesforce/apex/CR_AllowlistService.saveAllowlist';
import autoPopulateDefaults from '@salesforce/apex/CR_AllowlistService.autoPopulateDefaults';
import clearAllowlist from '@salesforce/apex/CR_AllowlistService.clearAllowlist';

// Version stamp: helps us verify a fresh bundle is loaded after deploys.
// Bump this whenever you change the save flow.
// eslint-disable-next-line no-console
console.log('[CR Allowlist] component bundle v8 (JSON-string Apex param)');

const FILTER_OPTIONS = [
    { label: 'All objects', value: 'all' },
    { label: 'In allowlist', value: 'in' },
    { label: 'Not in allowlist', value: 'out' },
    { label: 'Custom objects only', value: 'custom' }
];

const CATEGORY_OPTIONS = [
    { label: '— Choose —', value: '' },
    { label: 'Standard', value: 'Standard' },
    { label: 'Custom', value: 'Custom' },
    { label: 'Fact', value: 'Fact' },
    { label: 'Dimension', value: 'Dimension' },
    { label: 'Junction', value: 'Junction' },
    { label: 'Other', value: 'Other' }
];

const PAGE_SIZE_OPTIONS = [
    { label: '50 per page', value: '50' },
    { label: '100 per page', value: '100' },
    { label: '200 per page', value: '200' },
    { label: 'All', value: 'all' }
];

const DEFAULT_PAGE_SIZE = 100;

export default class CrAllowlistManager extends LightningElement {
    @track candidates = [];
    @track searchTerm = '';
    @track filterMode = 'in';
    @track busy = false;
    @track loadError;
    @track currentPage = 1;
    @track pageSizeValue = String(DEFAULT_PAGE_SIZE);

    // Track per-apiName edits keyed by apiName.
    pendingEdits = new Map();

    filterOptions = FILTER_OPTIONS;
    categoryOptions = CATEGORY_OPTIONS;
    pageSizeOptions = PAGE_SIZE_OPTIONS;

    // Phase G: toggle the help drawer when the toolbar ? button is clicked
    // (first click opens, next click closes).
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    connectedCallback() {
        // Defer the heavy describe-of-all-objects fetch one frame past
        // first paint so the page chrome paints immediately and the user
        // sees the Loading spinner instead of a blank page.
        this.busy = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.loadCandidates(), 0);
    }

    async loadCandidates() {
        this.busy = true;
        this.loadError = null;
        try {
            const data = await listAllCandidates();
            this.candidates = (data || []).map((c) => ({
                ...c,
                active: !!c.active,
                inAllowlist: !!c.inAllowlist,
                category: c.category || ''
            }));
            this.pendingEdits = new Map();
        } catch (error) {
            this.loadError = error?.body?.message || error?.message || 'Failed to load candidate objects.';
        } finally {
            this.busy = false;
        }
    }

    get filteredRows() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        return this.candidates.filter((c) => {
            const pending = this.pendingEdits.has(c.apiName);
            const matchesTerm = !term || (
                (c.label || '').toLowerCase().includes(term) ||
                (c.apiName || '').toLowerCase().includes(term)
            );
            if (!matchesTerm && !pending) return false;
            if (pending) return true;
            if (this.filterMode === 'in' && !c.active) return false;
            if (this.filterMode === 'out' && c.active) return false;
            if (this.filterMode === 'custom' && !c.custom) return false;
            return true;
        });
    }

    get pageSize() {
        if (this.pageSizeValue === 'all') return Number.MAX_SAFE_INTEGER;
        const parsed = parseInt(this.pageSizeValue, 10);
        return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_PAGE_SIZE;
    }

    get totalPages() {
        const filtered = this.filteredRows.length;
        if (filtered === 0) return 1;
        return Math.max(1, Math.ceil(filtered / this.pageSize));
    }

    get effectivePage() {
        return Math.min(this.currentPage, this.totalPages);
    }

    get visibleRows() {
        const all = this.filteredRows;
        const start = (this.effectivePage - 1) * this.pageSize;
        const end = Math.min(start + this.pageSize, all.length);
        return all.slice(start, end).map((c) => {
            const edited = this.pendingEdits.has(c.apiName);
            // Status pill + card styling: pending overrides in/out so unsaved
            // changes are obvious. Otherwise show whether the row is currently
            // in the allowlist (active=true) or available to add (active=false).
            let cardClass = 'object-card object-card_out';
            let statusTone = 'neutral';
            let statusLabel = 'Available';
            if (edited) {
                cardClass = 'object-card object-card_pending';
                statusTone = 'warning';
                statusLabel = 'Unsaved';
            } else if (c.active) {
                cardClass = 'object-card object-card_in';
                statusTone = 'success';
                statusLabel = 'In allowlist';
            }
            return {
                ...c,
                cardClass,
                statusTone,
                statusLabel,
                toggleLabel: c.active ? `Remove ${c.label} from allowlist` : `Add ${c.label} to allowlist`,
                // Legacy fields kept for downstream callers / tests.
                rowClass: edited ? 'pending-row' : '',
                categoryDisabled: !c.active
            };
        });
    }

    get hasVisibleRows() {
        return this.visibleRows.length > 0;
    }

    get tableClass() {
        return this.hasVisibleRows ? 'manager-table manager-table_has-rows' : 'manager-table';
    }

    get filteredCount() {
        return this.filteredRows.length;
    }

    get pageStart() {
        if (this.filteredRows.length === 0) return 0;
        return (this.effectivePage - 1) * this.pageSize + 1;
    }

    get pageEnd() {
        const start = this.pageStart;
        if (start === 0) return 0;
        return Math.min(start + this.visibleRows.length - 1, this.filteredRows.length);
    }

    get pageLabel() {
        const total = this.filteredRows.length;
        if (total === 0) return 'No matching rows';
        return `${this.pageStart}–${this.pageEnd} of ${total}`;
    }

    get prevDisabled() {
        return this.effectivePage <= 1;
    }

    get nextDisabled() {
        return this.effectivePage >= this.totalPages;
    }

    get totalCount() {
        return this.candidates.length;
    }

    get allowlistedCount() {
        return this.candidates.filter((c) => c.active).length;
    }

    get pendingChangesCount() {
        return this.pendingEdits.size;
    }

    get hasPending() {
        return this.pendingEdits.size > 0;
    }

    // Visible list of unsaved changes — gives users immediate confirmation that
    // their toggles are being captured before they hit Save.
    get pendingItems() {
        return Array.from(this.pendingEdits.values()).map((c) => ({
            apiName: c.apiName,
            label: c.label || c.apiName,
            actionLabel: c.active ? 'Add' : 'Remove',
            actionClass: c.active ? 'pending-action pending-action_add' : 'pending-action pending-action_remove'
        }));
    }

    handleDiscardPending() {
        // Reload from server to drop unsaved edits and restore original states.
        this.pendingEdits = new Map();
        this.loadCandidates();
    }

    get saveDisabled() {
        return this.busy || this.pendingEdits.size === 0;
    }

    // Filter pills replace the old combobox so users see counts at a glance
    // and can switch between views in one click.
    get filterPills() {
        const total = this.candidates.length;
        const inCount = this.candidates.filter((c) => c.active).length;
        const customCount = this.candidates.filter((c) => c.custom).length;
        const make = (mode, label, count) => {
            const selected = this.filterMode === mode;
            return {
                mode,
                label,
                count,
                selected,
                class: selected ? 'filter-pill filter-pill_active' : 'filter-pill'
            };
        };
        return [
            make('in', 'In allowlist', inCount),
            make('out', 'Available', total - inCount),
            make('custom', 'Custom only', customCount),
            make('all', 'All objects', total)
        ];
    }

    handleFilterPill(event) {
        const mode = event.currentTarget.dataset.mode;
        if (!mode || mode === this.filterMode) return;
        this.filterMode = mode;
        this.currentPage = 1;
    }

    // Tailored empty-state copy per filter so users know exactly what to do next.
    get emptyIcon() {
        if ((this.searchTerm || '').trim()) return 'utility:search';
        if (this.filterMode === 'in') return 'utility:list';
        return 'utility:filterList';
    }

    get emptyTitle() {
        if ((this.searchTerm || '').trim()) return 'No objects match your search';
        if (this.filterMode === 'in') return 'Your allowlist is empty';
        if (this.filterMode === 'custom') return 'No custom objects available';
        return 'No objects to show';
    }

    get emptyCopy() {
        if ((this.searchTerm || '').trim()) {
            return 'Try a different search term or change the filter above.';
        }
        if (this.filterMode === 'in') {
            return 'Switch to "Available" to add objects, or click "Auto-populate" to seed the list with common defaults.';
        }
        if (this.filterMode === 'custom') {
            return 'This org has no custom objects accessible to the current user.';
        }
        return 'No objects to show.';
    }

    get emptyShowAvailableButton() {
        return this.filterMode === 'in' && !(this.searchTerm || '').trim();
    }

    handleSearch(event) {
        this.searchTerm = event.detail.value || '';
        this.currentPage = 1;
    }

    handleFilterChange(event) {
        this.filterMode = event.detail.value;
        this.currentPage = 1;
    }

    handlePageSizeChange(event) {
        this.pageSizeValue = event.detail.value;
        this.currentPage = 1;
    }

    handleFirstPage() {
        this.currentPage = 1;
    }

    handlePrevPage() {
        if (this.currentPage > 1) this.currentPage -= 1;
    }

    handleNextPage() {
        if (this.currentPage < this.totalPages) this.currentPage += 1;
    }

    handleLastPage() {
        this.currentPage = this.totalPages;
    }

    handleActiveToggle(event) {
        // Triple-fallback for the apiName: dataset on currentTarget (most
        // reliable), then dataset on retargeted target, then the value/name
        // attributes (we set both on the lightning-input so we always have one).
        const apiName = event.currentTarget?.dataset?.api
            || event.target?.dataset?.api
            || event.detail?.value
            || event.target?.value
            || event.target?.name;
        if (!apiName) {
            // eslint-disable-next-line no-console
            console.error('[CR Allowlist] Toggle fired but apiName could not be resolved', event);
            this.toast('Toggle could not identify the object — open dev tools.', 'error');
            return;
        }
        const detail = event.detail || {};
        const active = typeof detail.checked === 'boolean'
            ? detail.checked
            : !!event.target?.checked;
        this.applyEdit(apiName, { active });
    }

    handleCategoryChange(event) {
        const apiName = event.currentTarget?.dataset?.api || event.target?.dataset?.api;
        if (!apiName) return;
        const category = event.detail?.value;
        this.applyEdit(apiName, { category });
    }

    applyEdit(apiName, patch) {
        this.candidates = this.candidates.map((c) => {
            if (c.apiName !== apiName) return c;
            return { ...c, ...patch };
        });
        const original = this.findOriginal(apiName);
        const current = this.candidates.find((c) => c.apiName === apiName);
        if (
            original &&
            current.active === original.active &&
            current.category === original.category
        ) {
            this.pendingEdits.delete(apiName);
        } else {
            this.pendingEdits.set(apiName, current);
        }
        this.pendingEdits = new Map(this.pendingEdits); // trigger reactivity
    }

    findOriginal(apiName) {
        // We don't preserve the loaded snapshot separately, so reload comparison
        // requires a fresh fetch. Treat any edit as pending.
        return null;
    }

    async handleSave() {
        if (this.pendingEdits.size === 0) return;
        this.busy = true;
        // Capture how many of the unsaved edits flipped objects into the allowlist
        // so we can land the user on a view that confirms their work.
        const addedCount = Array.from(this.pendingEdits.values()).filter((c) => c && c.active).length;
        try {
            // Use the Map's KEY as the authoritative apiName — applyEdit always
            // calls `pendingEdits.set(apiName, current)` so the key is guaranteed
            // to be the API name. Falling back to value.apiName only if the key
            // is somehow missing protects against any reactivity-proxy weirdness
            // that might strip enumerable properties from the spread value.
            const entries = Array.from(this.pendingEdits.entries())
                .map(([key, c]) => {
                    const apiName = key || c?.apiName;
                    if (!apiName || typeof apiName !== 'string' || !apiName.trim()) return null;
                    return {
                        recordId: c?.allowlistRecordId || null,
                        apiName,
                        active: c?.active === true,
                        category: c?.category || '',
                        displayOrder: c?.displayOrder ?? null
                    };
                })
                .filter(Boolean);
            // eslint-disable-next-line no-console
            console.log('[CR Allowlist] Sending entries to Apex:', JSON.parse(JSON.stringify(entries)));
            if (entries.length === 0) {
                this.toast('No changes to save (all pending edits were missing the object name).', 'warning');
                this.busy = false;
                return;
            }
            // Send as JSON string and have Apex parse it manually — avoids the
            // wire-layer inner-class deserialization that was nulling fields.
            const entriesJson = JSON.stringify(entries);
            // eslint-disable-next-line no-console
            console.log('[CR Allowlist] entriesJson:', entriesJson);
            const written = await saveAllowlist({ entriesJson });
            // eslint-disable-next-line no-console
            console.log('[CR Allowlist] Apex returned written count:', written);
            if (written === 0) {
                this.toast(
                    `Apex received ${entries.length} entries but saved 0. First entry: ${JSON.stringify(entries[0])}`,
                    'warning'
                );
            } else {
                this.toast(`Saved ${written} object(s) to the allowlist.`, 'success');
                this.template.querySelector('c-cr-save-button')?.triggerSuccess();
            }
            await this.loadCandidates();
            // If the user just added objects from a non-allowlist view ("Available",
            // "Custom only"), switch them into the "In allowlist" view so the saved
            // objects are visible — otherwise the rows disappear from their current
            // filter and it looks like the save didn't work.
            if (addedCount > 0 && this.filterMode !== 'all' && this.filterMode !== 'in') {
                this.filterMode = 'in';
                this.currentPage = 1;
            }
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('[CR Allowlist] Save threw:', error);
            this.toast(error?.body?.message || error?.message || 'Save failed.', 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleAutoPopulate() {
        this.busy = true;
        try {
            const added = await autoPopulateDefaults();
            this.toast(`Added ${added} object(s) to the allowlist.`, 'success');
            await this.loadCandidates();
        } catch (error) {
            this.toast(error?.body?.message || error?.message || 'Auto-populate failed.', 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleClearAll() {
        const proceed = await LightningConfirm.open({
            label: 'Clear allowlist',
            theme: 'warning',
            message: 'Deactivate every object in the allowlist? Records remain but are hidden from the picker.'
        });
        if (!proceed) return;
        this.busy = true;
        try {
            const cleared = await clearAllowlist();
            this.toast(`Deactivated ${cleared} record(s). The picker will fall back to defaults.`, 'success');
            await this.loadCandidates();
        } catch (error) {
            this.toast(error?.body?.message || error?.message || 'Clear failed.', 'error');
        } finally {
            this.busy = false;
        }
    }

    toast(message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title: 'Allowlist', message, variant }));
    }
}