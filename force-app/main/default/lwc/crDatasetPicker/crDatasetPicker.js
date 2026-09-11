import { LightningElement, api, track, wire } from 'lwc';
import listDatasets from '@salesforce/apex/CR_ReportDefinitionService.listDatasets';
import getDatasetPeek from '@salesforce/apex/CR_DatasetCatalogService.getDatasetPeek';

const MODE_OPTIONS = [
    { label: 'Live', value: 'live' },
    { label: 'Cached', value: 'cached' },
    { label: 'Hybrid', value: 'hybrid' }
];

export default class CrDatasetPicker extends LightningElement {
    @track sourceType = 'curated';
    @track selectedDatasetKey;
    @track mode = 'hybrid';
    @track datasets = [];
    @track loadError;
    // Phase 1 v10: per-dataset peek panel with row count + last refresh.
    @track _peek = null;
    @track _peekLoading = false;
    @track _peekError = null;

    // When set ('curated' | 'adhoc'), hides the source-type radio and forces the
    // picker into that mode. Used by the Step 1 launcher: the "Curated Dataset"
    // card locks to curated, the "Create New Custom Report" card locks to adhoc.
    _lockedSourceType;
    @api
    get lockedSourceType() {
        return this._lockedSourceType;
    }
    set lockedSourceType(value) {
        this._lockedSourceType = value || null;
        if (this._lockedSourceType === 'adhoc' || this._lockedSourceType === 'curated') {
            this.sourceType = this._lockedSourceType;
        }
    }

    get showSourceTypeRadio() {
        return !this._lockedSourceType;
    }

    sourceOptions = [
        { label: 'Curated', value: 'curated' },
        { label: 'Ad hoc', value: 'adhoc' }
    ];
    modeOptions = MODE_OPTIONS;

    @wire(listDatasets)
    wiredDatasets({ data, error }) {
        if (data) {
            this.datasets = data;
            this.loadError = null;
        } else if (error) {
            this.loadError = error?.body?.message || 'Could not load curated datasets.';
        }
    }

    get isCurated() { return this.sourceType === 'curated'; }
    get isAdHoc() { return this.sourceType === 'adhoc'; }

    get datasetOptions() {
        return (this.datasets || []).map((d) => ({
            label: `${d.label} (${d.sobjectApiName})`,
            value: d.datasetKey
        }));
    }

    get selectedDataset() {
        return (this.datasets || []).find((d) => d.datasetKey === this.selectedDatasetKey);
    }

    handleSourceTypeChange(event) {
        this.sourceType = event.detail.value;
        if (this.sourceType === 'curated' && this.selectedDataset) {
            this.emitCurated();
        }
    }

    handleDatasetChange(event) {
        this.selectedDatasetKey = event.detail.value;
        const dataset = this.selectedDataset;
        if (dataset) {
            this.mode = dataset.mode || 'hybrid';
            this.emitCurated();
            this.loadPeek(this.selectedDatasetKey);
        } else {
            this._peek = null;
        }
    }

    async loadPeek(datasetKey) {
        if (!datasetKey) return;
        this._peekLoading = true;
        this._peekError = null;
        try {
            this._peek = await getDatasetPeek({ datasetKey });
        } catch (error) {
            this._peek = null;
            this._peekError = error?.body?.message || 'Could not load dataset details.';
        } finally {
            this._peekLoading = false;
        }
    }

    get hasPeek() { return !!this._peek; }
    get peekRowCountDisplay() {
        const c = this._peek?.rowCount;
        if (c === null || c === undefined) return '—';
        return Number(c).toLocaleString();
    }
    get peekAccessibilityLabel() {
        if (!this._peek) return '';
        return this._peek.accessible ? 'Accessible to you' : 'No access — saved reports may still run server-side';
    }
    get peekAccessibilityClass() {
        return this._peek?.accessible
            ? 'peek-pill peek-pill_ok'
            : 'peek-pill peek-pill_warn';
    }

    handleModeChange(event) {
        this.mode = event.detail.value;
        this.emitCurated();
    }

    emitCurated() {
        const dataset = this.selectedDataset;
        if (!dataset) return;
        const definition = {
            datasetKey: dataset.datasetKey,
            mode: this.mode,
            objectApiName: dataset.sobjectApiName,
            primaryObject: dataset.sobjectApiName,
            relatedObjects: [],
            fieldPaths: []
        };
        this.dispatchEvent(
            new CustomEvent('datasetchange', {
                detail: { json: JSON.stringify(definition), definition }
            })
        );
    }
}