import { LightningElement, api, track } from 'lwc';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';

const TEXT_OPS = [
    { label: 'equals', value: '=' },
    { label: 'not equal to', value: '!=' },
    { label: 'contains', value: 'LIKE' },
    { label: 'is null', value: 'IS NULL' },
    { label: 'is not null', value: 'IS NOT NULL' }
];
const NUMBER_OPS = [
    { label: '=', value: '=' },
    { label: '≠', value: '!=' },
    { label: '>', value: '>' },
    { label: '≥', value: '>=' },
    { label: '<', value: '<' },
    { label: '≤', value: '<=' },
    { label: 'is null', value: 'IS NULL' },
    { label: 'is not null', value: 'IS NOT NULL' }
];
const DATE_OPS = [
    { label: 'on', value: '=' },
    { label: 'not on', value: '!=' },
    { label: 'after', value: '>' },
    { label: 'on or after', value: '>=' },
    { label: 'before', value: '<' },
    { label: 'on or before', value: '<=' },
    { label: 'in period', value: 'REL=' },
    { label: 'before period', value: 'REL<' },
    { label: 'after period', value: 'REL>' },
    { label: 'is null', value: 'IS NULL' },
    { label: 'is not null', value: 'IS NOT NULL' }
];

const RELATIVE_DATE_TOKENS = [
    { label: 'today', value: 'TODAY' },
    { label: 'yesterday', value: 'YESTERDAY' },
    { label: 'tomorrow', value: 'TOMORROW' },
    { label: 'this week', value: 'THIS_WEEK' },
    { label: 'last week', value: 'LAST_WEEK' },
    { label: 'next week', value: 'NEXT_WEEK' },
    { label: 'this month', value: 'THIS_MONTH' },
    { label: 'last month', value: 'LAST_MONTH' },
    { label: 'this quarter', value: 'THIS_QUARTER' },
    { label: 'last quarter', value: 'LAST_QUARTER' },
    { label: 'next quarter', value: 'NEXT_QUARTER' },
    { label: 'this year', value: 'THIS_YEAR' },
    { label: 'last year', value: 'LAST_YEAR' },
    { label: 'this fiscal quarter', value: 'THIS_FISCAL_QUARTER' },
    { label: 'last fiscal quarter', value: 'LAST_FISCAL_QUARTER' },
    { label: 'this fiscal year', value: 'THIS_FISCAL_YEAR' },
    { label: 'last fiscal year', value: 'LAST_FISCAL_YEAR' },
    { label: 'last 7 days', value: 'LAST_N_DAYS:7' },
    { label: 'last 30 days', value: 'LAST_N_DAYS:30' },
    { label: 'last 60 days', value: 'LAST_N_DAYS:60' },
    { label: 'last 90 days', value: 'LAST_N_DAYS:90' },
    { label: 'next 7 days', value: 'NEXT_N_DAYS:7' },
    { label: 'next 30 days', value: 'NEXT_N_DAYS:30' }
];

const RELATIVE_OP_TO_SOQL = { 'REL=': '=', 'REL<': '<', 'REL>': '>' };
const PICKLIST_OPS = [
    { label: 'equals', value: '=' },
    { label: 'not equal to', value: '!=' },
    { label: 'in', value: 'IN' },
    { label: 'not in', value: 'NOT IN' },
    { label: 'is null', value: 'IS NULL' },
    { label: 'is not null', value: 'IS NOT NULL' }
];
const MULTIPICKLIST_OPS = [
    { label: 'includes', value: 'INCLUDES' },
    { label: 'excludes', value: 'EXCLUDES' }
];
const BOOLEAN_OPS = [{ label: 'is', value: '=' }];
const REFERENCE_OPS = [
    { label: 'equals', value: '=' },
    { label: 'not equal to', value: '!=' },
    { label: 'is null', value: 'IS NULL' },
    { label: 'is not null', value: 'IS NOT NULL' }
];

const NO_VALUE_OPS = new Set(['IS NULL', 'IS NOT NULL']);
const ARRAY_VALUE_OPS = new Set(['IN', 'NOT IN', 'INCLUDES', 'EXCLUDES']);
const RELATIVE_OPS = new Set(['REL=', 'REL<', 'REL>']);

let _idCounter = 0;
const newId = () => `f_${Date.now()}_${++_idCounter}`;

export default class CrFilterBuilder extends LightningElement {
    @api initialJson = '[]';

    @track filters = [];
    @track filterLogic = 'AND';
    @track loadError;
    @track fieldsByApiName = {};
    @track fieldSearchTerm = '';

    _primaryObject = null;
    @api
    get primaryObject() {
        return this._primaryObject;
    }
    set primaryObject(value) {
        const nextObject = value || null;
        if (nextObject === this._primaryObject) {
            return;
        }
        this._primaryObject = nextObject;
        this._loadedObject = null;
        this.loadError = null;
        this.fieldSearchTerm = '';
        this._fieldMetadata = [];
        this.fieldsByApiName = {};
        this.filters = this.filters.map((row) => this.applyMeta(row, null));
    }

    _fieldMetadata;
    @api
    get fieldMetadata() {
        return this._fieldMetadata;
    }
    set fieldMetadata(value) {
        this._fieldMetadata = Array.isArray(value) ? value : [];
        this.fieldsByApiName = this.toFieldsByApiName(this._fieldMetadata);
        this.loadError = null;
        this.filters = this.filters.map((row) => this.applyMeta(row, this.fieldsByApiName[row.field]));
    }

    booleanOptions = [
        { label: 'true', value: 'true' },
        { label: 'false', value: 'false' }
    ];
    logicOptions = [
        { label: 'AND', value: 'AND' },
        { label: 'OR', value: 'OR' }
    ];

    _loadedObject = null;

    connectedCallback() {
        this.tryHydrate();
        this.loadFields();
    }

    renderedCallback() {
        if (this._loadedObject !== this.primaryObject) {
            this.loadFields();
        }
    }

    get fieldOptions() {
        return Object.values(this.fieldsByApiName)
            .map((f) => ({
                label: this.fieldOptionLabel(f),
                value: f.apiName,
                type: f.dataType,
                searchText: this.fieldSearchText(f)
            }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    get filteredFieldOptions() {
        const term = this.normalizeSearch(this.fieldSearchTerm);
        const selectedFields = new Set(this.filters.map((row) => row.field).filter(Boolean));
        return this.fieldOptions
            .filter((option) => !term || selectedFields.has(option.value) || option.searchText.includes(term))
            .map(({ searchText, ...option }) => option);
    }

    // Field palette rendered as a scrollable list on the left of step 3. Each entry has
    // a primary label (the field's user-friendly label) and a secondary line (the API name
    // and data type) so the user can disambiguate at a glance.
    get visibleFieldChoices() {
        const selected = new Set(this.filters.map((row) => row.field).filter(Boolean));
        return this.filteredFieldOptions.slice(0, 100).map((option) => {
            const meta = this.fieldsByApiName[option.value] || {};
            const isSelected = selected.has(option.value);
            const primaryLabel = meta.label || option.value;
            const dataType = meta.dataType ? this.formatDataType(meta.dataType) : '';
            const metaLine = dataType ? `${option.value} • ${dataType}` : option.value;
            return {
                value: option.value,
                primaryLabel,
                metaLine,
                isSelected,
                cssClass: isSelected ? 'field-choice field-choice_selected' : 'field-choice'
            };
        });
    }

    get hasFieldChoices() {
        return this.fieldOptions.length > 0;
    }

    get hasVisibleFieldChoices() {
        return this.visibleFieldChoices.length > 0;
    }

    get hasMoreFieldChoices() {
        return this.filteredFieldOptions.length > 100;
    }

    get moreFieldChoicesLabel() {
        const total = this.filteredFieldOptions.length;
        return `+${total - 100} more — narrow your search to see them`;
    }

    get fieldChoiceEmptyLabel() {
        if (!this.primaryObject) return 'Pick a template or data source first.';
        if (!this.fieldOptions.length) return 'No filterable fields loaded yet. Try a hard refresh of the page.';
        return 'No fields match your search.';
    }

    formatDataType(dataType) {
        if (!dataType) return '';
        const s = String(dataType).toLowerCase();
        if (s === 'string') return 'text';
        if (s === 'datetime') return 'date/time';
        if (s === 'reference') return 'lookup';
        return s;
    }

    get fieldCountLabel() {
        const total = this.fieldOptions.length;
        const shown = this.filteredFieldOptions.length;
        if (!this.primaryObject) {
            return 'Select a data source first';
        }
        if (!this.fieldSearchTerm) {
            return `${total} fields available`;
        }
        return `${shown} of ${total} fields shown`;
    }

    get hasFilters() {
        return this.filters.length > 0;
    }

    get addDisabled() {
        return !this.primaryObject || this.fieldOptions.length === 0;
    }

    get jsonOutput() {
        const conditions = this.filters
            .filter((row) => row.field && row.operator && this.isRowComplete(row))
            .map((row) => this.toCondition(row));
        if (conditions.length === 0) {
            return '[]';
        }
        if (this.filterLogic === 'OR') {
            return JSON.stringify({ logic: 'OR', conditions }, null, 2);
        }
        return JSON.stringify(conditions, null, 2);
    }

    async loadFields() {
        if (!this.primaryObject) {
            this.fieldsByApiName = {};
            this._loadedObject = null;
            return;
        }
        this._loadedObject = this.primaryObject;
        // If parent provided fieldMetadata, the setter already populated us.
        if (Array.isArray(this._fieldMetadata) && this._fieldMetadata.length) {
            return;
        }
        // Standalone usage: fall back to self-fetch.
        try {
            this.loadError = null;
            const describe = await describeObject({ objectApiName: this.primaryObject, depth: 0 });
            this._fieldMetadata = describe.fields || [];
            this.fieldsByApiName = this.toFieldsByApiName(this._fieldMetadata);
            this.filters = this.filters.map((row) => this.applyMeta(row, this.fieldsByApiName[row.field]));
        } catch (error) {
            this.loadError = error?.body?.message || error?.message || 'Could not load fields.';
            this._fieldMetadata = [];
            this.fieldsByApiName = {};
        }
    }

    handleFieldSearchChange(event) {
        this.fieldSearchTerm = event.detail?.value || event.target?.value || '';
    }

    addFilter() {
        this.filters = [...this.filters, this.makeRow()];
        this.reindex();
        this.fireChange();
    }

    handleFieldChoiceClick(event) {
        const apiName = event.currentTarget.dataset.field;
        if (!apiName) return;
        const meta = this.fieldsByApiName[apiName];
        const seed = { field: apiName };
        const newRow = this.makeRow(seed);
        this.filters = [...this.filters, newRow];
        this.reindex();
        this.fireChange();
    }

    removeFilter(event) {
        const id = event.currentTarget.dataset.id;
        this.filters = this.filters.filter((row) => row.id !== id);
        this.reindex();
        this.fireChange();
    }

    handleFieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const apiName = event.detail.value;
        const meta = this.fieldsByApiName[apiName];
        this.filters = this.filters.map((row) =>
            row.id === id ? this.applyMeta({ ...row, field: apiName, operator: null, value: null }, meta) : row
        );
        this.fireChange();
    }

    handleOperatorChange(event) {
        const id = event.currentTarget.dataset.id;
        const operator = event.detail.value;
        this.filters = this.filters.map((row) => {
            if (row.id !== id) return row;
            const showValue = !NO_VALUE_OPS.has(operator);
            return {
                ...row,
                operator,
                value: showValue ? row.value : null,
                showValue,
                valuePlaceholder: this.placeholderFor(operator)
            };
        });
        this.fireChange();
    }

    handleValueChange(event) {
        const id = event.currentTarget.dataset.id;
        const value = event.detail.value;
        this.filters = this.filters.map((row) => (row.id === id ? { ...row, value } : row));
        this.fireChange();
    }

    handleLogicChange(event) {
        this.filterLogic = event.detail.value;
        this.fireChange();
    }

    makeRow(seed = {}) {
        const meta = seed.field ? this.fieldsByApiName[seed.field] : null;
        return this.applyMeta(
            {
                id: newId(),
                field: seed.field || null,
                operator: seed.operator || null,
                value: seed.value === undefined ? null : seed.value,
                displayIndex: 0,
                operatorOptions: [],
                valueOptions: [],
                operatorDisabled: true,
                showValue: true,
                valuePlaceholder: '',
                isDate: false,
                isDatetime: false,
                isNumber: false,
                isPicklist: false,
                isMultiPicklist: false,
                isBoolean: false,
                isText: false
            },
            meta
        );
    }

    applyMeta(row, meta) {
        const dataType = meta && meta.dataType ? String(meta.dataType).toUpperCase() : null;
        const operatorOptions = this.operatorsForType(dataType);
        const isRelative = RELATIVE_OPS.has(row.operator);
        const valueOptions = isRelative ? RELATIVE_DATE_TOKENS : this.picklistOptions(meta);
        const showValue = !NO_VALUE_OPS.has(row.operator);
        const flags = this.flagsForType(dataType, row.operator);
        return {
            ...row,
            ...flags,
            operatorOptions,
            valueOptions,
            operatorDisabled: !dataType,
            showValue,
            valuePlaceholder: this.placeholderFor(row.operator)
        };
    }

    operatorsForType(dataType) {
        switch (dataType) {
            case 'CURRENCY':
            case 'DOUBLE':
            case 'INTEGER':
            case 'LONG':
            case 'PERCENT':
                return NUMBER_OPS;
            case 'DATE':
            case 'DATETIME':
            case 'TIME':
                return DATE_OPS;
            case 'PICKLIST':
            case 'COMBOBOX':
                return PICKLIST_OPS;
            case 'MULTIPICKLIST':
                return MULTIPICKLIST_OPS;
            case 'BOOLEAN':
                return BOOLEAN_OPS;
            case 'REFERENCE':
            case 'ID':
                return REFERENCE_OPS;
            case null:
            case undefined:
                return [];
            default:
                return TEXT_OPS;
        }
    }

    flagsForType(dataType, operator) {
        const isRelative = RELATIVE_OPS.has(operator);
        return {
            isDate: !isRelative && dataType === 'DATE',
            isDatetime: !isRelative && (dataType === 'DATETIME' || dataType === 'TIME'),
            isNumber: ['CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT'].includes(dataType),
            isPicklist: isRelative
                ? true
                : dataType === 'PICKLIST' || dataType === 'COMBOBOX',
            isMultiPicklist: dataType === 'MULTIPICKLIST',
            isBoolean: dataType === 'BOOLEAN',
            isText: !dataType || isRelative
                ? false
                : !['CURRENCY','DOUBLE','INTEGER','LONG','PERCENT','DATE','DATETIME','TIME','PICKLIST','COMBOBOX','MULTIPICKLIST','BOOLEAN'].includes(dataType)
        };
    }

    picklistOptions(meta) {
        if (!meta || !meta.picklistValues) return [];
        return meta.picklistValues.map((v) => ({ label: v, value: v }));
    }

    placeholderFor(operator) {
        if (operator === 'LIKE') return 'contains text';
        if (ARRAY_VALUE_OPS.has(operator)) return 'value1, value2';
        return '';
    }

    isRowComplete(row) {
        if (NO_VALUE_OPS.has(row.operator)) return true;
        return row.value !== null && row.value !== undefined && row.value !== '';
    }

    toCondition(row) {
        const condition = { field: row.field, operator: row.operator };
        if (NO_VALUE_OPS.has(row.operator)) {
            return condition;
        }
        if (RELATIVE_OPS.has(row.operator)) {
            condition.operator = RELATIVE_OP_TO_SOQL[row.operator];
            condition.value = row.value;
            return condition;
        }
        if (row.operator === 'LIKE') {
            // Escape user-typed wildcards so "50%" searches for the literal string,
            // not "anything containing 50". Backslash first to avoid double-escaping.
            const escaped = String(row.value || '')
                .replace(/\\/g, '\\\\')
                .replace(/[%_]/g, '\\$&');
            condition.value = `%${escaped}%`;
            return condition;
        }
        if (ARRAY_VALUE_OPS.has(row.operator)) {
            condition.value = String(row.value)
                .split(',')
                .map((s) => s.trim())
                .filter((s) => s.length > 0);
            return condition;
        }
        if (row.isBoolean) {
            condition.value = row.value === 'true' || row.value === true;
            return condition;
        }
        if (row.isNumber) {
            const n = Number(row.value);
            condition.value = Number.isFinite(n) ? n : row.value;
            return condition;
        }
        condition.value = row.value;
        return condition;
    }

    fromCondition(c) {
        const seed = { field: c.field || c.path, operator: (c.operator || '').toUpperCase() };
        // Round-trip: if the stored operator is a SOQL one and the value is a date literal, restore the relative-op variant.
        if (typeof c.value === 'string' && /^[A-Z_]+(:\d+)?$/.test(c.value) && ['=', '<', '>'].includes(seed.operator)) {
            seed.operator = 'REL' + seed.operator;
            seed.value = c.value;
            return seed;
        }
        if (NO_VALUE_OPS.has(seed.operator)) {
            seed.value = null;
        } else if (seed.operator === 'LIKE' && typeof c.value === 'string') {
            seed.value = c.value.replace(/^%/, '').replace(/%$/, '');
        } else if (Array.isArray(c.value)) {
            seed.value = c.value.join(', ');
        } else if (typeof c.value === 'boolean') {
            seed.value = String(c.value);
        } else {
            seed.value = c.value === null || c.value === undefined ? null : String(c.value);
        }
        return seed;
    }

    tryHydrate() {
        let parsed;
        try {
            parsed = JSON.parse(this.initialJson || '[]');
        } catch {
            this.filters = [];
            return;
        }
        let conditions = [];
        if (Array.isArray(parsed)) {
            conditions = parsed;
            this.filterLogic = 'AND';
        } else if (parsed && typeof parsed === 'object') {
            conditions = parsed.conditions || [];
            this.filterLogic = (parsed.logic || 'AND').toUpperCase() === 'OR' ? 'OR' : 'AND';
        }
        this.filters = conditions
            .filter((c) => c && (c.field || c.path))
            .map((c) => this.makeRow(this.fromCondition(c)));
        this.reindex();
    }

    reindex() {
        this.filters = this.filters.map((row, i) => ({ ...row, displayIndex: i + 1 }));
    }

    fireChange() {
        this.dispatchEvent(
            new CustomEvent('filterschange', {
                detail: { value: this.jsonOutput }
            })
        );
    }

    toFieldsByApiName(fields = []) {
        return (fields || []).reduce((map, field) => {
            if (field?.apiName && field.filterable) {
                map[field.apiName] = field;
            }
            return map;
        }, {});
    }

    fieldOptionLabel(field) {
        const label = field.label || field.apiName;
        return label === field.apiName ? label : `${label} (${field.apiName})`;
    }

    fieldSearchText(field) {
        return this.normalizeSearch([
            field.label,
            field.apiName,
            field.dataType
        ].filter(Boolean).join(' '));
    }

    normalizeSearch(value) {
        return String(value || '').trim().toLowerCase();
    }
}