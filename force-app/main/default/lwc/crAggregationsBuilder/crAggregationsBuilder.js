import { LightningElement, api, track } from 'lwc';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';

const FUNCTION_OPTIONS = [
    { label: 'Count', value: 'COUNT' },
    { label: 'Sum', value: 'SUM' },
    { label: 'Average', value: 'AVG' },
    { label: 'Minimum', value: 'MIN' },
    { label: 'Maximum', value: 'MAX' }
];

const NUMERIC_TYPES = ['CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT'];
const NUMERIC_FUNCTIONS = new Set(['SUM', 'AVG', 'MIN', 'MAX']);

let _idCounter = 0;
const newId = () => `a_${Date.now()}_${++_idCounter}`;

export default class CrAggregationsBuilder extends LightningElement {
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

    @track aggregations = [];
    @track fieldsByApiName = {};
    @track loadError;

    functionOptions = FUNCTION_OPTIONS;
    _loadedObject = null;
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
            this.aggregations = this.aggregations.map((r) => this.applyFunction(r, r.function));
        }
    }

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

    get hasAggregations() {
        return this.aggregations.length > 0;
    }

    get addDisabled() {
        return !this.primaryObject;
    }

    get jsonOutput() {
        const rows = this.aggregations
            .filter((r) => r.function && (r.function === 'COUNT' || r.field))
            .map((r) => {
                const out = { function: r.function };
                if (r.field) out.field = r.field;
                return out;
            });
        return JSON.stringify(rows, null, 2);
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
            this.aggregations = this.aggregations.map((r) => this.applyFunction(r, r.function));
        } catch (error) {
            if (obj !== this.primaryObject) return;
            this.loadError = error?.body?.message || error?.message || 'Could not load fields.';
            this.fieldsByApiName = {};
        }
    }

    fieldOptionsFor(functionName) {
        const all = Object.values(this.fieldsByApiName);
        const filtered = NUMERIC_FUNCTIONS.has(functionName)
            ? all.filter((f) => NUMERIC_TYPES.includes(String(f.dataType || '').toUpperCase()))
            : all;
        return filtered
            .map((f) => ({ label: f.label, value: f.apiName }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    addAggregation() {
        const row = this.applyFunction({ id: newId(), function: 'COUNT', field: null, displayIndex: 0 }, 'COUNT');
        this.aggregations = [...this.aggregations, row];
        this.reindex();
        this.fireChange();
    }

    removeAggregation(event) {
        const id = event.currentTarget.dataset.id;
        this.aggregations = this.aggregations.filter((r) => r.id !== id);
        this.reindex();
        this.fireChange();
    }

    handleFunctionChange(event) {
        const id = event.currentTarget.dataset.id;
        const func = event.detail.value;
        this.aggregations = this.aggregations.map((r) =>
            r.id === id ? this.applyFunction({ ...r, function: func, field: func === 'COUNT' ? null : r.field }, func) : r
        );
        this.fireChange();
    }

    handleFieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const field = event.detail.value;
        this.aggregations = this.aggregations.map((r) => (r.id === id ? { ...r, field } : r));
        this.fireChange();
    }

    applyFunction(row, functionName) {
        return {
            ...row,
            fieldOptions: this.fieldOptionsFor(functionName),
            fieldDisabled: functionName === 'COUNT' && !row.field
        };
    }

    tryHydrate() {
        let parsed;
        try {
            parsed = JSON.parse(this.initialJson || '[]');
        } catch {
            this.aggregations = [];
            return;
        }
        if (!Array.isArray(parsed)) {
            this.aggregations = [];
            return;
        }
        this.aggregations = parsed
            .filter((entry) => entry && entry.function)
            .map((entry) => this.applyFunction({
                id: newId(),
                function: String(entry.function).toUpperCase(),
                field: entry.field || null,
                displayIndex: 0
            }, String(entry.function).toUpperCase()));
        this.reindex();
    }

    reindex() {
        this.aggregations = this.aggregations.map((row, i) => ({ ...row, displayIndex: i + 1 }));
    }

    fireChange() {
        this.dispatchEvent(
            new CustomEvent('aggregationschange', {
                detail: { value: this.jsonOutput }
            })
        );
    }
}