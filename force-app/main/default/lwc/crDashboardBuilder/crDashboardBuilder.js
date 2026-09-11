import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import LightningPrompt from 'lightning/prompt';
import listReports from '@salesforce/apex/CR_ReportDefinitionService.listReports';
import listDashboards from '@salesforce/apex/CR_DashboardService.listDashboards';
import loadDashboard from '@salesforce/apex/CR_DashboardService.loadDashboard';
import deleteDashboardApex from '@salesforce/apex/CR_DashboardService.deleteDashboard';
import cloneDashboardApex from '@salesforce/apex/CR_DashboardService.cloneDashboard';
import saveDashboardV3 from '@salesforce/apex/CR_DashboardService.saveDashboardV3';
import { applyBrandTheme } from 'c/crBrandTheme';

const UNDO_STACK_LIMIT = 25;

// Phase B: 15 named palettes. Mirrors the swatch shortlist in
// crDashboardPropertiesModal but exposes the full per-chart series so
// crChart and crDashboardViewer can apply them at render time.
const PALETTE_COLORS = {
    Aurora:              ['#4F46E5','#7C3AED','#DB2777','#F59E0B','#10B981','#06B6D4','#3B82F6','#EC4899','#84CC16'],
    Branding:            ['#E8631C','#6BA9B8','#7A4FA3','#3E8E5A','#2C6EA8','#C0392B','#BE7A0A','#B5507A','#2B3A47'],
    Nightfall:           ['#1A1F71','#2E3192','#4B0082','#0F3057','#00587A','#008891','#5B5EA6','#9B59B6','#3498DB'],
    Wildflowers:         ['#FF6F91','#FF9671','#FFC75F','#F9F871','#D65DB1','#845EC2','#0089BA','#008F7A','#B0A8B9'],
    Sunrise:             ['#F94144','#F3722C','#F8961E','#F9C74F','#90BE6D','#43AA8B','#577590','#277DA1','#F94144'],
    Bluegrass:           ['#1B4332','#2D6A4F','#40916C','#52B788','#74C69D','#95D5B2','#B7E4C7','#D8F3DC','#081C15'],
    Ocean:               ['#03045E','#023E8A','#0077B6','#0096C7','#00B4D8','#48CAE4','#90E0EF','#ADE8F4','#CAF0F8'],
    Heat:                ['#370617','#6A040F','#9D0208','#D00000','#DC2F02','#E85D04','#F48C06','#FAA307','#FFBA08'],
    Duck:                ['#264653','#287271','#2A9D8F','#8AB17D','#E9C46A','#F4A261','#E76F51','#264653','#2A9D8F'],
    Pond:                ['#386641','#588157','#6A994E','#A7C957','#F2E8CF','#BC4749','#386641','#A7C957','#588157'],
    Watermelon:          ['#FF595E','#FF7C7C','#FFCA3A','#8AC926','#1982C4','#6A4C93','#FF595E','#1982C4','#8AC926'],
    Fire:                ['#FFB703','#FB8500','#FF6B35','#E63946','#9D0208','#6A040F','#370617','#FFB703','#FB8500'],
    Water:               ['#A8DADC','#457B9D','#1D3557','#E63946','#F1FAEE','#A8DADC','#457B9D','#1D3557','#F1FAEE'],
    Lake:                ['#03045E','#023E8A','#0077B6','#0096C7','#00B4D8','#48CAE4','#90E0EF','#ADE8F4','#CAF0F8'],
    Mineral_Accessible:  ['#0072B2','#E69F00','#56B4E9','#009E73','#F0E442','#D55E00','#CC79A7','#000000','#999999']
};

let _idCounter = 0;
const newComponentKey = () => `cmp_${Date.now()}_${++_idCounter}`;

// 12 is the default grid; 9 is the alternate (matches the picklist on
// Dashboard__c.Grid_Size__c). All grid math is parameterised on gridCols.
const DEFAULT_GRID_COLS = 12;
const GRID_ROW_PX = 56; // Matches the canvas row height in CSS (3.5rem at 16px base).
const MIN_TILE_W = 2;
const MIN_TILE_H = 2;

// Visualization-type → SLDS icon + display label mapping. Keeps the tile body
// readable as a preview card instead of dominating it with a full combobox.
const VIZ_ICON = {
    auto: 'utility:dashboard_ext',
    table: 'utility:table',
    bar: 'utility:chart',
    line: 'utility:trend',
    donut: 'utility:pie_chart',
    pie: 'utility:pie_chart',
    metric: 'utility:number_input',
    gauge: 'utility:speedometer'
};
const VIZ_LABEL = {
    auto: 'Auto visual',
    table: 'Table',
    bar: 'Bar chart',
    line: 'Line chart',
    donut: 'Donut chart',
    pie: 'Pie chart',
    metric: 'Metric',
    gauge: 'Gauge'
};

export default class CrDashboardBuilder extends NavigationMixin(LightningElement) {
    @track reportOptions = [];
    @track reportRootObjectsById = {};
    @track components = [];
    @track savedDashboardId = null;
    @track savedDashboardVersion = null;
    // Dirty when user has changed components/filters/name since last save. Drives the
    // "Save Dashboard" button styling so the unsaved-changes state isn't subtle.
    @track isDirty = false;
    // Toggles the inline-edit mode on the dashboard title in the sticky header.
    @track isEditingName = false;
    // Phase I: the New Dashboard Wizard mounts above the canvas when the user
    // opens the builder without a c__dashboardId in the URL. Existing-edit
    // sessions skip the wizard entirely. wizardChecked is set after the page
    // ref resolves so the wizard doesn't briefly flash for existing edits.
    @track wizardOpen = false;
    @track _wizardChecked = false;
    // Modal toggles. Phase A introduced the toolbar-driven dialogs; Phase C
    // splits the old single addComponentModal into a 3-step flow (type picker
    // → report picker → widget config) plus an Edit Widget reuse of step 3.
    @track filtersModalOpen = false;
    @track settingsModalOpen = false;
    @track typeModalOpen = false;
    @track reportPickerModalOpen = false;
    @track configModalOpen = false;
    // Working state for the add/edit widget flow.
    @track _pendingReport = null;        // Report picked at step 2, awaiting config
    @track _editingTileKey = null;       // Set when the config modal is opened to edit an existing tile
    @track _editingViz = null;           // Viz JSON snapshot loaded into the config modal in edit mode
    @track _pendingWidgetKind = 'chart'; // chart | text | image — picked at step 1, drives the config form
    // Undo/redo stacks: each entry is a JSON snapshot of mutable state. Capped
    // at UNDO_STACK_LIMIT to keep memory bounded even on long sessions.
    @track _undoStack = [];
    @track _redoStack = [];
    // Re-entry guard for Apex-bound actions. When a save/clone/delete is in
    // flight the toolbar button is disabled AND the handlers early-return, so
    // a synthetic+native click double-fire (or user double-click) can never
    // submit twice. Without this guard, a fresh-dashboard save creates two
    // Dashboard__c records because both fires see savedDashboardId == null.
    @track _saveInFlight = false;

    dashboardName = 'New Custom Dashboard';
    folder = 'Vital Reports';
    category = 'Executive';
    filterJson = '[]';
    isPublic = false;
    @track description = '';
    // Phase B: dashboard-level properties. Defaults match the picklist
    // defaults on the Salesforce side; null/blank values from old dashboards
    // hydrate to these.
    @track theme = 'Light';
    @track palette = 'Aurora';
    @track gridSize = '12';
    @track runAsMode = 'Me';
    @track runAsUserId = null;
    @track allowViewerRunAsChoice = false;
    selectedReportId;
    selectedFilterContextReportId;
    visualizationType = 'auto';

    visualizationOptions = [
        { label: 'Auto visual', value: 'auto' },
        { label: 'Table', value: 'table' },
        { label: 'Bar', value: 'bar' },
        { label: 'Horizontal Bar', value: 'horizontal' },
        { label: 'Line', value: 'line' },
        { label: 'Area', value: 'area' },
        { label: 'Donut', value: 'donut' },
        { label: 'Pie', value: 'pie' },
        { label: 'Metric', value: 'metric' },
        { label: 'Gauge', value: 'gauge' }
    ];

    wiredDashboardsResult;

    get hasComponents() {
        return this.components.length > 0;
    }

    // Phase B: column count derived from gridSize (12 or 9). Falls back to
    // the default if the picklist value is somehow malformed.
    get gridCols() {
        const n = parseInt(this.gridSize, 10);
        return Number.isFinite(n) && n > 0 ? n : DEFAULT_GRID_COLS;
    }

    // Theme class applied to the builder shell. Keeps the canvas dark + tiles
    // styled accordingly when Theme=Dark.
    get builderShellClass() {
        return this.theme === 'Dark' ? 'builder-shell builder-shell_dark' : 'builder-shell';
    }

    get saveButtonLabel() {
        return this.isDirty ? 'Save Dashboard *' : 'Save Dashboard';
    }

    get saveButtonVariant() {
        return this.isDirty ? 'destructive' : 'brand';
    }

    get unsavedBannerVisible() {
        return this.isDirty && this.hasComponents;
    }

    connectedCallback() {
        applyBrandTheme(this);
        // Defer the report list fetch so the page chrome paints first.
        // The combobox is only visible on the Data step; users almost never
        // see it within the LCP window anyway.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.loadReports(), 0);
    }

    @wire(listDashboards, { searchTerm: '' })
    wiredDashboards(result) {
        this.wiredDashboardsResult = result;
    }

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (!pageRef) return;
        const incomingId = pageRef.state?.c__dashboardId;
        if (incomingId && incomingId !== this.savedDashboardId) {
            // Existing dashboard route — hydrate and skip the wizard.
            this.hydrateFromDashboardId(incomingId);
            this.wizardOpen = false;
        } else if (!this._wizardChecked && !incomingId && !this.savedDashboardId) {
            // New-builder route — show the New Dashboard wizard exactly once
            // per session before revealing the canvas.
            this.wizardOpen = true;
        }
        this._wizardChecked = true;
    }

    async hydrateFromDashboardId(dashboardId) {
        try {
            const payload = await loadDashboard({ dashboardId, includeResults: false });
            const d = payload.dashboard;
            this.dashboardName = d.Name;
            this.folder = d.Folder__c || this.folder;
            this.category = d.Category__c || this.category;
            this.isPublic = !!d.Is_Public__c;
            this.filterJson = d.Filter_JSON__c || '[]';
            this.savedDashboardId = d.Id;
            this.savedDashboardVersion = d.Version__c;
            // Phase B: hydrate dashboard-level properties. Null-coalesce to
            // defaults so old (pre-Phase-B) dashboards render without errors.
            this.theme = d.Theme__c || 'Light';
            this.palette = d.Palette__c || 'Aurora';
            this.gridSize = d.Grid_Size__c || '12';
            this.runAsMode = d.Run_As_Mode__c || 'Me';
            this.runAsUserId = d.Run_As_User__c || null;
            this.allowViewerRunAsChoice = !!d.Allow_Viewer_Run_As_Choice__c;
            this.description = d.Description__c || '';
            this.components = (payload.components || []).map((c) => ({
                key: newComponentKey(),
                id: c.Id,
                name: c.Name,
                reportDefinitionId: c.Report_Definition__c,
                rootObject: this.reportRootObjectsById[c.Report_Definition__c],
                visualization: this.parseVisualization(c.Visualization_JSON__c),
                x: c.Position_X__c,
                y: c.Position_Y__c,
                w: c.Width__c,
                h: c.Height__c
            }));
            const layout = this.parseLayout(d.Layout_JSON__c);
            this.selectedFilterContextReportId = layout.filterContextReportId;
            this.ensureFilterContext();
        } catch (error) {
            this.toastError(error);
        }
    }

    parseVisualization(json) {
        try {
            const visualization = JSON.parse(json || '{}') || { type: 'auto' };
            return this.normalizeVisualization(visualization);
        } catch {
            return { type: 'auto' };
        }
    }

    normalizeVisualization(visualization) {
        if (!visualization.type) {
            return { type: 'auto' };
        }
        if (visualization.type === 'table' && visualization.locked !== true) {
            return { type: 'auto' };
        }
        return visualization;
    }

    buildVisualization(type) {
        return type === 'table' ? { type: 'table', locked: true } : { type };
    }

    parseLayout(json) {
        try {
            return JSON.parse(json || '{}') || {};
        } catch {
            return {};
        }
    }

    async loadReports() {
        const reports = await listReports({ searchTerm: '' });
        this.reportOptions = reports.map((report) => ({ label: report.name, value: report.id }));
        const rootMap = {};
        for (const r of reports) {
            if (r.rootObject) rootMap[r.id] = r.rootObject;
        }
        this.reportRootObjectsById = rootMap;
        this.decorateComponentsWithRoots();
        this.ensureFilterContext();
    }

    get filterPrimaryObject() {
        if (this.selectedFilterContextReportId && this.reportRootObjectsById[this.selectedFilterContextReportId]) {
            return this.reportRootObjectsById[this.selectedFilterContextReportId];
        }
        for (const c of this.components) {
            const root = this.reportRootObjectsById[c.reportDefinitionId];
            if (root) return root;
        }
        return null;
    }

    get hasFilterableContext() {
        return !!this.filterPrimaryObject;
    }

    get filterContextOptions() {
        const seen = new Set();
        return this.components
            .filter((component) => component.reportDefinitionId && this.reportRootObjectsById[component.reportDefinitionId])
            .filter((component) => {
                if (seen.has(component.reportDefinitionId)) return false;
                seen.add(component.reportDefinitionId);
                return true;
            })
            .map((component) => ({
                label: `${component.name} (${this.reportRootObjectsById[component.reportDefinitionId]})`,
                value: component.reportDefinitionId
            }));
    }

    get hasMultipleFilterContexts() {
        return this.filterContextOptions.length > 1;
    }

    handleNameChange(event) {
        this.dashboardName = event.detail.value;
        this.isDirty = true;
    }

    handleFilterChange(event) {
        this.snapshotForUndo();
        this.filterJson = event.detail.value;
        this.isDirty = true;
    }

    handleFilterContextChange(event) {
        this.selectedFilterContextReportId = event.detail.value;
    }

    // ---- New Dashboard Stepper (Phase I) ----
    handleWizardCreate(event) {
        const detail = event.detail || {};
        this.dashboardName = detail.name || this.dashboardName;
        this.folder = detail.folder || this.folder;
        if (detail.description != null) this.description = detail.description;
        if (detail.theme) this.theme = detail.theme;
        if (detail.palette) this.palette = detail.palette;
        if (detail.gridSize) this.gridSize = detail.gridSize;
        // Mark dirty so the unsaved-changes pill shows immediately — the
        // user just entered metadata that isn't on the server yet.
        this.isDirty = true;
        this.wizardOpen = false;
    }
    handleWizardCancel() {
        this.wizardOpen = false;
        // Navigate back to the Dashboard Viewer. The earlier value
        // 'Dashboards' was an invalid tab API name (no such tab exists),
        // which produced a "Page doesn't exist" toast on cancel. Use the
        // canonical user-facing Dashboard Viewer tab instead. Best-effort:
        // some hosts (App Builder previews) block navigation; the wizard
        // close + clean builder is still a reasonable fallback.
        try {
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Dashboard_Viewer' }
            });
        } catch {
            // No-op when navigation isn't allowed.
        }
    }

    // ---- Add Widget 3-step flow (Phase C) ----
    openAddComponentModal() {
        this._pendingReport = null;
        this._editingTileKey = null;
        this._editingViz = null;
        this.typeModalOpen = true;
    }
    handleTypeModalCancel() {
        this.typeModalOpen = false;
    }
    handleTypeModalSelect(event) {
        const type = event.detail?.type;
        this.typeModalOpen = false;
        if (type === 'chart') {
            this._pendingWidgetKind = 'chart';
            this.reportPickerModalOpen = true;
        } else if (type === 'text') {
            this._pendingWidgetKind = 'text';
            this._pendingReport = null;
            this._editingViz = { type: 'richtext' };
            this.configModalOpen = true;
        } else if (type === 'image') {
            this._pendingWidgetKind = 'image';
            this._pendingReport = null;
            this._editingViz = { type: 'image' };
            this.configModalOpen = true;
        } else if (type === 'clock') {
            // Clock is a first-class shortcut to the allowlisted clock LWC: it
            // pre-selects lwcName so the user lands on a ready-to-save clock tile
            // instead of having to know the LWC registry. The config dialog still
            // lets them tweak/switch like any other LWC widget.
            this._pendingWidgetKind = 'lwc';
            this._pendingReport = null;
            this._editingViz = { type: 'lwc', lwcName: 'crDashboardClockWidget' };
            this.configModalOpen = true;
        } else if (type === 'lwc') {
            this._pendingWidgetKind = 'lwc';
            this._pendingReport = null;
            // Default to the first registry entry; the config dialog lets the
            // user switch and edit the props JSON. type:'lwc' triggers the
            // LWC form body when opened.
            this._editingViz = { type: 'lwc' };
            this.configModalOpen = true;
        } else {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Unknown widget type',
                message: `"${type}" is not a recognized widget kind.`,
                variant: 'warning'
            }));
        }
    }
    handleReportPickerCancel() {
        this.reportPickerModalOpen = false;
        this._pendingReport = null;
    }
    handleReportPickerSelect(event) {
        const report = event.detail?.report;
        if (!report) return;
        this._pendingReport = report;
        this.reportPickerModalOpen = false;
        // Pre-seed initialViz with chart-type 'auto' so crChart's auto-detect
        // picks a sensible default until the user changes it.
        this._editingViz = { type: 'auto' };
        this.configModalOpen = true;
    }
    handleConfigCancel() {
        this.configModalOpen = false;
        this._pendingReport = null;
        this._editingTileKey = null;
        this._editingViz = null;
    }
    handleConfigApply(event) {
        const detail = event.detail || {};
        this.configModalOpen = false;
        this.snapshotForUndo();
        if (this._editingTileKey) {
            this.components = this.components.map((c) =>
                c.key === this._editingTileKey ? { ...c, visualization: detail.viz, name: detail.viz.title || c.name } : c
            );
        } else {
            const reportId = detail.reportId || this._pendingReport?.id;
            const reportName = detail.viz?.title || this._pendingReport?.name || 'Component';
            const rootObject = this.reportRootObjectsById[reportId];
            // Place the new tile in the first free grid slot instead of the old
            // y = length*3 stacking, which overlapped tiles after a resize.
            const slot = this.findFreeSlot(6, 3);
            this.components = [
                ...this.components,
                {
                    key: newComponentKey(),
                    name: reportName,
                    reportDefinitionId: reportId,
                    rootObject,
                    visualization: detail.viz,
                    x: slot.x,
                    y: slot.y,
                    w: 6,
                    h: 3
                }
            ];
            this.ensureFilterContext();
        }
        this.isDirty = true;
        this._pendingReport = null;
        this._editingTileKey = null;
        this._editingViz = null;
    }

    get configReportId() {
        // For new-widget flow it's the picked report; for edit it's the tile's saved report.
        if (this._editingTileKey) {
            const tile = this.components.find((c) => c.key === this._editingTileKey);
            return tile?.reportDefinitionId || null;
        }
        return this._pendingReport?.id || null;
    }
    get configReportName() {
        if (this._editingTileKey) {
            const tile = this.components.find((c) => c.key === this._editingTileKey);
            return tile?.name || '';
        }
        return this._pendingReport?.name || '';
    }
    get configIsEditMode() {
        return !!this._editingTileKey;
    }
    // Template binding can't reference `_`-prefixed fields. Expose via getter.
    get configInitialViz() {
        return this._editingViz;
    }
    get configWidgetKind() {
        // In edit mode, derive kind from the existing viz so editing a
        // text/image/lwc tile loads the right form even if _pendingWidgetKind
        // was reset.
        if (this._editingTileKey && this._editingViz) {
            if (this._editingViz.type === 'richtext') return 'text';
            if (this._editingViz.type === 'image') return 'image';
            if (this._editingViz.type === 'lwc') return 'lwc';
            return 'chart';
        }
        return this._pendingWidgetKind || 'chart';
    }

    // ---- Modal toggles (Phase A retained) ----
    openFiltersModal() {
        if (!this.hasComponents) {
            // Filters require at least one component to derive the field source.
            this.dispatchEvent(new ShowToastEvent({
                title: 'Add a component first',
                message: 'Filters need at least one report-backed tile on the canvas.',
                variant: 'info'
            }));
            return;
        }
        this.filtersModalOpen = true;
    }
    closeFiltersModal() {
        this.filtersModalOpen = false;
    }
    openSettingsModal() {
        this.settingsModalOpen = true;
    }
    closeSettingsModal() {
        this.settingsModalOpen = false;
    }

    // Phase G: toggle the help drawer when the toolbar ? button is clicked.
    // First click opens, next click closes. The panel still handles its own
    // first-time auto-open via localStorage; this method drives subsequent
    // opens and closes.
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    handlePropertiesApply(event) {
        const detail = event.detail || {};
        // Capture previous state so the user can undo a properties change.
        this.snapshotForUndo();
        this.dashboardName = detail.name;
        this.folder = detail.folder;
        this.category = detail.category;
        this.isPublic = !!detail.isPublic;
        this.theme = detail.theme || 'Light';
        this.palette = detail.palette || 'Aurora';
        this.gridSize = detail.gridSize || '12';
        this.runAsMode = detail.runAsMode || 'Me';
        this.runAsUserId = detail.runAsUserId || null;
        this.allowViewerRunAsChoice = !!detail.allowViewerChoice;
        this.isDirty = true;
        // Grid-size change: clamp tile widths/positions into the new column
        // count so we don't end up with tiles overflowing the canvas.
        this.normalizeTilesForGrid();
        this.settingsModalOpen = false;
    }

    handlePropertiesValidationError(event) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Properties incomplete',
            message: event.detail?.message || 'Fix the highlighted fields before saving.',
            variant: 'warning'
        }));
    }

    // Phase B: re-clamp every tile to fit inside the current grid column count.
    // Called after a 12->9 (or vice-versa) switch so we don't leave tiles
    // hanging off the right edge.
    normalizeTilesForGrid() {
        const cols = parseInt(this.gridSize, 10) || 12;
        if (!Array.isArray(this.components) || this.components.length === 0) return;
        this.components = this.components.map((c) => {
            let { x = 0, y = 0, w = 6, h = 3 } = c;
            // Clamp width to grid; ensure it's at least the configured minimum.
            const minW = 2;
            w = Math.max(minW, Math.min(cols, w));
            // Push tile left if its right edge would overflow.
            if (x + w > cols) {
                x = Math.max(0, cols - w);
            }
            return { ...c, x, y, w, h };
        });
    }

    // Find the first free grid slot for a new tile of size w x h. Scans
    // top-to-bottom, left-to-right against the current column count and tests
    // each candidate rect for overlap with existing tiles. Replaces the old
    // y = components.length * 3 heuristic, which overlapped tiles after a
    // resize. Width is clamped to the grid so the scan always terminates.
    findFreeSlot(w, h) {
        const cols = this.gridCols;
        const tileW = Math.max(MIN_TILE_W, Math.min(cols, Number.isFinite(w) ? w : 6));
        const tileH = Math.max(MIN_TILE_H, Number.isFinite(h) ? h : 3);
        const rects = this.components.map((c) => ({
            x: Number.isFinite(c.x) ? c.x : 0,
            y: Number.isFinite(c.y) ? c.y : 0,
            w: Number.isFinite(c.w) && c.w >= MIN_TILE_W ? c.w : 6,
            h: Number.isFinite(c.h) && c.h >= MIN_TILE_H ? c.h : 3
        }));
        const overlaps = (x, y) =>
            rects.some((r) => x < r.x + r.w && x + tileW > r.x && y < r.y + r.h && y + tileH > r.y);
        // Bound the row scan: worst case every tile is stacked, so the deepest
        // a new tile can land is below the current maximum bottom edge.
        const maxBottom = rects.reduce((acc, r) => Math.max(acc, r.y + r.h), 0);
        for (let y = 0; y <= maxBottom; y++) {
            for (let x = 0; x + tileW <= cols; x++) {
                if (!overlaps(x, y)) {
                    return { x, y };
                }
            }
        }
        // Fallback: drop it on a fresh row below everything.
        return { x: 0, y: maxBottom };
    }

    get filterButtonDisabled() {
        return !this.hasComponents;
    }

    get filterButtonTooltip() {
        return this.filterButtonDisabled
            ? 'Add at least one report-backed component before configuring dashboard filters.'
            : 'Edit dashboard filters';
    }

    get saveAsEnabled() {
        // Save As needs an existing saved record to clone from, and must
        // not be available while another Apex call is in flight.
        return !!this.savedDashboardId && !this._saveInFlight;
    }
    get deleteEnabled() {
        return !!this.savedDashboardId && !this._saveInFlight;
    }
    get saveButtonDisabled() {
        return this._saveInFlight;
    }

    // Phase C: opens the rich config modal preloaded with the tile's saved viz.
    handleEditTile(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        const tile = this.components.find((c) => c.key === key);
        if (!tile) return;
        this._editingTileKey = key;
        this._pendingReport = null;
        this._editingViz = tile.visualization || { type: 'auto' };
        this.configModalOpen = true;
    }

    // ---- Inline title rename ----
    startNameEdit() {
        this.isEditingName = true;
        // Focus the input after LWC renders the editable variant.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const input = this.template.querySelector('.title-input');
            if (input && typeof input.focus === 'function') input.focus();
        }, 0);
    }

    endNameEdit() {
        this.isEditingName = false;
    }

    handleNameKey(event) {
        // Enter or Escape commits and exits edit mode (value already saved via onchange).
        if (event.key === 'Enter' || event.key === 'Escape') {
            this.isEditingName = false;
        }
    }

    // Clone a tile's full config (visualization, size, report binding) into a
    // new component placed in the first free grid slot. Reuses the same
    // component shape as the add path, snapshots for undo, and marks dirty.
    handleDuplicateComponent(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        const source = this.components.find((component) => component.key === key);
        if (!source) return;
        this.snapshotForUndo();
        const w = Number.isFinite(source.w) && source.w >= MIN_TILE_W ? source.w : 6;
        const h = Number.isFinite(source.h) && source.h >= MIN_TILE_H ? source.h : 3;
        const slot = this.findFreeSlot(w, h);
        this.components = [
            ...this.components,
            {
                key: newComponentKey(),
                name: source.name,
                reportDefinitionId: source.reportDefinitionId,
                rootObject: source.rootObject,
                // Deep-copy the viz JSON so edits to the clone don't mutate the
                // original tile's config (and vice versa).
                visualization: JSON.parse(JSON.stringify(source.visualization || { type: 'auto' })),
                x: slot.x,
                y: slot.y,
                w,
                h
            }
        ];
        this.ensureFilterContext();
        this.isDirty = true;
    }

    handleRemoveComponent(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        this.snapshotForUndo();
        this.components = this.components.filter((component) => component.key !== key);
        this.ensureFilterContext();
        this.isDirty = true;
    }

    // ---- WYSIWYG canvas: drag-to-move + corner-resize on a 12-column grid ----

    get tilesForCanvas() {
        const colPct = 100 / this.gridCols;
        return this.components.map((component) => {
            const x = Number.isFinite(component.x) ? component.x : 0;
            const y = Number.isFinite(component.y) ? component.y : 0;
            const w = Number.isFinite(component.w) && component.w >= MIN_TILE_W ? component.w : 6;
            const h = Number.isFinite(component.h) && component.h >= MIN_TILE_H ? component.h : 3;
            const isDragging = this._dragKey === component.key;
            const viz = component.visualization || {};
            const vizType = viz.type || 'auto';
            return {
                ...component,
                tileStyle: `left:${x * colPct}%;top:${y * GRID_ROW_PX}px;width:${w * colPct}%;height:${h * GRID_ROW_PX}px;`,
                tileClass: isDragging ? 'tile is-dragging' : 'tile',
                // Phase D: tile-body switch. The viz.type === 'richtext' / 'image'
                // tiles render the actual content inline; chart tiles still
                // show the type-icon preview placeholder in the builder.
                isTextTile: vizType === 'richtext',
                isImageTile: vizType === 'image',
                // Phase E2: LWC tile + per-component flags for the
                // hardcoded if-true switch in the template (see registry
                // in crDashboardWidgetConfig).
                isLwcTile: vizType === 'lwc',
                isLwcKpi: vizType === 'lwc' && viz.lwcName === 'crDashboardKpiTileWidget',
                isLwcClock: vizType === 'lwc' && viz.lwcName === 'crDashboardClockWidget',
                lwcWidgetProps: viz.widgetProps || {},
                isChartTile: vizType !== 'richtext' && vizType !== 'image' && vizType !== 'lwc',
                richTextHtml: viz.html || '',
                imageUrl: viz.url || '',
                imageAlt: viz.altText || '',
                imageStyle: `object-fit:${viz.fit || 'contain'};`,
                vizIcon: VIZ_ICON[vizType] || VIZ_ICON.auto,
                vizLabel: VIZ_LABEL[vizType] || VIZ_LABEL.auto
            };
        });
    }

    get canvasStyle() {
        const maxRow = this.components.reduce((acc, c) => {
            const y = Number.isFinite(c.y) ? c.y : 0;
            const h = Number.isFinite(c.h) ? c.h : 3;
            return Math.max(acc, y + h);
        }, 6);
        // Add a row of slack so users can drop a tile below the current bottom.
        return `min-height:${(maxRow + 1) * GRID_ROW_PX}px;`;
    }

    // Phase B: dynamic gridline background reflects the configured grid size.
    // Combines the height-clamping rule from canvasStyle with a column-aware
    // background-size so the gridlines line up with where tiles will snap.
    get canvasGridStyle() {
        const colPct = 100 / this.gridCols;
        return `${this.canvasStyle} background-size: ${colPct}% ${GRID_ROW_PX}px;`;
    }

    handleTileMoveStart(event) {
        this._beginDragFromEvent(event, 'move');
    }

    handleTileResizeStart(event) {
        // Prevent move-handler firing on the parent header.
        event.stopPropagation();
        this._beginDragFromEvent(event, 'resize');
    }

    _beginDragFromEvent(event, kind) {
        if (event.button !== undefined && event.button !== 0) return;
        const key = event.currentTarget.dataset.key;
        const tile = this.components.find((c) => c.key === key);
        if (!tile) return;
        event.preventDefault();
        // Capture state BEFORE the drag mutates it; pushed onto the undo stack
        // at drag-end so a single drag = a single undo step.
        this._preDragSnapshot = this.snapshotState();
        const canvas = this.template.querySelector('.tile-canvas');
        const cols = this.gridCols;
        const colWidth = canvas ? canvas.clientWidth / cols : 1;
        this._dragState = {
            key,
            kind,
            startClientX: event.clientX,
            startClientY: event.clientY,
            origX: Number.isFinite(tile.x) ? tile.x : 0,
            origY: Number.isFinite(tile.y) ? tile.y : 0,
            origW: Number.isFinite(tile.w) && tile.w >= MIN_TILE_W ? tile.w : 6,
            origH: Number.isFinite(tile.h) && tile.h >= MIN_TILE_H ? tile.h : 3,
            colWidth: Math.max(colWidth, 1)
        };
        this._dragKey = key;
        if (!this._pointerMoveBound) {
            this._pointerMoveBound = (e) => this._handleDragMove(e);
            this._pointerUpBound = (e) => this._handleDragEnd(e);
        }
        document.addEventListener('pointermove', this._pointerMoveBound);
        document.addEventListener('pointerup', this._pointerUpBound);
        document.addEventListener('pointercancel', this._pointerUpBound);
    }

    _handleDragMove(event) {
        const state = this._dragState;
        if (!state) return;
        event.preventDefault();
        const dx = Math.round((event.clientX - state.startClientX) / state.colWidth);
        const dy = Math.round((event.clientY - state.startClientY) / GRID_ROW_PX);
        let { origX: x, origY: y, origW: w, origH: h } = state;
        if (state.kind === 'move') {
            x = Math.max(0, Math.min(this.gridCols - w, state.origX + dx));
            y = Math.max(0, state.origY + dy);
        } else {
            w = Math.max(MIN_TILE_W, Math.min(this.gridCols - state.origX, state.origW + dx));
            h = Math.max(MIN_TILE_H, state.origH + dy);
        }
        const updated = this.components.map((c) =>
            c.key === state.key ? { ...c, x, y, w, h } : c
        );
        this.components = updated;
    }

    _handleDragEnd() {
        if (!this._dragState) return;
        // Snapshot is taken at drag-end (not start) so undo collapses a single
        // drag into one step instead of dozens of pointermove micro-states.
        // We push the *pre-drag* state, which we cached at start.
        if (this._preDragSnapshot) {
            this._undoStack = [...this._undoStack, this._preDragSnapshot].slice(-UNDO_STACK_LIMIT);
            this._redoStack = [];
            this._preDragSnapshot = null;
        }
        this._dragState = null;
        this._dragKey = null;
        this.isDirty = true;
        document.removeEventListener('pointermove', this._pointerMoveBound);
        document.removeEventListener('pointerup', this._pointerUpBound);
        document.removeEventListener('pointercancel', this._pointerUpBound);
    }

    disconnectedCallback() {
        if (this._pointerMoveBound) {
            document.removeEventListener('pointermove', this._pointerMoveBound);
            document.removeEventListener('pointerup', this._pointerUpBound);
            document.removeEventListener('pointercancel', this._pointerUpBound);
        }
    }

    // ---- Undo / redo ----
    snapshotState() {
        return JSON.stringify({
            components: this.components,
            filterJson: this.filterJson,
            dashboardName: this.dashboardName,
            folder: this.folder,
            category: this.category,
            isPublic: this.isPublic,
            selectedFilterContextReportId: this.selectedFilterContextReportId
        });
    }

    snapshotForUndo() {
        const snapshot = this.snapshotState();
        this._undoStack = [...this._undoStack, snapshot].slice(-UNDO_STACK_LIMIT);
        this._redoStack = [];
    }

    restoreSnapshot(snapshot) {
        try {
            const state = JSON.parse(snapshot);
            this.components = state.components || [];
            this.filterJson = state.filterJson || '[]';
            this.dashboardName = state.dashboardName;
            this.folder = state.folder;
            this.category = state.category;
            this.isPublic = !!state.isPublic;
            this.selectedFilterContextReportId = state.selectedFilterContextReportId || null;
            this.isDirty = true;
        } catch {
            // Bad snapshot — ignore.
        }
    }

    handleUndo() {
        if (this._undoStack.length === 0) return;
        const current = this.snapshotState();
        const prior = this._undoStack[this._undoStack.length - 1];
        this._undoStack = this._undoStack.slice(0, -1);
        this._redoStack = [...this._redoStack, current].slice(-UNDO_STACK_LIMIT);
        this.restoreSnapshot(prior);
    }

    handleRedo() {
        if (this._redoStack.length === 0) return;
        const current = this.snapshotState();
        const next = this._redoStack[this._redoStack.length - 1];
        this._redoStack = this._redoStack.slice(0, -1);
        this._undoStack = [...this._undoStack, current].slice(-UNDO_STACK_LIMIT);
        this.restoreSnapshot(next);
    }

    get undoDisabled() {
        return this._undoStack.length === 0;
    }
    get redoDisabled() {
        return this._redoStack.length === 0;
    }

    // ---- Save As ----
    async handleSaveAs() {
        if (this._saveInFlight) return;
        if (!this.savedDashboardId) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Save first',
                message: 'Save the dashboard before using Save As.',
                variant: 'info'
            }));
            return;
        }
        const newName = await LightningPrompt.open({
            label: 'Save As',
            message: 'Enter a name for the copy.',
            defaultValue: `${this.dashboardName} Copy`,
            theme: 'shade'
        });
        if (newName === null) return; // user cancelled
        const trimmed = (newName || '').trim();
        if (!trimmed) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Name required',
                message: 'Pick a non-empty name.',
                variant: 'warning'
            }));
            return;
        }
        this._saveInFlight = true;
        try {
            const newId = await cloneDashboardApex({
                sourceDashboardId: this.savedDashboardId,
                newName: trimmed
            });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Dashboard saved as new copy',
                message: `"${trimmed}" is now open for editing. The original is unchanged.`,
                variant: 'success'
            }));
            // Navigate to the new clone so the user starts editing the copy.
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Dashboard_Builder' },
                state: { c__dashboardId: newId }
            });
            if (this.wiredDashboardsResult) {
                refreshApex(this.wiredDashboardsResult);
            }
        } catch (error) {
            this.toastError(error);
        } finally {
            this._saveInFlight = false;
        }
    }

    // ---- Delete ----
    async handleDelete() {
        if (this._saveInFlight) return;
        if (!this.savedDashboardId) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Nothing to delete',
                message: 'This dashboard has not been saved yet.',
                variant: 'info'
            }));
            return;
        }
        const proceed = await LightningConfirm.open({
            label: 'Delete dashboard',
            theme: 'error',
            message: `Permanently delete "${this.dashboardName}" and all its components? This cannot be undone.`
        });
        if (!proceed) return;
        this._saveInFlight = true;
        try {
            await deleteDashboardApex({ dashboardId: this.savedDashboardId });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Dashboard deleted',
                message: this.dashboardName,
                variant: 'success'
            }));
            // Reset local state so we don't keep stale ids around.
            this.savedDashboardId = null;
            this.savedDashboardVersion = null;
            this.components = [];
            this.filterJson = '[]';
            this.isDirty = false;
            this._undoStack = [];
            this._redoStack = [];
            if (this.wiredDashboardsResult) {
                refreshApex(this.wiredDashboardsResult);
            }
            // Navigate to the dashboard list (best-effort; tab name varies by org).
            try {
                this[NavigationMixin.Navigate]({
                    type: 'standard__navItemPage',
                    attributes: { apiName: 'Dashboards' }
                });
            } catch {
                // Some hosts don't allow navigation; the local state reset above
                // already gives a clean canvas.
            }
        } catch (error) {
            this.toastError(error);
        } finally {
            this._saveInFlight = false;
        }
    }

    // ---- Done ----
    async handleDone() {
        if (this.isDirty) {
            const proceed = await LightningConfirm.open({
                label: 'Discard unsaved changes?',
                theme: 'warning',
                message: 'You have unsaved changes. Leave anyway?'
            });
            if (!proceed) return;
        }
        // Best-effort navigate to the viewer; falls back to the dashboard list.
        try {
            if (this.savedDashboardId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__navItemPage',
                    attributes: { apiName: 'Custom_Dashboard_Viewer' },
                    state: { c__dashboardId: this.savedDashboardId }
                });
            } else {
                this[NavigationMixin.Navigate]({
                    type: 'standard__navItemPage',
                    attributes: { apiName: 'Dashboards' }
                });
            }
        } catch {
            // No-op when navigation isn't allowed in the host context.
        }
    }

    async save() {
        if (this._saveInFlight) return;
        this._saveInFlight = true;
        try {
            const id = await saveDashboardV3({
                dashboardId: this.savedDashboardId,
                name: this.dashboardName,
                folder: this.folder,
                category: this.category,
                filterJson: this.filterJson,
                layoutJson: JSON.stringify({
                    columns: parseInt(this.gridSize, 10) || 12,
                    filterContextReportId: this.selectedFilterContextReportId
                }),
                isPublic: this.isPublic,
                componentsJson: JSON.stringify(this.components),
                lastKnownVersion: this.savedDashboardVersion,
                theme: this.theme,
                palette: this.palette,
                gridSize: this.gridSize,
                runAsMode: this.runAsMode,
                runAsUserId: this.runAsUserId,
                allowViewerRunAsChoice: this.allowViewerRunAsChoice,
                description: this.description
            });
            this.savedDashboardId = id;
            this.savedDashboardVersion = (this.savedDashboardVersion || 0) + 1;
            this.isDirty = false;
            this.persistDashboardIdInUrl(id);
            if (this.wiredDashboardsResult) {
                refreshApex(this.wiredDashboardsResult);
            }
            this.dispatchEvent(new ShowToastEvent({
                title: 'Dashboard saved',
                message: `"${this.dashboardName}" is up to date.`,
                variant: 'success'
            }));
            this.template.querySelector('c-cr-toolbar-save')?.triggerSuccess();
        } catch (error) {
            const rawMessage = error?.body?.message || error?.message || '';
            // Stable marker matched against CR_DashboardService conflict throw.
            if (rawMessage.startsWith('[CR_CONFLICT]')) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Conflict - reload required',
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

    persistDashboardIdInUrl(dashboardId) {
        try {
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: { apiName: 'Custom_Dashboard_Builder' },
                state: { c__dashboardId: dashboardId }
            }, true);
        } catch {
            // Some hosts (App Builder, embedded contexts) don't allow navigation; ignore.
        }
    }

    toastError(error) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Dashboard error',
                message: error?.body?.message || error.message,
                variant: 'error'
            })
        );
    }

    decorateComponentsWithRoots() {
        this.components = this.components.map((component) => ({
            ...component,
            rootObject: this.reportRootObjectsById[component.reportDefinitionId]
        }));
    }

    ensureFilterContext() {
        if (this.selectedFilterContextReportId && this.reportRootObjectsById[this.selectedFilterContextReportId]) {
            return;
        }
        if (this.selectedFilterContextReportId && Object.keys(this.reportRootObjectsById).length === 0) {
            return;
        }
        const first = this.components.find((component) => this.reportRootObjectsById[component.reportDefinitionId]);
        this.selectedFilterContextReportId = first ? first.reportDefinitionId : null;
    }
}