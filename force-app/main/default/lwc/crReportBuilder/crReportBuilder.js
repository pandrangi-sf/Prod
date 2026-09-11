import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import saveReport from '@salesforce/apex/CR_ReportDefinitionService.saveReport';
import listReports from '@salesforce/apex/CR_ReportDefinitionService.listReports';
import loadReport from '@salesforce/apex/CR_ReportDefinitionService.loadReport';
import describeObject from '@salesforce/apex/CR_ObjectDescribeService.describeObject';
import { TEMPLATES } from './templates';
import { applyBrandTheme } from 'c/crBrandTheme';

const FALLBACK_DATASET = {
    datasetKey: 'Opportunity_Hybrid',
    mode: 'hybrid',
    objectApiName: 'Fact_Opportunity__c',
    primaryObject: 'Fact_Opportunity__c'
};

// Per-template flair surfaced in the gallery cards. Keep these in sync with
// templates.js when new entries are added; missing keys fall back to a generic
// description and icon (see templateGalleryItems).
const TEMPLATE_DESCRIPTIONS = {
    pipeline_by_stage: 'Open opportunity pipeline grouped by stage with totals.',
    won_by_owner: 'Won opportunities aggregated by owner. Pivot view.',
    cases_by_priority: 'Open cases broken out by priority with average age.',
    activities_visits: 'Tasks tied to Visit Reports — TaskRelations, Visit Services, all 12 standard activity columns.',
    al_activities_with_services: 'Alabama PRM visits exploded one row per service per attendee.',
    fl_activities_with_services: 'Florida PRM visits exploded one row per service per attendee.',
    al_activities_with_collateral: 'Alabama PRM visits with the collateral handed out on each.',
    fl_activities_with_collateral: 'Florida PRM visits with the collateral handed out on each.',
    al_collateral_by_location: 'Alabama collateral distribution sorted by location, then visit date.',
    al_activities_with_objections: 'Alabama PRM visits with objections raised — facility, type, notes.',
    fl_activities_with_objections: 'Florida PRM visits with objections raised — facility, type, notes.',
    al_target_report: 'Alabama Targets joined to active provider locations and address detail.',
    fl_unzoned_targets: 'Florida targets with no active zoned coverage — gap analysis.',
    al_unzoned_targets: 'Alabama targets with no active zoned coverage — gap analysis.',
    zoned_location_gaps: 'Zoned locations the PRM has claimed but where no provider is targeted yet.'
};

const TEMPLATE_ICONS = {
    pipeline_by_stage: 'utility:opportunity',
    won_by_owner: 'utility:user',
    cases_by_priority: 'utility:case',
    activities_visits: 'utility:event',
    al_activities_with_services: 'utility:concur_apps',
    fl_activities_with_services: 'utility:concur_apps',
    al_activities_with_collateral: 'utility:file',
    fl_activities_with_collateral: 'utility:file',
    al_collateral_by_location: 'utility:location',
    al_activities_with_objections: 'utility:warning',
    fl_activities_with_objections: 'utility:warning',
    al_target_report: 'utility:target',
    fl_unzoned_targets: 'utility:filter',
    al_unzoned_targets: 'utility:filter',
    zoned_location_gaps: 'utility:checkin'
};

export default class CrReportBuilder extends NavigationMixin(LightningElement) {
    @track datasetDefinition;
    @track currentStep = 'data';
    // Sub-view of the Data step (the 4-card launcher and its branches).
    // Values: 'launcher' | 'template' | 'clone' | 'import' | 'blank'
    @track dataSubstep = 'launcher';
    @track cloneSearchTerm = '';
    @track savedReportId = null;
    @track savedReportVersion = null;
    @track savedReportList = [];
    @track selectedTemplate = '';
    @track selectedCloneId = '';
    @track importNeedsBaseObject = false;
    @track fieldMetadata = [];
    @track previewMounted = false;
    @track unsupportedImports = [];
    @track resetInProgress = false;
    @track previewWidth = 560;
    // Region toggles. Templates prefixed `al_` are Alabama-specific; `fl_` are Florida-specific.
    // Anything else is general and stays visible regardless of toggle state. With both off
    // the gallery shows everything (the default).
    @track regionFlorida = false;
    @track regionAlabama = false;

    _fieldMetadataObject = null;
    _fieldMetadataRelKey = '';
    _clearedReportId = null;
    _boundPreviewResize;
    _boundPreviewResizeEnd;
    _resizingPreview = false;
    _definitionJsonCache = null;
    _previewMountTimer;
    _previewIdleHandle;

    connectedCallback() {
        applyBrandTheme(this);
        this._boundPreviewResize = this.handlePreviewResize.bind(this);
        this._boundPreviewResizeEnd = this.stopPreviewResize.bind(this);
        this.schedulePreviewMount();
    }

    // Phase G: toggle the help drawer when the toolbar ? button is clicked
    // (first click opens, next click closes).
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    disconnectedCallback() {
        this.stopPreviewResize();
        clearTimeout(this._previewMountTimer);
        if (this._previewIdleHandle && window.cancelIdleCallback) {
            window.cancelIdleCallback(this._previewIdleHandle);
        }
    }

    reportName = 'New Custom Report';
    folder = 'Vital Reports';
    category = 'Ad Hoc';
    description = '';
    // Tracks which template (if any) the report was originally built from.
    // Stored inside Definition_JSON__c so we can detect template-origin reports
    // on edit and skip the Columns step (templates already define columns).
    templateSource = '';
    isPublic = false;
    chartType = 'bar';
    filtersJson = '[]';
    groupingsJson = '[]';
    aggregationsJson = '[]';
    formulasJson = '[]';
    summaryFormulasJson = '[]';
    bucketsJson = '[]';

    chartOptions = [
        { label: 'Bar', value: 'bar' },
        { label: 'Horizontal Bar', value: 'horizontal' },
        { label: 'Line', value: 'line' },
        { label: 'Area', value: 'area' },
        { label: 'Donut', value: 'donut' },
        { label: 'Pie', value: 'pie' },
        { label: 'Pivot', value: 'pivot' }
    ];

    wiredReportsResult;

    @wire(listReports, { searchTerm: '' })
    wiredReports(result) {
        this.wiredReportsResult = result;
        if (result.data) this.savedReportList = result.data;
        if (result.error) this.savedReportList = [];
    }

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (!pageRef) return;
        const incomingId = pageRef.state?.c__reportId;
        if (!incomingId) {
            this._clearedReportId = null;
            return;
        }
        if (incomingId === this._clearedReportId) {
            return;
        }
        if (incomingId && incomingId !== this.savedReportId) {
            this.hydrateFromReportId(incomingId);
        }
    }

    async hydrateFromReportId(reportId) {
        try {
            const record = await loadReport({ reportDefinitionId: reportId });
            this.applyLoadedReport(record);
            // Direct-load: this is an EDIT of the loaded record, not a clone.
            this.reportName = record.name;
            this.savedReportId = record.id;
            this.savedReportVersion = record.version;
            // applyLoadedReport reads templateSource from the saved JSON. For reports
            // saved before that key existed, fall back to matching the report Name
            // against known template reportNames so existing template-built reports
            // still skip the Columns step.
            if (!this.templateSource) {
                const matched = TEMPLATES.find((t) => t.reportName && t.reportName === record.name);
                if (matched) {
                    this.templateSource = matched.value;
                }
            }
            // Skip past the launcher/template gallery so users land on the editor.
            // Template-built reports already have their columns wired up — drop
            // straight into Filters (step 3). Ad-hoc reports need the Columns
            // step (step 2) to confirm the dataset/field selections.
            this.currentStep = this.templateSource ? 'filters' : 'columns';
            this.dataSubstep = 'blank';
        } catch (error) {
            this.toastError(error);
        }
    }

    get templateOptions() {
        return [{ label: '— Start blank —', value: '' }, ...TEMPLATES.map((t) => ({ label: t.label, value: t.value }))];
    }

    get cloneOptions() {
        return [
            { label: '— Don’t clone —', value: '' },
            ...(this.savedReportList || []).map((r) => ({ label: r.name, value: r.id }))
        ];
    }

    // primaryObject and hasDataset answer different questions on purpose.
    //   primaryObject: "what should we render in the JSON / pass to the engine?"
    //                  Falls back to Fact_Opportunity__c so the master JSON
    //                  preview is never empty.
    //   hasDataset:    "did the user actually choose something?"
    //                  No fallback; drives Save gating and the requirements list.
    // Don't unify these without understanding both call sites.
    get primaryObject() {
        return this.datasetDefinition?.primaryObject || FALLBACK_DATASET.primaryObject;
    }

    get primaryObjectForChild() {
        // Don't push the FALLBACK_DATASET default down to crObjectFieldSelector;
        // we only want it to pre-populate when the user (or import) actually picked one.
        return this.datasetDefinition?.primaryObject || null;
    }

    // Re-seed crObjectFieldSelector when the Columns step re-mounts (the user
    // navigated away and clicked Back). Without these, the child's internal
    // selection state resets to empty and any prior selections are visually lost.
    get initialRelatedRelationships() {
        const explicit = this.datasetDefinition?.relatedRelationships || [];
        if (explicit.length) return explicit;
        // Backward compat: reports saved before the relatedRelationships round-trip
        // landed don't have an explicit list. Derive it from 2-segment field paths
        // whose first segment is a relationship name (anything other than the
        // primary object's API name).
        return this.deriveRelatedRelationships(
            this.datasetDefinition?.primaryObject,
            this.datasetDefinition?.fieldPaths
        );
    }

    get initialFieldPaths() {
        return this.datasetDefinition?.fieldPaths || [];
    }

    deriveRelatedRelationships(primaryObject, fieldPaths) {
        if (!primaryObject || !Array.isArray(fieldPaths)) return [];
        const set = new Set();
        for (const path of fieldPaths) {
            if (typeof path !== 'string') continue;
            const segments = path.split('.');
            // Selector emits 2-segment paths: "RelationshipName.FieldApiName" for
            // related fields, "PrimaryObject.FieldApiName" for primary fields.
            // Three-segment paths (Task.Owner.Name from templates) and bare apiNames
            // (Fact_Opportunity__c primary fields) don't fit the selector model and
            // are skipped — they wouldn't round-trip cleanly through the selector
            // anyway.
            if (segments.length !== 2) continue;
            if (segments[0] === primaryObject) continue;
            set.add(segments[0]);
        }
        return [...set];
    }

    get isStepData() { return this.currentStep === 'data'; }
    get isStepColumns() { return this.currentStep === 'columns'; }
    get isStepFilters() { return this.currentStep === 'filters'; }
    get isStepGroup() { return this.currentStep === 'group'; }
    get isStepVisualize() { return this.currentStep === 'visualize'; }
    get isStepSave() { return this.currentStep === 'save'; }
    get showBuilderContent() { return !this.resetInProgress; }

    // ─── Step 1 launcher state ────────────────────────────────────────────────
    // The Data step is split into a 4-card launcher + four branches. Each branch
    // has its own UI (template gallery, saved-reports list, standard-report importer,
    // or the legacy free-form configuration). The substep state controls which one
    // shows; the launcher lets the user pick a starting point.
    get isSubstepLauncher() { return this.dataSubstep === 'launcher'; }
    get isSubstepTemplate() { return this.dataSubstep === 'template'; }
    get isSubstepClone() { return this.dataSubstep === 'clone'; }
    get isSubstepImport() { return this.dataSubstep === 'import'; }
    get isSubstepBlank() { return this.dataSubstep === 'blank'; }
    get isSubstepCurated() { return this.dataSubstep === 'curated'; }

    // True only when the user is actively staring at the launcher tiles. Drives the
    // "hide chrome" treatment — Back/Next/Clear, the live-preview pane, and the
    // preview resizer all collapse so the Step 1 picker reads as a clean landing page.
    get isOnLauncher() {
        return this.currentStep === 'data' && this.dataSubstep === 'launcher';
    }
    get showBuilderChrome() {
        return !this.isOnLauncher;
    }

    get launcherCards() {
        return [
            {
                key: 'template',
                title: 'Start from Template',
                description: 'Pick a pre-built report — fields, filters, and groupings preconfigured.',
                icon: 'standard:report_type',
                iconWrapClass: 'launcher-card__icon launcher-card__icon--purple',
                badge: 'Recommended',
                badgeClass: 'card-badge card-badge_recommended'
            },
            {
                key: 'clone',
                title: 'Clone Existing Report',
                description: 'Copy a saved report and tweak it without starting from scratch.',
                icon: 'standard:report',
                iconWrapClass: 'launcher-card__icon launcher-card__icon--blue',
                badge: '',
                badgeClass: ''
            },
            {
                key: 'import',
                title: 'Import from Standard Report',
                description: 'Pull a native Salesforce report into the builder to extend or modernize it.',
                icon: 'standard:data_streams',
                iconWrapClass: 'launcher-card__icon launcher-card__icon--amber',
                badge: '',
                badgeClass: ''
            },
            {
                key: 'curated',
                title: 'Use a Curated Dataset',
                description: 'Pick a maintained, pre-modeled dataset (Fact_Opportunity, Fact_Case, …).',
                icon: 'standard:dataset',
                iconWrapClass: 'launcher-card__icon launcher-card__icon--teal',
                badge: '',
                badgeClass: ''
            },
            {
                key: 'blank',
                title: 'Create New Custom Report',
                description: 'Start ad hoc — pick any object and build from scratch.',
                icon: 'standard:custom',
                iconWrapClass: 'launcher-card__icon launcher-card__icon--green',
                badge: '',
                badgeClass: ''
            }
        ];
    }

    get templateGalleryItems() {
        // Surface a couple of curated picks as "Recommended" — these are the templates
        // most likely to be useful out of the box. Tweak the set as the catalog grows.
        const recommendedSet = new Set(['activities_visits', 'al_activities_with_services', 'fl_activities_with_services']);
        return TEMPLATES
            .filter((t) => this.matchesRegionFilter(t.value))
            .map((t) => {
                const description = TEMPLATE_DESCRIPTIONS[t.value] || `Pre-configured ${t.label} report.`;
                const isRecommended = recommendedSet.has(t.value);
                return {
                    value: t.value,
                    title: t.label,
                    description,
                    icon: TEMPLATE_ICONS[t.value] || 'utility:rows',
                    isRecommended,
                    cardClass: isRecommended ? 'gallery-card gallery-card_recommended' : 'gallery-card'
                };
            });
    }

    matchesRegionFilter(templateValue) {
        // Both toggles off → no filter (default behavior).
        if (!this.regionFlorida && !this.regionAlabama) return true;
        const isAlabama = templateValue.startsWith('al_');
        const isFlorida = templateValue.startsWith('fl_');
        // Non-regional templates always show — they're cross-team utilities.
        if (!isAlabama && !isFlorida) return true;
        if (isAlabama && this.regionAlabama) return true;
        if (isFlorida && this.regionFlorida) return true;
        return false;
    }

    handleFloridaToggle() {
        this.regionFlorida = !this.regionFlorida;
    }

    handleAlabamaToggle() {
        this.regionAlabama = !this.regionAlabama;
    }

    // Pill-button toggle state classes — flipped between active and inactive
    // based on the corresponding region flag. The pill renders selected when
    // the region is on.
    get floridaPillClass() {
        return this.regionFlorida ? 'region-pill region-pill--active' : 'region-pill';
    }

    get alabamaPillClass() {
        return this.regionAlabama ? 'region-pill region-pill--active' : 'region-pill';
    }

    get cloneGalleryItems() {
        const term = (this.cloneSearchTerm || '').trim().toLowerCase();
        const list = this.savedReportList || [];
        const filtered = !term ? list : list.filter((r) =>
            (r.name || '').toLowerCase().includes(term) ||
            (r.folder || '').toLowerCase().includes(term) ||
            (r.category || '').toLowerCase().includes(term)
        );
        return filtered.map((r) => ({
            id: r.id,
            title: r.name || 'Untitled report',
            metaLine: this.formatCloneMetaLine(r),
            cardClass: 'gallery-card gallery-card_clone'
        }));
    }

    get hasCloneItems() {
        return this.cloneGalleryItems.length > 0;
    }

    get hasSavedReports() {
        return (this.savedReportList || []).length > 0;
    }

    get cloneEmptyLabel() {
        if (!this.hasSavedReports) return 'No saved reports yet — save one and it will appear here for cloning.';
        return 'No saved reports match your search.';
    }

    get builderLayoutStyle() {
        // On the launcher, collapse the workspace to a single column so the centered
        // card grid isn't squeezed against an empty preview track. Once the user picks
        // a path, restore the 3-column (main / resizer / preview) grid.
        if (this.isOnLauncher) {
            return 'grid-template-columns: 1fr;';
        }
        return `--preview-width: ${this.previewWidth}px;`;
    }

    get selectedFieldCount() {
        try {
            return (this.datasetDefinition?.fieldPaths || []).length;
        } catch {
            return 0;
        }
    }

    get hasReportName() { return !!(this.reportName && this.reportName.trim()); }
    get hasDataset() { return !!this.datasetDefinition?.primaryObject; }
    get hasFields() { return this.selectedFieldCount > 0; }

    get summaryFormulas() {
        return this.safeJson(this.summaryFormulasJson, []);
    }

    get hasImportReviewItems() {
        return (this.unsupportedImports || []).length > 0 || this.summaryFormulas.length > 0;
    }

    get importReviewRows() {
        const unsupported = (this.unsupportedImports || []).map((item, index) => ({
            id: `unsupported_${index}`,
            title: item.sourceName || item.sourceField || item.type || 'Imported item',
            badge: this.toTitle(item.type || 'review'),
            detail: [item.reason, item.recommendedAction].filter(Boolean).join(' '),
            cssClass: 'import-review-item'
        }));
        const formulas = this.summaryFormulas.map((item, index) => ({
            id: `summary_formula_${index}`,
            title: item.label || item.name || 'Summary Formula',
            badge: 'Summary Formula',
            detail: 'Preserved from the source report for review. It is not executed in preview, viewer, or export yet.',
            cssClass: 'import-review-item'
        }));
        return [...unsupported, ...formulas];
    }

    get saveDisabled() {
        // Mirror what CR_QueryEngine.validateDefinition will accept on the
        // server side, so users can't click Save and then get an Apex error
        // for a precondition we already know about client-side. Also disable
        // while an in-flight save is running so a fast second click can't
        // double-insert (the JS guard already short-circuits, but the visible
        // disable prevents the spinner-less double-click from feeling broken).
        return !this.hasReportName || !this.hasDataset || !this.hasFields || this._saveInFlight;
    }

    // Hover tooltip explaining why Save is greyed out, so the user
    // doesn't have to scan the requirements checklist below the button.
    get saveTooltip() {
        if (!this.saveDisabled) return 'Save this report';
        const missing = [];
        if (!this.hasReportName) missing.push('a report name');
        if (!this.hasDataset) missing.push('a data source');
        if (!this.hasFields) missing.push('at least one field');
        return `Add ${missing.join(', ')} to enable Save.`;
    }

    get requirementsList() {
        const items = [
            { ok: this.hasReportName, label: 'Report Name is set' },
            { ok: this.hasDataset, label: 'A data source is selected' },
            { ok: this.hasFields, label: 'At least one field is selected' }
        ];
        return items.map((i) => ({
            label: i.label,
            icon: i.ok ? '✓' : '•',
            cssClass: i.ok ? 'req-ok' : 'req-pending'
        }));
    }

    get definitionJson() {
        if (this._definitionJsonCache) {
            return this._definitionJsonCache;
        }
        const dataset = this.datasetDefinition || FALLBACK_DATASET;
        const fieldLabels = dataset.fieldLabels || {};
        const fields = (dataset.fieldPaths || ['Opportunity_Name__c', 'Amount__c', 'Stage_Name__c']).map((path) => ({
            path,
            label: fieldLabels[path] || path
        }));
        const definition = {
            dataset,
            fields,
            filters: this.safeJson(this.filtersJson, []),
            groupings: this.safeJson(this.groupingsJson, []),
            aggregations: this.safeJson(this.aggregationsJson, []),
            formulas: this.safeJson(this.formulasJson, []),
            summaryFormulas: this.summaryFormulas,
            buckets: this.safeJson(this.bucketsJson, []),
            unsupportedImports: this.unsupportedImports || [],
            sort: [{ field: 'Id', direction: 'ASC' }],
            pagination: { pageSize: 100, strategy: 'keyset' },
            chart: { type: this.chartType },
            drillDown: { enabled: true }
        };
        // Only attach templateSource when set so existing reports' JSON shape is unchanged.
        if (this.templateSource) {
            definition.templateSource = this.templateSource;
        }
        this._definitionJsonCache = JSON.stringify(definition, null, 2);
        return this._definitionJsonCache;
    }

    handleStepChange(event) {
        this.currentStep = event.detail.value;
    }

    handleDatasetChange(event) {
        const incoming = event.detail.definition;
        const prev = this.datasetDefinition;
        const prevIsCurated = prev?.datasetKey && !prev.datasetKey.endsWith('_AdHoc');
        if (prevIsCurated && incoming?.datasetKey?.endsWith('_AdHoc')) {
            this.datasetDefinition = {
                ...prev,
                primaryObject: incoming.primaryObject || prev.primaryObject,
                objectApiName: incoming.objectApiName || prev.objectApiName,
                relatedObjects: incoming.relatedObjects || prev.relatedObjects || [],
                relatedRelationships: incoming.relatedRelationships || prev.relatedRelationships || [],
                fieldPaths: incoming.fieldPaths || prev.fieldPaths || []
            };
            this.datasetDefinition.fieldLabels = {
                ...(prev.fieldLabels || {}),
                ...(incoming.fieldLabels || {})
            };
        } else {
            this.datasetDefinition = incoming;
        }
        if (this.datasetDefinition?.primaryObject) {
            this.importNeedsBaseObject = false;
        }
        this.invalidateDefinitionJson();
        this.refreshFieldMetadata();
        // When the user came in via the "Curated Dataset" launcher card, advance straight
        // to Columns after they pick a dataset. Ad-hoc stays put — they still need to set
        // a name/folder and then click Next themselves.
        if (this.dataSubstep === 'curated' && this.datasetDefinition?.primaryObject) {
            this.currentStep = 'columns';
        }
    }

    async refreshFieldMetadata() {
        const obj = this.datasetDefinition?.primaryObject;
        const explicitRels = this.datasetDefinition?.relatedRelationships || [];
        // Same backward-compat fallback as initialRelatedRelationships — keep the
        // two derivations identical so the selector and the merged fieldMetadata
        // can't disagree about which relationships are active.
        const relationships = explicitRels.length
            ? [...explicitRels]
            : this.deriveRelatedRelationships(obj, this.datasetDefinition?.fieldPaths);
        if (!obj) {
            this.fieldMetadata = [];
            this._fieldMetadataObject = null;
            this._fieldMetadataRelKey = '';
            return;
        }
        // Cache key combines primary + sorted-relationships so changing either
        // refetches but a no-op re-render is cheap.
        const relKey = relationships.slice().sort().join(',');
        if (obj === this._fieldMetadataObject && relKey === this._fieldMetadataRelKey) return;
        this._fieldMetadataObject = obj;
        this._fieldMetadataRelKey = relKey;
        this.fieldMetadata = [];
        try {
            const primaryDescribe = await describeObject({ objectApiName: obj, depth: 0 });
            // Race guard — another refresh may have moved on while we awaited.
            if (this._fieldMetadataObject !== obj || this._fieldMetadataRelKey !== relKey) return;
            const merged = [...(primaryDescribe?.fields || [])];
            if (relationships.length) {
                // Only PARENT relationships are merged into fieldMetadata: child-collection
                // fields can't be used as flat filter/grouping/aggregation operands in SOQL
                // (CR_QueryEngine.rejectChildCollectionPath would throw on save). Column
                // display still supports child relationships via expandChildRows; that path
                // doesn't read this metadata list.
                const objByRelName = new Map();
                for (const r of primaryDescribe?.parentRelationships || []) {
                    if (r.relationshipName && r.objectApiName) {
                        objByRelName.set(r.relationshipName, r.objectApiName);
                    }
                }
                for (const relName of relationships) {
                    const objName = objByRelName.get(relName);
                    if (!objName) continue;
                    try {
                        const relDescribe = await describeObject({ objectApiName: objName, depth: 0 });
                        if (this._fieldMetadataObject !== obj || this._fieldMetadataRelKey !== relKey) return;
                        for (const f of relDescribe?.fields || []) {
                            // Relationship-prefixed apiName matches the path format the engine
                            // and the field selector already use ("Account.Industry").
                            merged.push({ ...f, apiName: `${relName}.${f.apiName}` });
                        }
                    } catch (_e) {
                        // Inaccessible related object — skip it, don't fail the whole load.
                    }
                }
            }
            this.fieldMetadata = merged;
        } catch {
            if (this._fieldMetadataObject === obj && this._fieldMetadataRelKey === relKey) {
                this.fieldMetadata = [];
                this._fieldMetadataObject = null;
                this._fieldMetadataRelKey = '';
            }
        }
    }

    handleNameChange(event) { this.reportName = event.detail.value; }
    handleFolderChange(event) { this.folder = event.detail.value; }
    handleCategoryChange(event) { this.category = event.detail.value; }
    handleDescriptionChange(event) { this.description = event.detail.value; }
    handlePublicChange(event) { this.isPublic = event.detail.checked; }
    handleFiltersChange(event) {
        this.filtersJson = event.detail.value;
        this.invalidateDefinitionJson();
    }

    handleGroupingsChange(event) {
        this.groupingsJson = event.detail.value;
        this.invalidateDefinitionJson();
    }

    handleAggregationsChange(event) {
        this.aggregationsJson = event.detail.value;
        this.invalidateDefinitionJson();
    }

    handleFormulasChange(event) {
        this.formulasJson = event.detail.value;
        this.invalidateDefinitionJson();
    }

    handleBucketsChange(event) {
        this.bucketsJson = event.detail.value;
        this.invalidateDefinitionJson();
    }

    handleChartChange(event) {
        this.chartType = event.detail.value;
        this.invalidateDefinitionJson();
    }

    startPreviewResize(event) {
        event.preventDefault();
        this._resizingPreview = true;
        window.addEventListener('mousemove', this._boundPreviewResize);
        window.addEventListener('mouseup', this._boundPreviewResizeEnd);
    }

    handlePreviewResize(event) {
        if (!this._resizingPreview) {
            return;
        }
        const workspace = this.template.querySelector('.builder-workspace');
        if (!workspace) {
            return;
        }
        const rect = workspace.getBoundingClientRect();
        this.previewWidth = this.clampPreviewWidth(rect.right - event.clientX);
    }

    stopPreviewResize() {
        if (!this._boundPreviewResize || !this._boundPreviewResizeEnd) {
            return;
        }
        this._resizingPreview = false;
        window.removeEventListener('mousemove', this._boundPreviewResize);
        window.removeEventListener('mouseup', this._boundPreviewResizeEnd);
    }

    resetPreviewWidth() {
        this.previewWidth = 560;
    }

    clampPreviewWidth(width) {
        return Math.max(360, Math.min(900, Math.round(width || 560)));
    }

    invalidateDefinitionJson() {
        this._definitionJsonCache = null;
    }

    schedulePreviewMount() {
        const mount = () => {
            this.previewMounted = true;
            this._previewIdleHandle = null;
            this._previewMountTimer = null;
        };
        if (window.requestIdleCallback) {
            this._previewIdleHandle = window.requestIdleCallback(mount, { timeout: 1500 });
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._previewMountTimer = setTimeout(mount, 700);
    }

    clearBuilder() {
        this._clearedReportId = this.savedReportId;
        this.resetInProgress = true;
        this.resetState();
        this.clearReportIdFromUrl();
        // Let currently-mounted child components disconnect before rendering
        // the first step again, so their internal selected values also reset.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.currentStep = 'data';
            this.resetInProgress = false;
        }, 0);
        this.dispatchEvent(new ShowToastEvent({
            title: 'Report builder cleared',
            message: 'Start a fresh report from the Data step.',
            variant: 'success'
        }));
    }

    resetState() {
        this.datasetDefinition = undefined;
        this.currentStep = 'data';
        this.dataSubstep = 'launcher';
        this.cloneSearchTerm = '';
        this.savedReportId = null;
        this.savedReportVersion = null;
        this.selectedTemplate = '';
        this.selectedCloneId = '';
        this.importNeedsBaseObject = false;
        this.fieldMetadata = [];
        this.unsupportedImports = [];
        this._fieldMetadataObject = null;
        this._fieldMetadataRelKey = '';
        this.reportName = 'New Custom Report';
        this.folder = 'Vital Reports';
        this.category = 'Ad Hoc';
        this.description = '';
        this.templateSource = '';
        this.isPublic = false;
        this.chartType = 'bar';
        this.filtersJson = '[]';
        this.groupingsJson = '[]';
        this.aggregationsJson = '[]';
        this.formulasJson = '[]';
        this.summaryFormulasJson = '[]';
        this.bucketsJson = '[]';
        this.invalidateDefinitionJson();
    }

    handleTemplateSelect(event) {
        const value = event.detail.value;
        this.selectedTemplate = value;
        if (!value) return;
        const template = TEMPLATES.find((t) => t.value === value);
        if (!template) return;
        this.applyTemplate(template);
    }

    // ─── Step 1 launcher handlers ────────────────────────────────────────────
    handleLauncherCardClick(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (key === 'blank') {
            // Skip the launcher and show the legacy free-form config so the user can
            // pick their own object/dataset. No need to advance steps yet — they'll
            // configure here and click Next on the stepper.
            this.dataSubstep = 'blank';
            return;
        }
        this.dataSubstep = key;
    }

    handleBackToLauncher() {
        this.dataSubstep = 'launcher';
    }

    handleTemplateCardClick(event) {
        const value = event.currentTarget.dataset.value;
        if (!value) return;
        this.selectedTemplate = value;
        const template = TEMPLATES.find((t) => t.value === value);
        if (!template) return;
        this.applyTemplate(template);
        // applyTemplate already honors template.startStep; if the template doesn't
        // specify one, jump to the columns step so the user keeps moving forward.
        if (!template.startStep) {
            this.currentStep = 'columns';
        }
    }

    handleCloneCardClick(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.selectedCloneId = id;
        this.loadCloneById(id);
    }

    async loadCloneById(id) {
        try {
            const record = await loadReport({ reportDefinitionId: id });
            this.applyLoadedReport(record);
            this.currentStep = 'columns';
        } catch (error) {
            this.toastError(error);
        }
    }

    handleCloneSearchChange(event) {
        this.cloneSearchTerm = event.detail?.value || event.target?.value || '';
    }

    formatCloneMetaLine(record) {
        const parts = [];
        if (record.folder) parts.push(record.folder);
        if (record.category) parts.push(record.category);
        if (record.rootObject) parts.push(record.rootObject);
        if (record.lastRunAt) parts.push(`last run ${this.formatShortDate(record.lastRunAt)}`);
        return parts.join(' • ') || 'Saved report';
    }

    formatShortDate(value) {
        if (!value) return '';
        try {
            const d = new Date(value);
            if (Number.isNaN(d.getTime())) return '';
            return d.toLocaleDateString();
        } catch {
            return '';
        }
    }

    applyTemplate(template) {
        this.reportName = template.reportName;
        this.templateSource = template.value || '';
        this.datasetDefinition = template.dataset;
        this.filtersJson = JSON.stringify(template.filters || [], null, 2);
        this.groupingsJson = JSON.stringify(template.groupings || [], null, 2);
        this.aggregationsJson = JSON.stringify(template.aggregations || [], null, 2);
        this.formulasJson = JSON.stringify(template.formulas || [], null, 2);
        this.summaryFormulasJson = '[]';
        this.bucketsJson = JSON.stringify(template.buckets || [], null, 2);
        this.unsupportedImports = [];
        this.chartType = template.chartType || 'bar';
        // Treat as a brand-new record on next save: clear both id and version
        // so the optimistic-concurrency check in saveReport doesn't carry over
        // a stale lastKnownVersion from a previously loaded report.
        this.savedReportId = null;
        this.savedReportVersion = null;
        this.selectedCloneId = '';
        this.invalidateDefinitionJson();
        this.refreshFieldMetadata();
        if (template.startStep) {
            this.currentStep = template.startStep;
        }
    }

    async handleCloneSelect(event) {
        const id = event.detail.value;
        this.selectedCloneId = id;
        if (!id) return;
        try {
            const record = await loadReport({ reportDefinitionId: id });
            this.applyLoadedReport(record);
        } catch (error) {
            this.toastError(error);
        }
    }

    handleStandardReportImport(event) {
        const detail = event.detail;
        let parsed = {};
        try {
            parsed = JSON.parse(detail.definitionJson || '{}');
        } catch {
            this.toastError({ message: 'Imported report has invalid JSON.' });
            return;
        }
        this.reportName = detail.reportName ? `${detail.reportName} (Imported)` : this.reportName;
        this.datasetDefinition = parsed.dataset || FALLBACK_DATASET;
        if ((parsed.fields || []).length && !this.datasetDefinition.fieldPaths?.length) {
            this.datasetDefinition = {
                ...this.datasetDefinition,
                fieldPaths: parsed.fields.map((f) => f.path).filter(Boolean),
                fieldLabels: this.fieldLabelsFromFields(parsed.fields)
            };
        } else if ((parsed.fields || []).length && !this.datasetDefinition.fieldLabels) {
            this.datasetDefinition = {
                ...this.datasetDefinition,
                fieldLabels: this.fieldLabelsFromFields(parsed.fields)
            };
        }
        this.filtersJson = JSON.stringify(parsed.filters || [], null, 2);
        this.groupingsJson = JSON.stringify(parsed.groupings || [], null, 2);
        this.aggregationsJson = JSON.stringify(parsed.aggregations || [], null, 2);
        this.formulasJson = JSON.stringify(parsed.formulas || [], null, 2);
        this.summaryFormulasJson = JSON.stringify(parsed.summaryFormulas || [], null, 2);
        this.bucketsJson = JSON.stringify(parsed.buckets || [], null, 2);
        this.unsupportedImports = parsed.unsupportedImports || [];
        this.chartType = parsed.chart?.type || 'bar';
        this.savedReportId = null;
        this.selectedTemplate = '';
        this.selectedCloneId = '';
        this.importNeedsBaseObject = !this.datasetDefinition?.primaryObject;
        this.invalidateDefinitionJson();
        const warningCount = (detail.warnings || []).length;
        if (this.importNeedsBaseObject) {
            this.currentStep = 'columns';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Pick a base object',
                message: `"${detail.reportName}" uses a Custom Report Type. Pick a queryable base object below before saving.`,
                variant: 'warning',
                mode: 'sticky'
            }));
            return;
        }
        // Successful import with a base object — advance straight to Columns so the
        // user lands in the configuration flow instead of staring at the picker again.
        this.currentStep = 'columns';
        const message = warningCount > 0
            ? `Imported "${detail.reportName}" with ${warningCount} note(s). Review filters/groupings.`
            : `Imported "${detail.reportName}".`;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Standard report imported',
            message,
            variant: warningCount > 0 ? 'warning' : 'success'
        }));
    }

    applyLoadedReport(record) {
        let parsed = {};
        try {
            parsed = JSON.parse(record.definitionJson || '{}');
        } catch {
            this.toastError({ message: 'Loaded report has invalid JSON.' });
            return;
        }
        this.reportName = `${record.name} (Copy)`;
        this.folder = record.folder || this.folder;
        this.category = record.category || this.category;
        this.description = record.description || '';
        this.templateSource = parsed.templateSource || '';
        this.isPublic = !!record.isPublic;
        this.datasetDefinition = parsed.dataset || FALLBACK_DATASET;
        if ((parsed.fields || []).length && !this.datasetDefinition.fieldPaths?.length) {
            this.datasetDefinition = {
                ...this.datasetDefinition,
                fieldPaths: parsed.fields.map((f) => f.path).filter(Boolean),
                fieldLabels: this.fieldLabelsFromFields(parsed.fields)
            };
        } else if ((parsed.fields || []).length && !this.datasetDefinition.fieldLabels) {
            this.datasetDefinition = {
                ...this.datasetDefinition,
                fieldLabels: this.fieldLabelsFromFields(parsed.fields)
            };
        }
        this.filtersJson = JSON.stringify(parsed.filters || [], null, 2);
        this.groupingsJson = JSON.stringify(parsed.groupings || [], null, 2);
        this.aggregationsJson = JSON.stringify(parsed.aggregations || [], null, 2);
        this.formulasJson = JSON.stringify(parsed.formulas || [], null, 2);
        this.summaryFormulasJson = JSON.stringify(parsed.summaryFormulas || [], null, 2);
        this.bucketsJson = JSON.stringify(parsed.buckets || [], null, 2);
        this.unsupportedImports = parsed.unsupportedImports || [];
        this.chartType = parsed.chart?.type || 'bar';
        // Clone path: treat as new record. Caller (S1.3) overrides for direct-load.
        this.savedReportId = null;
        this.savedReportVersion = null;
        this.selectedTemplate = '';
        this.invalidateDefinitionJson();
    }

    // Re-entry guard for the Save flow.
    // Without this, a fast double-click (or a bubbled-then-composed CustomEvent
    // from c-cr-save-button) fires `save()` twice. Both calls capture
    // `savedReportId = null`, so Apex inserts two Report_Definition__c rows.
    // The unique-on-Developer_Name__c constraint doesn't catch the duplicate
    // because `normalizeDeveloperName` appends a random salt to each call.
    // Mirrors crDashboardBuilder._saveInFlight.
    @track _saveInFlight = false;

    async save() {
        if (this._saveInFlight) return;
        this._saveInFlight = true;
        try {
            const datasetKey = (this.datasetDefinition && this.datasetDefinition.datasetKey) || FALLBACK_DATASET.datasetKey;
            const id = await saveReport({
                reportDefinitionId: this.savedReportId,
                name: this.reportName,
                datasetKey,
                definitionJson: this.definitionJson,
                folder: this.folder,
                category: this.category,
                isPublic: this.isPublic,
                lastKnownVersion: this.savedReportVersion,
                description: this.description
            });
            this.savedReportId = id;
            this.savedReportVersion = (this.savedReportVersion || 0) + 1;
            this.persistReportIdInUrl(id);
            if (this.wiredReportsResult) {
                await refreshApex(this.wiredReportsResult);
            }
            this.dispatchEvent(new ShowToastEvent({ title: 'Report saved', message: id, variant: 'success' }));
            // Morph the Save Report button into a green check briefly so the
            // user gets an inline success cue alongside the toast.
            this.template.querySelector('c-cr-save-button')?.triggerSuccess();
        } catch (error) {
            const rawMessage = error?.body?.message || error?.message || '';
            // [CR_CONFLICT] is the stable marker emitted by CR_ReportDefinitionService
            // when the optimistic-concurrency check fails. Match on prefix rather than
            // free-text so the conflict UI doesn't break if Apex copy is reworded.
            if (rawMessage.startsWith('[CR_CONFLICT]')) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Conflict — reload required',
                    message: rawMessage.replace(/^\[CR_CONFLICT\]\s*/, ''),
                    variant: 'error',
                    mode: 'sticky'
                }));
            } else {
                this.toastError(error);
            }
        } finally {
            this._saveInFlight = false;
        }
    }

    persistReportIdInUrl(reportId) {
        try {
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Report_Builder' },
                state: { c__reportId: reportId }
            }, true);
        } catch {
            // Navigation isn't available in every host (e.g. some app pages); ignore.
        }
    }

    clearReportIdFromUrl() {
        try {
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Report_Builder' }
            }, true);
        } catch {
            // Navigation isn't available in every host (e.g. some app pages); ignore.
        }
    }

    safeJson(value, fallback) {
        try {
            return JSON.parse(value || JSON.stringify(fallback));
        } catch (error) {
            return fallback;
        }
    }

    fieldLabelsFromFields(fields) {
        return (fields || []).reduce((labels, field) => {
            if (field?.path) {
                labels[field.path] = field.label || field.path;
            }
            return labels;
        }, {});
    }

    toTitle(value) {
        return String(value || '')
            .replace(/([A-Z])/g, ' $1')
            .replace(/^./, (char) => char.toUpperCase())
            .trim();
    }

    toastError(error) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Reporting error',
                message: error?.body?.message || error.message,
                variant: 'error'
            })
        );
    }
}