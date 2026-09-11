import { LightningElement, api, track } from 'lwc';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';

let _idCounter = 0;
const newId = () => `g_${Date.now()}_${++_idCounter}`;

// Date groupings MUST be bucketed — grouping a date raw produces one category per
// day (hundreds of unreadable bars). Month is the safe default.
const GRAIN_OPTIONS = [
    { label: 'Day', value: 'Day' },
    { label: 'Week', value: 'Week' },
    { label: 'Month', value: 'Month' },
    { label: 'Quarter', value: 'Quarter' },
    { label: 'Year', value: 'Year' }
];
const DEFAULT_GRAIN = 'Month';
const isDateType = (f) => !!f && ['DATE', 'DATETIME'].includes(String(f.type || '').toUpperCase());

export default class CrGroupingsBuilder extends LightningElement {
    @api primaryObject;

    _initialJson = '[]';
    @api
    get initialJson() {
        return this._initialJson;
    }
    set initialJson(value) {
        this._initialJson = value == null ? '[]' : value;
        if (this._isConnected) {
            this.tryHydrate();
        }
    }

    @track groupings = [];
    @track fieldsByApiName = {};
    @track loadError;

    _isConnected = false;
    _fieldMetadata;
    @api
    get fieldMetadata() {
        return this._fieldMetadata;
    }
    set fieldMetadata(value) {
        this._fieldMetadata = value;
        if (Array.isArray(value) && value.length) {
            const map = {};
            for (const f of value) map[f.apiName] = f;
            this.fieldsByApiName = map;
        }
    }

    _loadedObject = null;

    connectedCallback() {
        this._isConnected = true;
        this.tryHydrate();
        this.loadFields();
    }

    disconnectedCallback() {
        this._isConnected = false;
    }

    renderedCallback() {
        if (this._loadedObject !== this.primaryObject) {
            this.loadFields();
        }
    }

    get fieldOptions() {
        return Object.values(this.fieldsByApiName)
            .filter((f) => f.groupable)
            .map((f) => ({ label: f.label, value: f.apiName }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    get hasGroupings() {
        return this.groupings.length > 0;
    }

    get addDisabled() {
        return !this.primaryObject || this.fieldOptions.length === 0;
    }

    // Rows decorated for the template: date fields get a granularity picker.
    get groupingRows() {
        return this.groupings.map((r) => {
            const dateField = isDateType(r.field ? this.fieldsByApiName[r.field] : null);
            return {
                ...r,
                showGranularity: dateField,
                granularityOptions: GRAIN_OPTIONS,
                granularity: dateField ? r.granularity || DEFAULT_GRAIN : null
            };
        });
    }

    get jsonOutput() {
        const rows = this.groupings
            .filter((r) => r.field)
            .map((r) => {
                const out = { field: r.field };
                if (isDateType(this.fieldsByApiName[r.field])) {
                    out.granularity = r.granularity || DEFAULT_GRAIN;
                }
                return out;
            });
        return JSON.stringify(rows, null, 2);
    }

    handleGranularityChange(event) {
        const id = event.currentTarget.dataset.id;
        const granularity = event.detail.value;
        this.groupings = this.groupings.map((r) => (r.id === id ? { ...r, granularity } : r));
        this.fireChange();
    }

    async loadFields() {
        const obj = this.primaryObject;
        if (!obj) {
            this.fieldsByApiName = {};
            this._loadedObject = null;
            return;
        }
        this._loadedObject = obj;
        if (Array.isArray(this._fieldMetadata) && this._fieldMetadata.length) {
            return;
        }
        try {
            this.loadError = null;
            const describe = await describeObject({ objectApiName: obj, depth: 0 });
            if (obj !== this.primaryObject) return;
            const map = {};
            for (const field of describe.fields || []) {
                map[field.apiName] = field;
            }
            this.fieldsByApiName = map;
        } catch (error) {
            if (obj !== this.primaryObject) return;
            this.loadError = error?.body?.message || error?.message || 'Could not load fields.';
            this.fieldsByApiName = {};
        }
    }

    addGrouping() {
        this.groupings = [...this.groupings, { id: newId(), field: null, displayIndex: 0, upDisabled: true, downDisabled: true }];
        this.reindex();
        this.fireChange();
    }

    removeGrouping(event) {
        const id = event.currentTarget.dataset.id;
        this.groupings = this.groupings.filter((r) => r.id !== id);
        this.reindex();
        this.fireChange();
    }

    handleFieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const field = event.detail.value;
        // Picking a date field seeds a sane bucket so a raw per-day grouping can't
        // slip through unnoticed.
        const grain = isDateType(this.fieldsByApiName[field]) ? DEFAULT_GRAIN : null;
        this.groupings = this.groupings.map((r) =>
            r.id === id ? { ...r, field, granularity: grain } : r
        );
        this.fireChange();
    }

    moveUp(event) {
        const id = event.currentTarget.dataset.id;
        const i = this.groupings.findIndex((r) => r.id === id);
        if (i <= 0) return;
        const next = [...this.groupings];
        [next[i - 1], next[i]] = [next[i], next[i - 1]];
        this.groupings = next;
        this.reindex();
        this.fireChange();
    }

    moveDown(event) {
        const id = event.currentTarget.dataset.id;
        const i = this.groupings.findIndex((r) => r.id === id);
        if (i < 0 || i >= this.groupings.length - 1) return;
        const next = [...this.groupings];
        [next[i], next[i + 1]] = [next[i + 1], next[i]];
        this.groupings = next;
        this.reindex();
        this.fireChange();
    }

    tryHydrate() {
        let parsed;
        try {
            parsed = JSON.parse(this.initialJson || '[]');
        } catch {
            this.groupings = [];
            return;
        }
        if (!Array.isArray(parsed)) {
            this.groupings = [];
            return;
        }
        this.groupings = parsed
            .map((entry) => {
                const field = typeof entry === 'string' ? entry : entry?.field || entry?.path;
                const granularity = typeof entry === 'string' ? null : entry?.granularity || null;
                return field
                    ? { id: newId(), field, granularity, displayIndex: 0, upDisabled: true, downDisabled: true }
                    : null;
            })
            .filter(Boolean);
        this.reindex();
    }

    reindex() {
        const last = this.groupings.length - 1;
        this.groupings = this.groupings.map((row, i) => ({
            ...row,
            displayIndex: i + 1,
            upDisabled: i === 0,
            downDisabled: i === last
        }));
    }

    fireChange() {
        this.dispatchEvent(
            new CustomEvent('groupingschange', {
                detail: { value: this.jsonOutput }
            })
        );
    }
}