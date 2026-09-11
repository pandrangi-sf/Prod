import { LightningElement, api, track } from 'lwc';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';
import validateFormula from '@salesforce/apex/CR_FormulaEngine.validateFormula';

const TYPE_OPTIONS = [
    { label: 'Number', value: 'number' },
    { label: 'Text', value: 'text' }
];

let _idCounter = 0;
const newId = () => `f_${Date.now()}_${++_idCounter}`;

export default class CrFormulaEditor extends LightningElement {
    @api primaryObject;

    _initialJson = '[]';
    @api
    get initialJson() {
        return this._initialJson;
    }
    set initialJson(value) {
        this._initialJson = value == null ? '[]' : value;
        // Re-hydrate when the parent feeds new state post-mount (e.g., after
        // template apply). Without this the editor keeps stale formulas.
        if (this._isConnected) {
            this.tryHydrate();
        }
    }

    @track formulas = [];
    @track fieldsByApiName = {};
    @track loadError;

    typeOptions = TYPE_OPTIONS;
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
            .map((f) => ({ label: f.apiName, value: f.apiName }))
            .sort((a, b) => a.label.localeCompare(b.label))
            .slice(0, 30);
    }

    get hasFormulas() {
        return this.formulas.length > 0;
    }

    get addDisabled() {
        return false;
    }

    get jsonOutput() {
        const out = this.formulas
            .filter((f) => f.name && f.expression)
            .map((f) => ({ name: f.name, type: f.type || 'number', expression: f.expression }));
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
            // Race guard: drop the result if primaryObject changed during the round-trip.
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

    addFormula() {
        const formula = {
            id: newId(),
            name: 'New Formula',
            type: 'number',
            expression: '',
            validationOk: false,
            validationError: false,
            validationMessage: ''
        };
        this.formulas = [...this.formulas, formula];
        this.fireChange();
    }

    removeFormula(event) {
        const id = event.currentTarget.dataset.id;
        this.formulas = this.formulas.filter((f) => f.id !== id);
        this.fireChange();
    }

    handleFormulaChange(event) {
        const id = event.currentTarget.dataset.id;
        const prop = event.currentTarget.dataset.prop;
        const value = event.detail.value;
        this.formulas = this.formulas.map((f) =>
            f.id === id ? { ...f, [prop]: value, validationOk: false, validationError: false, validationMessage: '' } : f
        );
        this.fireChange();
    }

    insertField(event) {
        const id = event.currentTarget.dataset.id;
        const token = event.currentTarget.dataset.token;
        this.formulas = this.formulas.map((f) =>
            f.id === id ? { ...f, expression: (f.expression || '') + (f.expression ? ' ' : '') + token } : f
        );
        this.fireChange();
    }

    async validateOne(event) {
        const id = event.currentTarget.dataset.id;
        const formula = this.formulas.find((f) => f.id === id);
        if (!formula) return;
        if (formula.validating) return; // Already in flight — ignore double-clicks.
        // Disable the button via the per-row validating flag.
        this.formulas = this.formulas.map((f) => (f.id === id ? { ...f, validating: true } : f));
        try {
            const result = await validateFormula({
                formulaJson: JSON.stringify({ name: formula.name, type: formula.type, expression: formula.expression }),
                sampleRowJson: '{}'
            });
            this.formulas = this.formulas.map((f) =>
                f.id === id
                    ? {
                          ...f,
                          validating: false,
                          validationOk: result.valid,
                          validationError: !result.valid,
                          validationMessage: result.valid ? 'Looks good.' : (result.errors || []).join(' ')
                      }
                    : f
            );
        } catch (error) {
            const message = error?.body?.message || error?.message || 'Validation failed.';
            this.formulas = this.formulas.map((f) =>
                f.id === id ? { ...f, validating: false, validationOk: false, validationError: true, validationMessage: message } : f
            );
        }
    }

    tryHydrate() {
        let parsed;
        try {
            parsed = JSON.parse(this.initialJson || '[]');
        } catch {
            this.formulas = [];
            return;
        }
        if (!Array.isArray(parsed)) {
            this.formulas = [];
            return;
        }
        this.formulas = parsed
            .filter((f) => f && (f.name || f.label))
            .map((f) => ({
                id: newId(),
                name: f.name || f.label,
                type: f.type || 'number',
                expression: f.expression || '',
                validationOk: false,
                validationError: false,
                validationMessage: ''
            }));
    }

    fireChange() {
        this.dispatchEvent(
            new CustomEvent('formulaschange', {
                detail: { value: this.jsonOutput }
            })
        );
    }
}