import { LightningElement, api, track } from 'lwc';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';

const OPERATOR_OPTIONS = [
    { label: '=', value: '=' },
    { label: '≠', value: '!=' },
    { label: '>', value: '>' },
    { label: '≥', value: '>=' },
    { label: '<', value: '<' },
    { label: '≤', value: '<=' },
    { label: 'between', value: 'BETWEEN' },
    { label: 'contains', value: 'CONTAINS' }
];

let _idCounter = 0;
const newId = (prefix) => `${prefix}_${Date.now()}_${++_idCounter}`;

export default class CrBucketsBuilder extends LightningElement {
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

    @track buckets = [];
    @track fieldsByApiName = {};
    @track loadError;

    operatorOptions = OPERATOR_OPTIONS;
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

    get fieldOptions() {
        return Object.values(this.fieldsByApiName)
            .map((f) => ({ label: f.label, value: f.apiName }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    get hasBuckets() {
        return this.buckets.length > 0;
    }

    get addDisabled() {
        return !this.primaryObject;
    }

    get jsonOutput() {
        const out = this.buckets
            .filter((b) => b.name && b.sourceField)
            .map((b) => ({
                name: b.name,
                sourceField: b.sourceField,
                defaultValue: b.defaultValue || 'Other',
                rules: b.rules
                    .filter((r) => r.operator && r.label && (r.value !== '' || r.operator === 'IS NULL'))
                    .map((r) => this.toRule(r))
            }));
        return JSON.stringify(out, null, 2);
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

    addBucket() {
        const bucket = {
            id: newId('b'),
            name: 'New Bucket',
            sourceField: null,
            defaultValue: 'Other',
            rules: [],
            hasRules: false
        };
        this.buckets = [...this.buckets, bucket];
        this.fireChange();
    }

    removeBucket(event) {
        const id = event.currentTarget.dataset.id;
        this.buckets = this.buckets.filter((b) => b.id !== id);
        this.fireChange();
    }

    handleBucketChange(event) {
        const id = event.currentTarget.dataset.id;
        const prop = event.currentTarget.dataset.prop;
        const value = event.detail.value;
        this.buckets = this.buckets.map((b) => (b.id === id ? { ...b, [prop]: value } : b));
        this.fireChange();
    }

    addRule(event) {
        const bucketId = event.currentTarget.dataset.id;
        const rule = this.makeRule({ operator: '=' });
        this.buckets = this.buckets.map((b) =>
            b.id === bucketId ? { ...b, rules: [...b.rules, rule], hasRules: true } : b
        );
        this.fireChange();
    }

    removeRule(event) {
        const bucketId = event.currentTarget.dataset.bucketId;
        const ruleId = event.currentTarget.dataset.ruleId;
        this.buckets = this.buckets.map((b) => {
            if (b.id !== bucketId) return b;
            const rules = b.rules.filter((r) => r.id !== ruleId);
            return { ...b, rules, hasRules: rules.length > 0 };
        });
        this.fireChange();
    }

    handleRuleChange(event) {
        const bucketId = event.currentTarget.dataset.bucketId;
        const ruleId = event.currentTarget.dataset.ruleId;
        const prop = event.currentTarget.dataset.prop;
        const value = event.detail.value;
        this.buckets = this.buckets.map((b) => {
            if (b.id !== bucketId) return b;
            const rules = b.rules.map((r) => {
                if (r.id !== ruleId) return r;
                const next = { ...r, [prop]: value };
                if (prop === 'operator') {
                    next.isBetween = value === 'BETWEEN';
                    if (!next.isBetween) next.valueTo = '';
                }
                return next;
            });
            return { ...b, rules };
        });
        this.fireChange();
    }

    toRule(rule) {
        const out = { operator: rule.operator, value: this.coerce(rule.value), label: rule.label };
        if (rule.isBetween && rule.valueTo !== '' && rule.valueTo !== undefined) {
            out.valueTo = this.coerce(rule.valueTo);
        }
        return out;
    }

    coerce(value) {
        if (value === '' || value === null || value === undefined) return value;
        const n = Number(value);
        return Number.isFinite(n) && String(n) === String(value).trim() ? n : value;
    }

    makeRule(seed = {}) {
        const operator = seed.operator || '=';
        return {
            id: newId('r'),
            operator,
            value: seed.value === undefined || seed.value === null ? '' : String(seed.value),
            valueTo: seed.valueTo === undefined || seed.valueTo === null ? '' : String(seed.valueTo),
            label: seed.label || '',
            isBetween: operator === 'BETWEEN'
        };
    }

    tryHydrate() {
        let parsed;
        try {
            parsed = JSON.parse(this.initialJson || '[]');
        } catch {
            this.buckets = [];
            return;
        }
        if (!Array.isArray(parsed)) {
            this.buckets = [];
            return;
        }
        this.buckets = parsed.map((b) => {
            const rules = (b.rules || []).map((r) => this.makeRule(r));
            return {
                id: newId('b'),
                name: b.name || b.label || 'Bucket',
                sourceField: b.sourceField || b.field || null,
                defaultValue: b.defaultValue || 'Other',
                rules,
                hasRules: rules.length > 0
            };
        });
    }

    fireChange() {
        this.dispatchEvent(
            new CustomEvent('bucketschange', {
                detail: { value: this.jsonOutput }
            })
        );
    }
}