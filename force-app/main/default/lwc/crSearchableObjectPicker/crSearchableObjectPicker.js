import { LightningElement, api, track } from 'lwc';

const DEFAULT_DEBOUNCE_MS = 300;
const DEFAULT_MAX_RESULTS = 50;
const DEFAULT_RECENTS_LIMIT = 5;
const RECENTS_STORAGE_PREFIX = 'crSearchableObjectPicker:';

export default class CrSearchableObjectPicker extends LightningElement {
    @api label;
    @api placeholder = 'Search...';
    @api fieldLevelHelp;
    @api required = false;
    @api disabled = false;
    @api loading = false;
    @api debounceMs = DEFAULT_DEBOUNCE_MS;
    @api maxResults = DEFAULT_MAX_RESULTS;
    @api disableRecents = false;
    @api recentsKey = 'objects';
    @api recentsLimit = DEFAULT_RECENTS_LIMIT;

    @track _items = [];
    @track _value;
    @track displayValue = '';
    @track searchTerm = '';
    @track isOpen = false;
    @track activeIndex = 0;
    @track recentValues = [];

    _debounceTimer;
    _blurTimer;
    _hydrated = false;

    @api
    get items() {
        return this._items;
    }
    set items(value) {
        this._items = Array.isArray(value) ? value : [];
        this._hydrated = false;
    }

    @api
    get value() {
        return this._value;
    }
    set value(v) {
        this._value = v;
        this._hydrated = false;
        // When the parent clears the value, also clear the displayed label —
        // otherwise renderedCallback's `if (this._value)` short-circuit leaves
        // the previous selection's text on screen.
        if (v === null || v === undefined || v === '') {
            this.displayValue = '';
        }
    }

    connectedCallback() {
        this.loadRecents();
    }

    renderedCallback() {
        if (!this._hydrated && this._value && this._items.length) {
            const item = this._items.find((i) => i.value === this._value);
            if (item) {
                this.displayValue = item.label;
            }
            this._hydrated = true;
        }
    }

    get comboboxClass() {
        return [
            'slds-combobox',
            'slds-dropdown-trigger',
            'slds-dropdown-trigger_click',
            this.isOpen ? 'slds-is-open' : ''
        ]
            .filter(Boolean)
            .join(' ');
    }

    get hasValue() {
        return !!this._value;
    }

    get displayedItems() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        const recentSet = new Set(this.recentValues || []);
        let pool;

        if (term) {
            pool = this._items.filter(
                (i) =>
                    (i.label || '').toLowerCase().includes(term) ||
                    (i.value || '').toLowerCase().includes(term)
            );
        } else if (!this.disableRecents && this.recentValues.length) {
            const recents = this.recentValues
                .map((v) => this._items.find((i) => i.value === v))
                .filter(Boolean);
            const rest = this._items.filter((i) => !recentSet.has(i.value));
            pool = [...recents, ...rest];
        } else {
            pool = this._items;
        }

        return pool.slice(0, this.maxResults).map((item, idx) => this.decorate(item, idx, term, recentSet));
    }

    get hasResults() {
        return this.displayedItems.length > 0;
    }

    get showLoading() {
        return this.loading;
    }

    get showNoResults() {
        return !this.loading && !this.hasResults;
    }

    get activeDescendantId() {
        if (!this.isOpen) return null;
        const items = this.displayedItems;
        if (this.activeIndex < 0 || this.activeIndex >= items.length) return null;
        return items[this.activeIndex].optionId;
    }

    decorate(item, idx, term, recentSet) {
        const isActive = idx === this.activeIndex;
        const isRecent = recentSet.has(item.value);
        return {
            value: item.value,
            label: item.label,
            meta: item.meta || item.value,
            index: idx,
            isRecent,
            optionId: `option-${idx}-${item.value}`,
            parts: this.highlightParts(item.label, term),
            isActive,
            isActiveStr: isActive ? 'true' : 'false',
            cssClass: this.optionCssClass(isActive)
        };
    }

    optionCssClass(isActive) {
        const base = 'slds-media slds-listbox__option slds-listbox__option_entity slds-listbox__option_has-meta';
        return isActive ? `${base} slds-has-focus` : base;
    }

    highlightParts(label, term) {
        if (!term) {
            return [{ id: 0, text: label, highlight: false }];
        }
        const lower = (label || '').toLowerCase();
        const idx = lower.indexOf(term);
        if (idx < 0) {
            return [{ id: 0, text: label, highlight: false }];
        }
        const parts = [];
        if (idx > 0) {
            parts.push({ id: 0, text: label.substring(0, idx), highlight: false });
        }
        parts.push({ id: 1, text: label.substring(idx, idx + term.length), highlight: true });
        if (idx + term.length < label.length) {
            parts.push({ id: 2, text: label.substring(idx + term.length), highlight: false });
        }
        return parts;
    }

    handleInput(event) {
        const value = event.target.value;
        if (this._value) {
            this._value = null;
            this._hydrated = true;
            this.dispatchChange(null, null);
        }
        this.displayValue = value;
        this.isOpen = true;
        clearTimeout(this._debounceTimer);
        this._debounceTimer = setTimeout(() => {
            this.searchTerm = value;
            this.activeIndex = 0;
            this.dispatchSearch(value);
        }, this.debounceMs);
    }

    handleFocus() {
        // Cancel any pending close from a recent blur — re-focusing within the
        // 150ms window should keep the dropdown open.
        clearTimeout(this._blurTimer);
        if (!this.disabled) {
            this.isOpen = true;
        }
    }

    handleBlur() {
        // Delay so mousedown on an option fires first.
        clearTimeout(this._blurTimer);
        this._blurTimer = setTimeout(() => {
            this.isOpen = false;
        }, 150);
    }

    disconnectedCallback() {
        // Pending timers hold a closure reference to this component until they
        // fire. Cancel them so an unmounted picker doesn't keep its instance alive.
        clearTimeout(this._debounceTimer);
        clearTimeout(this._blurTimer);
    }

    handleKeyDown(event) {
        if (this.disabled) return;
        const key = event.key;

        if (!this.isOpen && (key === 'ArrowDown' || key === 'ArrowUp' || key === 'Enter')) {
            this.isOpen = true;
            event.preventDefault();
            return;
        }
        if (!this.isOpen) return;

        const items = this.displayedItems;
        if (!items.length && key !== 'Escape') return;

        if (key === 'ArrowDown') {
            this.activeIndex = (this.activeIndex + 1) % items.length;
            event.preventDefault();
        } else if (key === 'ArrowUp') {
            this.activeIndex = this.activeIndex <= 0 ? items.length - 1 : this.activeIndex - 1;
            event.preventDefault();
        } else if (key === 'Enter') {
            if (items[this.activeIndex]) {
                this.selectByValue(items[this.activeIndex].value);
            }
            event.preventDefault();
        } else if (key === 'Escape') {
            this.isOpen = false;
            event.preventDefault();
        } else if (key === 'Tab') {
            this.isOpen = false;
        }
    }

    handleHover(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (Number.isFinite(idx)) {
            this.activeIndex = idx;
        }
    }

    handleSelect(event) {
        // mousedown + preventDefault keeps focus on the input so blur doesn't fire first
        event.preventDefault();
        const value = event.currentTarget.dataset.value;
        this.selectByValue(value);
    }

    handleClear(event) {
        event.preventDefault();
        event.stopPropagation();
        clearTimeout(this._debounceTimer);
        this._value = null;
        this.displayValue = '';
        this.searchTerm = '';
        this.activeIndex = 0;
        this.isOpen = true;
        this._hydrated = true;
        this.dispatchSearch('');
        this.dispatchChange(null, null);
    }

    selectByValue(value) {
        const item = this._items.find((i) => i.value === value);
        if (!item) return;
        this._value = item.value;
        this.displayValue = item.label;
        this.searchTerm = '';
        this.isOpen = false;
        this.pushRecent(item.value);
        this.dispatchChange(item.value, item.label);
    }

    dispatchChange(value, label) {
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { value, label }
            })
        );
    }

    dispatchSearch(searchTerm) {
        this.dispatchEvent(
            new CustomEvent('search', {
                detail: { searchTerm }
            })
        );
    }

    loadRecents() {
        if (this.disableRecents) return;
        try {
            const stored = window.localStorage?.getItem(RECENTS_STORAGE_PREFIX + this.recentsKey);
            this.recentValues = stored ? JSON.parse(stored) : [];
        } catch {
            this.recentValues = [];
        }
    }

    pushRecent(value) {
        if (this.disableRecents || !value) return;
        const next = [value, ...this.recentValues.filter((v) => v !== value)].slice(0, this.recentsLimit);
        this.recentValues = next;
        try {
            window.localStorage?.setItem(RECENTS_STORAGE_PREFIX + this.recentsKey, JSON.stringify(next));
        } catch {
            // localStorage disabled or full - ignore silently
        }
    }
}