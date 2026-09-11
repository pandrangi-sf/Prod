import { LightningElement, api, track } from 'lwc';
import searchObjects from '@salesforce/apex/CR_ObjectDescribeService.searchObjects';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';
import buildDatasetDefinition from '@salesforce/apex/CR_ObjectDescribeService.buildDatasetDefinition';

// Bound on the in-memory describe cache. Each describe payload can be
// 50-200 KB on objects with many fields/relationships. With no cap, switching
// between objects across a long session retains every describe forever and
// pushes the JS heap toward the browser's allocation ceiling.
const DESCRIBE_CACHE_MAX = 8;
const OBJECT_SEARCH_LIMIT = 75;
const RELATED_OPTION_RENDER_LIMIT = 200;
const FIELD_OPTION_RENDER_LIMIT = 300;

export default class CrObjectFieldSelector extends LightningElement {
    @track objectOptions = [];
    @track relatedOptions = [];
    @track fieldOptions = [];
    @track selectedRelatedObjects = [];
    @track selectedFields = [];
    @track objectLoading = false;
    @track relatedFilterTerm = '';
    @track fieldFilterTerm = '';
    @track draggingField = '';

    @track _primaryObject;
    // Backing fields for the hydration props. The parent re-passes these every
    // time the Columns step re-mounts (after the user navigated away and back)
    // so we can restore the user's prior selection without forcing them to re-pick.
    @track _initialRelatedRelationships = [];
    @track _initialFieldPaths = [];
    datasetJson = '{}';
    describeCache = new Map();
    fieldOptionByValue = new Map();
    _hydrated = false;
    _objectSearchRequest = 0;

    @api
    get primaryObject() {
        return this._primaryObject;
    }
    set primaryObject(value) {
        if (this._primaryObject === value) {
            return;
        }
        this._primaryObject = value;
        this._hydrated = false;
    }

    // Relationship NAMES (e.g., "Account", "Owner"), not object API names —
    // relationship names are the unit the checkbox-group binds to and the only
    // form that round-trips losslessly (Owner/CreatedBy/LastModifiedBy all map
    // to User). The parent stores the verbatim list in datasetDefinition and
    // re-passes it here on remount.
    @api
    get initialRelatedRelationships() {
        return this._initialRelatedRelationships;
    }
    set initialRelatedRelationships(value) {
        const next = Array.isArray(value) ? value : [];
        // Array identity changes on every parent render — compare contents to
        // avoid re-firing the hydrate cycle if nothing actually changed.
        if (this._sameArray(this._initialRelatedRelationships, next)) return;
        this._initialRelatedRelationships = next;
        this._hydrated = false;
    }

    @api
    get initialFieldPaths() {
        return this._initialFieldPaths;
    }
    set initialFieldPaths(value) {
        const next = Array.isArray(value) ? value : [];
        if (this._sameArray(this._initialFieldPaths, next)) return;
        this._initialFieldPaths = next;
        this._hydrated = false;
    }

    _sameArray(a, b) {
        if (a === b) return true;
        if (!a || !b || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }

    get hasPrimaryObject() {
        return !!this._primaryObject;
    }

    get filteredRelatedOptions() {
        return this.filterOptions(
            this.relatedOptions,
            this.relatedFilterTerm,
            this.selectedRelatedObjects,
            RELATED_OPTION_RENDER_LIMIT
        );
    }

    get filteredFieldOptions() {
        return this.filterOptions(
            this.fieldOptions,
            this.fieldFilterTerm,
            this.selectedFields,
            FIELD_OPTION_RENDER_LIMIT
        );
    }

    get hasSelectedFields() {
        return (this.selectedFields || []).length > 0;
    }

    get selectedFieldRows() {
        const selected = this.selectedFields || [];
        return selected.map((value, index) => {
            const option = this.fieldOptionByValue.get(value);
            return {
                value,
                label: option?.label || value,
                position: index + 1,
                isFirst: index === 0,
                isLast: index === selected.length - 1,
                cssClass: value === this.draggingField ? 'selected-field-row dragging' : 'selected-field-row'
            };
        });
    }

    connectedCallback() {
        this.loadObjects();
    }

    async renderedCallback() {
        // Hydrate on first render when the parent passed in a primaryObject + (optionally)
        // initial fields / related relationships. Phase 1 v16: robust matcher that
        // handles every observed source of init-path / option-value mismatch
        // (bare names, object-prefixed names, relationship-prefixed names, and
        // catch-all by field-apiName-only when nothing else works).
        if (!this._hydrated && this._primaryObject) {
            this._hydrated = true;
            try {
                await this.loadDescribe(this._primaryObject);
                if (this._initialRelatedRelationships.length) {
                    this.selectedRelatedObjects = [...this._initialRelatedRelationships];
                    for (const relationship of this.selectedRelationships()) {
                        // eslint-disable-next-line no-await-in-loop
                        await this.loadDescribe(relationship.objectApiName);
                    }
                }
                this.ensurePrimaryObjectOption();
                this.rebuildOptions();
                if (this._initialFieldPaths.length) {
                    this.selectedFields = this.matchInitialFieldPaths(this._initialFieldPaths);
                }
            } catch (err) {
                // eslint-disable-next-line no-console
                console.error('[crObjectFieldSelector] hydration failed:', err);
            }
        }
    }

    // Three-pass matcher. Returns canonical option values for whatever subset of
    // the inbound paths can be resolved against the current fieldOptions, in the
    // user's original order. All comparisons are case-insensitive because the
    // Apex describe historically returned field apiNames in lowercase (a quirk
    // of Schema.fields.getMap().keySet()) while templates and saved reports use
    // proper case. The matched value pushed onto selectedFields is always the
    // option's actual canonical-case value, so downstream emit/save stay clean.
    //
    //   Pass 1: direct (case-insensitive) equality on the full option value.
    //           Catches manual-picked paths re-loaded into the selector
    //           ("Fact_Opportunity__c.Amount__c" matches its own option).
    //   Pass 2: prefix with primaryObject, then direct case-insensitive equality.
    //           Catches template paths emitted as bare API names
    //           ("Amount__c" → "Fact_Opportunity__c.Amount__c" → option).
    //   Pass 3: last-segment case-insensitive fallback. For anything else,
    //           accept the unique option whose final field-apiName segment
    //           matches. Skipped on ambiguity (e.g., two related objects both
    //           with a "Name" field).
    matchInitialFieldPaths(paths) {
        const optionValues = (this.fieldOptions || []).map((o) => o.value);
        // Case-insensitive lookup: lowercase key → canonical option value
        const directHit = new Map();
        for (const v of optionValues) {
            directHit.set(v.toLowerCase(), v);
        }
        const byLastSegment = new Map();
        for (const v of optionValues) {
            const idx = v.lastIndexOf('.');
            const key = (idx >= 0 ? v.substring(idx + 1) : v).toLowerCase();
            if (!byLastSegment.has(key)) byLastSegment.set(key, []);
            byLastSegment.get(key).push(v);
        }
        const matched = [];
        const missed = [];
        for (const path of paths) {
            const pathLc = path.toLowerCase();
            // Pass 1
            if (directHit.has(pathLc)) {
                matched.push(directHit.get(pathLc));
                continue;
            }
            // Pass 2
            if (this._primaryObject) {
                const prefixedLc = `${this._primaryObject}.${path}`.toLowerCase();
                if (directHit.has(prefixedLc)) {
                    matched.push(directHit.get(prefixedLc));
                    continue;
                }
            }
            // Pass 3
            const idx = path.lastIndexOf('.');
            const segKey = (idx >= 0 ? path.substring(idx + 1) : path).toLowerCase();
            const candidates = byLastSegment.get(segKey) || [];
            if (candidates.length === 1) {
                matched.push(candidates[0]);
                continue;
            }
            missed.push(path);
        }
        if (missed.length) {
            // eslint-disable-next-line no-console
            console.warn(
                `[crObjectFieldSelector] could not match ${missed.length} of ${paths.length} initialFieldPaths against ${optionValues.length} options:`,
                missed
            );
        }
        return matched;
    }

    async loadObjects() {
        await this.searchForObjects('');
    }

    async handleObjectSearch(event) {
        await this.searchForObjects(event.detail.searchTerm || '');
    }

    async searchForObjects(searchTerm) {
        const requestId = ++this._objectSearchRequest;
        this.objectLoading = true;
        try {
            const objects = await searchObjects({ searchTerm, maxResults: OBJECT_SEARCH_LIMIT });
            if (requestId !== this._objectSearchRequest) {
                return;
            }
            this.objectOptions = [...objects]
                .sort((a, b) => a.label.localeCompare(b.label))
                .map((objectInfo) => ({
                    label: objectInfo.label,
                    value: objectInfo.apiName,
                    meta: objectInfo.apiName
                }));
            this.ensurePrimaryObjectOption();
        } catch {
            if (requestId === this._objectSearchRequest) {
                this.objectOptions = [];
                this.ensurePrimaryObjectOption();
            }
        } finally {
            if (requestId === this._objectSearchRequest) {
                this.objectLoading = false;
            }
        }
    }

    async handlePrimaryChange(event) {
        this._primaryObject = event.detail.value;
        this.selectedRelatedObjects = [];
        this.selectedFields = [];
        this.relatedFilterTerm = '';
        this.fieldFilterTerm = '';
        await this.loadDescribe(this._primaryObject);
        this.rebuildOptions();
        await this.emitDataset();
    }

    handleRelatedFilterChange(event) {
        this.relatedFilterTerm = event.target.value || '';
    }

    handleFieldFilterChange(event) {
        this.fieldFilterTerm = event.target.value || '';
    }

    async handleRelatedChange(event) {
        this.selectedRelatedObjects = event.detail.value;
        for (const relationship of this.selectedRelationships()) {
            // eslint-disable-next-line no-await-in-loop
            await this.loadDescribe(relationship.objectApiName);
        }
        this.rebuildOptions();
        await this.emitDataset();
    }

    async handleFieldChange(event) {
        this.selectedFields = event.detail.value;
        await this.emitDataset();
    }

    // One-click bulk-add for users whose workflow is "give me everything on this
    // object, I'll filter in Excel." Selects every option currently in fieldOptions
    // (which already respects the user-selected related objects and any active
    // search filter). Preserves order of the existing selection at the front so
    // the user's manual ordering isn't clobbered.
    async handleSelectAllFields() {
        const all = (this.fieldOptions || []).map((option) => option.value);
        const seen = new Set();
        const merged = [];
        for (const v of this.selectedFields || []) {
            if (!seen.has(v) && all.includes(v)) {
                seen.add(v);
                merged.push(v);
            }
        }
        for (const v of all) {
            if (!seen.has(v)) {
                seen.add(v);
                merged.push(v);
            }
        }
        this.selectedFields = merged;
        await this.emitDataset();
    }

    get selectAllLabel() {
        const total = (this.fieldOptions || []).length;
        return total ? `Select All (${total})` : 'Select All';
    }

    get selectAllDisabled() {
        const total = (this.fieldOptions || []).length;
        if (!total) return true;
        return (this.selectedFields || []).length >= total;
    }

    handleFieldDragStart(event) {
        this.draggingField = event.currentTarget.dataset.value;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this.draggingField);
    }

    handleFieldDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
    }

    async handleFieldDrop(event) {
        event.preventDefault();
        const source = this.draggingField || event.dataTransfer.getData('text/plain');
        const target = event.currentTarget.dataset.value;
        const sourceIndex = this.selectedFields.indexOf(source);
        const targetIndex = this.selectedFields.indexOf(target);
        await this.reorderSelectedField(source, target, sourceIndex < targetIndex);
    }

    handleFieldDragEnd() {
        this.draggingField = '';
    }

    async moveSelectedFieldUp(event) {
        const value = event.currentTarget.dataset.value;
        const index = this.selectedFields.indexOf(value);
        if (index <= 0) {
            return;
        }
        const target = this.selectedFields[index - 1];
        await this.reorderSelectedField(value, target);
    }

    async moveSelectedFieldDown(event) {
        const value = event.currentTarget.dataset.value;
        const index = this.selectedFields.indexOf(value);
        if (index < 0 || index >= this.selectedFields.length - 1) {
            return;
        }
        const target = this.selectedFields[index + 1];
        await this.reorderSelectedField(value, target, true);
    }

    async reorderSelectedField(source, target, placeAfterTarget = false) {
        if (!source || !target || source === target) {
            this.draggingField = '';
            return;
        }
        const next = [...(this.selectedFields || [])];
        const fromIndex = next.indexOf(source);
        const targetIndex = next.indexOf(target);
        if (fromIndex < 0 || targetIndex < 0) {
            this.draggingField = '';
            return;
        }
        next.splice(fromIndex, 1);
        let insertIndex = next.indexOf(target);
        if (placeAfterTarget) {
            insertIndex += 1;
        }
        next.splice(insertIndex, 0, source);
        this.selectedFields = next;
        this.draggingField = '';
        await this.emitDataset();
    }

    async loadDescribe(objectApiName) {
        if (!objectApiName) return;
        if (this.describeCache.has(objectApiName)) {
            // Move-to-end so most-recently-used wins eviction.
            const existing = this.describeCache.get(objectApiName);
            this.describeCache.delete(objectApiName);
            this.describeCache.set(objectApiName, existing);
            return;
        }
        const describe = await describeObject({ objectApiName, depth: 1 });
        // Evict the oldest entry once the cache exceeds the LRU bound.
        // Map iteration is insertion-ordered, so the first key is the oldest.
        while (this.describeCache.size >= DESCRIBE_CACHE_MAX) {
            const oldest = this.describeCache.keys().next().value;
            if (oldest === undefined) break;
            this.describeCache.delete(oldest);
        }
        this.describeCache.set(objectApiName, describe);
    }

    disconnectedCallback() {
        // Release any retained describe payloads when this component leaves the DOM.
        this.describeCache.clear();
    }

    rebuildOptions() {
        const primaryDescribe = this.describeCache.get(this._primaryObject);
        if (!primaryDescribe) {
            this.relatedOptions = [];
            this.fieldOptions = [];
            this.fieldOptionByValue = new Map();
            return;
        }

        const related = [];
        for (const relationship of primaryDescribe.parentRelationships || []) {
            if (!relationship.relationshipName) {
                continue;
            }
            related.push({
                label: `${relationship.label} (${relationship.relationshipName}) - parent`,
                value: relationship.relationshipName
            });
        }
        for (const relationship of primaryDescribe.childRelationships || []) {
            if (!relationship.relationshipName) {
                continue;
            }
            related.push({
                label: `${relationship.label} (${relationship.relationshipName}) - child`,
                value: relationship.relationshipName
            });
        }
        this.relatedOptions = this.uniqueOptions(related).sort((a, b) => a.label.localeCompare(b.label));

        const fieldOptions = [];
        // Primary-object fields use the bare field label — the primary object is
        // implicit within a single report, and Salesforce's standard report builder
        // takes the same approach. Phase 1 v18: previously prepended the object
        // label ("Fact Visit Activity Service: Subject"), which then leaked into
        // saved-report column headers via fieldLabels[path] → engine column.label.
        for (const field of primaryDescribe.fields || []) {
            fieldOptions.push({
                label: field.label,
                value: `${this._primaryObject}.${field.apiName}`
            });
        }
        // Related-object fields keep the relationship prefix so two related objects
        // with the same field name ("Owner: Email" vs "CreatedBy: Email") remain
        // disambiguated.
        for (const relationship of this.selectedRelationships(primaryDescribe)) {
            const relatedDescribe = this.describeCache.get(relationship.objectApiName);
            if (!relatedDescribe) {
                continue;
            }
            for (const field of relatedDescribe.fields || []) {
                fieldOptions.push({
                    label: `${relationship.relationshipName}: ${field.label}`,
                    value: `${relationship.relationshipName}.${field.apiName}`
                });
            }
        }
        this.fieldOptions = this.uniqueOptions(fieldOptions).sort((a, b) => a.label.localeCompare(b.label));
        this.fieldOptionByValue = new Map(this.fieldOptions.map((option) => [option.value, option]));
        this.pruneSelectedFields();
    }

    ensurePrimaryObjectOption() {
        if (!this._primaryObject) {
            return;
        }
        const describe = this.describeCache.get(this._primaryObject);
        const objectInfo = describe?.objectInfo;
        const label = objectInfo?.label || this._primaryObject;
        const existing = (this.objectOptions || []).find((option) => option.value === this._primaryObject);
        if (existing) {
            // The option may have been pre-seeded with the API name before the
            // describe resolved; upgrade it to the describe label once available.
            if (objectInfo?.label && existing.label !== label) {
                this.objectOptions = (this.objectOptions || [])
                    .map((option) => (option.value === this._primaryObject ? { ...option, label } : option))
                    .sort((a, b) => a.label.localeCompare(b.label));
            }
            return;
        }
        const option = {
            label,
            value: this._primaryObject,
            meta: this._primaryObject
        };
        this.objectOptions = this.uniqueOptions([option, ...(this.objectOptions || [])])
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    async emitDataset() {
        if (!this._primaryObject) {
            return;
        }
        const datasetJson = await buildDatasetDefinition({
            primaryObject: this._primaryObject,
            relatedObjects: this.uniqueValues(this.selectedRelationships().map((relationship) => relationship.objectApiName)),
            fieldPaths: this.selectedFields
        });
        const definition = JSON.parse(datasetJson);
        definition.fieldLabels = this.selectedFieldLabels();
        // Round-trip the relationship-name set (the verbatim checkbox-group values),
        // not just the object-name set. Object names are non-unique when multiple
        // relationships point at the same object (e.g., Owner/CreatedBy/LastModifiedBy
        // all → User), so the parent needs the relationship names to restore the
        // exact checkbox state when the Columns step re-mounts.
        definition.relatedRelationships = [...(this.selectedRelatedObjects || [])];
        this.datasetJson = JSON.stringify(definition, null, 2);
        this.dispatchEvent(
            new CustomEvent('datasetchange', {
                detail: {
                    json: this.datasetJson,
                    definition
                }
            })
        );
    }

    uniqueOptions(options) {
        const byValue = new Map();
        options.forEach((option) => byValue.set(option.value, option));
        return [...byValue.values()];
    }

    selectedFieldLabels() {
        return (this.selectedFields || []).reduce((labels, path) => {
            labels[path] = this.fieldOptionByValue.get(path)?.label || path;
            return labels;
        }, {});
    }

    filterOptions(options, term, selectedValues, renderLimit) {
        const trimmed = (term || '').trim().toLowerCase();
        const selected = new Set(selectedValues || []);
        if (!trimmed) {
            return this.limitOptions(options, selected, renderLimit);
        }
        const filtered = options.filter((option) => {
            if (selected.has(option.value)) {
                return true;
            }
            return (
                (option.label || '').toLowerCase().includes(trimmed) ||
                (option.value || '').toLowerCase().includes(trimmed)
            );
        });
        return this.limitOptions(filtered, selected, renderLimit);
    }

    limitOptions(options, selected, renderLimit) {
        if (!renderLimit || (options || []).length <= renderLimit) {
            return options || [];
        }
        const limited = [];
        let visibleCount = 0;
        for (const option of options || []) {
            if (selected.has(option.value)) {
                limited.push(option);
                continue;
            }
            if (visibleCount < renderLimit) {
                limited.push(option);
                visibleCount += 1;
            }
        }
        return limited;
    }

    selectedRelationships(primaryDescribe = this.describeCache.get(this._primaryObject)) {
        const selected = new Set(this.selectedRelatedObjects || []);
        const parents = (primaryDescribe?.parentRelationships || []).filter(
            (relationship) => relationship.relationshipName && selected.has(relationship.relationshipName)
        );
        const children = (primaryDescribe?.childRelationships || []).filter(
            (relationship) => relationship.relationshipName && selected.has(relationship.relationshipName)
        );
        return [...parents, ...children];
    }

    pruneSelectedFields() {
        if (!this.selectedFields.length) {
            return;
        }
        const available = new Set(this.fieldOptions.map((option) => option.value));
        this.selectedFields = this.selectedFields.filter((field) => available.has(field));
    }

    uniqueValues(values) {
        return [...new Set(values)];
    }
}