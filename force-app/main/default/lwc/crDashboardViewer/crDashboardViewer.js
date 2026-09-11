import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { subscribe as empSubscribe, unsubscribe as empUnsubscribe, onError as empOnError } from 'lightning/empApi';
import listDashboards from '@salesforce/apex/CR_DashboardService.listDashboards';
import loadDashboard from '@salesforce/apex/CR_DashboardService.loadDashboard';
import enqueueRun from '@salesforce/apex/CR_DashboardRunService.enqueueRun';
import getRun from '@salesforce/apex/CR_DashboardRunService.getRun';
import listRecentRuns from '@salesforce/apex/CR_DashboardRunService.listRecentRuns';
import listSnapshots from '@salesforce/apex/CR_DashboardRunService.listSnapshots';
import runReportById from '@salesforce/apex/CR_QueryEngine.runReportById';
import runReportsByIds from '@salesforce/apex/CR_QueryEngine.runReportsByIds';
import getDashboardPreference from '@salesforce/apex/CR_UserPreferenceService.getDashboardPreference';
import saveDashboardPreference from '@salesforce/apex/CR_UserPreferenceService.saveDashboardPreference';
import enqueueDashboardExports from '@salesforce/apex/CR_ExportService.enqueueDashboardExports';
import saveComponentChartType from '@salesforce/apex/CR_DashboardService.saveComponentChartType';
import canBuildDashboards from '@salesforce/apex/CR_DashboardService.canBuildDashboards';
import aiIsEnabled from '@salesforce/apex/CR_AIService.isEnabled';
import isEChartsDefault from '@salesforce/apex/CR_ReportConfigService.isEChartsDefault';
import { applyBrandTheme } from 'c/crBrandTheme';

const CHART_POINT_LIMIT = 12;
const DONUT_POINT_LIMIT = 8;
// Default palette used when Dashboard__c.Palette__c is unset (legacy data).
const CHART_COLORS = ['#0176d3', '#2e844a', '#fe9339', '#ba01ff', '#ea001e', '#0b827c', '#8c4b02', '#706e6b'];
const SUPPORTED_VISUALIZATIONS = new Set(['auto', 'table', 'bar', 'horizontal', 'line', 'donut', 'pie', 'metric', 'gauge', 'heatmap', 'treemap']);
// Visualization types that c-cr-chart can only render via the ECharts engine.
// Mirrors crReportViewer's _ECHARTS_TYPES (heatmap/treemap/gauge) minus gauge,
// which the dashboard tile renders with its own SVG KPI gauge rather than
// routing to c-cr-chart. Tiles whose type is in this set pass engine="echarts".
const ECHARTS_TILE_TYPES = new Set(['heatmap', 'treemap']);

// Phase B: 15 named palettes shared with crDashboardBuilder + crDashboardPropertiesModal.
// Kept in this file to avoid an extra static-resource hop and to let crChart
// receive a plain JS array that doesn't change at render time.
const PALETTE_COLORS = {
    Aurora:              ['#4F46E5','#7C3AED','#DB2777','#F59E0B','#10B981','#06B6D4','#3B82F6','#EC4899','#84CC16'],
    Branding:            ['#0070D2','#16325C','#54698D','#04E1CB','#7E8B9A','#FFB75D','#A094ED','#1B96FF','#FE5C4C'],
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

// Options for the per-tile chart-type picker shown in the viewer. Pure UI override —
// does not persist to the dashboard component until the user opens the builder and
// saves. Values match the chart-type contract that c-cr-chart understands.
const TILE_CHART_TYPE_OPTIONS = [
    { label: 'Bar', value: 'bar' },
    { label: 'Horizontal Bar', value: 'horizontal' },
    { label: 'Line', value: 'line' },
    { label: 'Area', value: 'area' },
    { label: 'Donut', value: 'doughnut' },
    { label: 'Pie', value: 'pie' }
];

export default class CrDashboardViewer extends NavigationMixin(LightningElement) {
    @track dashboardOptions = [];
    @track componentViews = [];
    // Per-component chart-type overrides set via the in-tile picker. Persisted
    // across dashboard refreshes so the user's selection survives polling/reloads.
    tileChartTypeOverrides = {};
    // Per-tile client-side column sort state for table tiles, keyed by
    // component id -> { column, dir }. Ephemeral (resets on dashboard reload /
    // refresh). Default: absent, meaning "render the result's natural order".
    tileSorts = {};
    selectedDashboardId;
    dashboardName;
    dashboardFiltersJson = '[]';
    // Phase 2 (BI parity): dashboard-level Quick Filter bar. Relative date
    // cascades to every component by injecting a date filter clause into
    // dashboardFiltersJson before runDashboard fires. Default targets
    // Snapshot_Date__c (the canonical fact-table date field); admins with
    // a different date column edit dashboardQuickDateField in the URL or
    // accept the no-op behavior for non-fact reports.
    @track quickDatePreset = 'all';
    @track quickDateField = 'Snapshot_Date__c';
    // Phase B: theme/palette applied at viewer render time.
    @track dashboardTheme = 'Light';
    @track dashboardPalette = 'Aurora';
    loading = false;
    runningDashboard = false;
    exportingDashboard = false;
    activeRunId;
    runStatus;
    runMessage;
    runCompletedAt;
    runPollHandle;
    runPollAttempts = 0;
    pendingDashboardId;

    maxPollAttempts = 30;
    @track runPollLimitReached = false;
    // Polling now serves only as a fallback for empApi event delivery, so it can
    // be much slower than before. Real-time updates arrive via Dashboard_Run_Event__e.
    pollDelayMs = 10000;
    runEventChannel = '/event/Dashboard_Run_Event__e';
    _eventSubscription = null;
    _eventErrorListenerAdded = false;

    get hasComponents() {
        return this.componentViews.length > 0;
    }

    // Phase B: resolve the active palette into a colors array. Falls back to
    // the legacy CHART_COLORS constant when the dashboard pre-dates Phase B.
    get activePaletteColors() {
        return PALETTE_COLORS[this.dashboardPalette] || CHART_COLORS;
    }

    get viewerShellClass() {
        const base = this.dashboardTheme === 'Dark' ? 'viewer-shell viewer-shell_dark' : 'viewer-shell';
        return this._presentMode ? `${base} viewer-shell_present` : base;
    }

    // Present / fullscreen mode — expands the dashboard to fill the window
    // (CSS overlay, not the Fullscreen API which is often blocked inside the
    // Lightning iframe). Toggled from the header; Escape exits.
    @track _presentMode = false;
    togglePresent() {
        this._presentMode = !this._presentMode;
    }
    get presentLabel() {
        return this._presentMode ? 'Exit' : 'Present';
    }
    get presentIcon() {
        return this._presentMode ? 'utility:contract_alt' : 'utility:expand_alt';
    }

    get reloadDisabled() {
        return !this.selectedDashboardId || this.loading;
    }

    get runDisabled() {
        return !this.selectedDashboardId || this.loading || this.runningDashboard;
    }

    get exportDisabled() {
        return !this.selectedDashboardId || this.exportingDashboard;
    }

    get hasRunStatus() {
        return !!this.runStatus;
    }

    get dashboardTitle() {
        return this.dashboardName || 'Select a dashboard';
    }

    get dashboardSubtitle() {
        if (this.runCompletedAt) {
            return 'Last refreshed';
        }
        if (this.runStatus) {
            return this.runStatus;
        }
        return 'Choose a dashboard and refresh to load the latest visual preview.';
    }

    get showLastRefreshed() {
        return !!this.runCompletedAt;
    }

    get runStatusClass() {
        const status = (this.runStatus || '').toLowerCase();
        if (status === 'failed') {
            return 'run-status run-status_error';
        }
        if (status === 'partial') {
            return 'run-status run-status_warning';
        }
        return 'run-status';
    }

    // Drives the thin animated progress strip in the sticky header during runs.
    get isRunInFlight() {
        const s = (this.runStatus || '').toLowerCase();
        return s === 'running' || s === 'queued';
    }

    // Only show the terminal-state run banner (failed/partial) — the in-flight
    // progress strip handles running/queued, and successful completes are obvious.
    get showTerminalRunStatus() {
        const s = (this.runStatus || '').toLowerCase();
        return s === 'failed' || s === 'partial';
    }

    // ---- Phase 2 (BI parity): dashboard-level Quick Filters ----

    get quickDatePresetOptions() {
        return [
            { label: 'All time',     value: 'all' },
            { label: 'Today',        value: 'today' },
            { label: 'Yesterday',    value: 'yesterday' },
            { label: 'Last 7 days',  value: 'last7days' },
            { label: 'Last 30 days', value: 'last30days' },
            { label: 'This month',   value: 'thismonth' },
            { label: 'Last month',   value: 'lastmonth' },
            { label: 'This quarter', value: 'thisquarter' },
            { label: 'Year to date', value: 'ytd' }
        ];
    }

    // Compute the {start, end} (as YYYY-MM-DD strings) for the chosen
    // relative date preset. Mirrors the Report Viewer's preset semantics so
    // a user who learns "Last 30 days" there sees the same behavior here.
    computeQuickDateRange() {
        const preset = this.quickDatePreset || 'all';
        if (preset === 'all') return { start: null, end: null };
        const now = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const fmt = (d) => {
            const y = d.getFullYear();
            const m = String(d.getMonth() + 1).padStart(2, '0');
            const day = String(d.getDate()).padStart(2, '0');
            return `${y}-${m}-${day}`;
        };
        const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
        switch (preset) {
            case 'today':      return { start: fmt(today), end: fmt(addDays(today, 1)) };
            case 'yesterday':  return { start: fmt(addDays(today, -1)), end: fmt(today) };
            case 'last7days':  return { start: fmt(addDays(today, -7)), end: null };
            case 'last30days': return { start: fmt(addDays(today, -30)), end: null };
            case 'thismonth':  return { start: fmt(new Date(today.getFullYear(), today.getMonth(), 1)), end: null };
            case 'lastmonth': {
                const firstThis = new Date(today.getFullYear(), today.getMonth(), 1);
                const firstLast = new Date(today.getFullYear(), today.getMonth() - 1, 1);
                return { start: fmt(firstLast), end: fmt(firstThis) };
            }
            case 'thisquarter': {
                const q = Math.floor(today.getMonth() / 3);
                return { start: fmt(new Date(today.getFullYear(), q * 3, 1)), end: null };
            }
            case 'ytd': return { start: fmt(new Date(today.getFullYear(), 0, 1)), end: null };
            default:    return { start: null, end: null };
        }
    }

    // Merge persisted dashboard filters with the runtime quick-date filter.
    // The quick-date clauses live alongside the persisted filters so the
    // user's bar choice cascades to every component without overwriting
    // the admin's saved filter set. Components whose report doesn't have
    // the quickDateField silently ignore those clauses (the query engine
    // already handles unknown fields gracefully).
    get effectiveFiltersJson() {
        let persisted = [];
        try { persisted = JSON.parse(this.dashboardFiltersJson || '[]') || []; }
        catch { persisted = []; }
        const range = this.computeQuickDateRange();
        const quick = [];
        if (range.start && this.quickDateField) {
            quick.push({ field: this.quickDateField, operator: '>=', value: range.start });
        }
        if (range.end && this.quickDateField) {
            quick.push({ field: this.quickDateField, operator: '<', value: range.end });
        }
        return JSON.stringify([...persisted, ...quick]);
    }

    handleQuickDatePresetChange(event) {
        this.quickDatePreset = event.detail.value;
        // Re-run the dashboard so every component reflects the new filter.
        this.runDashboard();
    }

    // Parsed dashboard filters as displayable chips. Returns [] when filters
    // are absent or malformed so the chip bar simply doesn't render.
    get filterChips() {
        try {
            const raw = JSON.parse(this.dashboardFiltersJson || '[]');
            if (!Array.isArray(raw)) return [];
            return raw
                .map((f, idx) => {
                    if (!f || typeof f !== 'object') return null;
                    const field = f.field || f.fieldPath || '';
                    const operator = f.operator || '=';
                    const rawValue = f.value;
                    if (!field) return null;
                    let value = rawValue;
                    if (Array.isArray(rawValue)) value = rawValue.join(', ');
                    else if (rawValue === null || rawValue === undefined) value = '';
                    return {
                        key: `${field}|${operator}|${idx}`,
                        field,
                        operator,
                        value: String(value)
                    };
                })
                .filter(Boolean);
        } catch (e) {
            return [];
        }
    }

    get hasFilterChips() {
        return this.filterChips.length > 0;
    }

    // Snapshot of the previous filter set so we can show an inline "Undo"
    // banner after a chip is removed — accidental clicks are otherwise
    // unrecoverable because the dashboard auto-runs immediately.
    @track filterUndoSnapshot = null;
    @track filterUndoLabel = '';
    _filterUndoTimer = null;

    get filterUndoVisible() {
        return !!this.filterUndoSnapshot;
    }

    handleRemoveFilterChip(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        try {
            const raw = JSON.parse(this.dashboardFiltersJson || '[]');
            if (!Array.isArray(raw)) return;
            const previousJson = this.dashboardFiltersJson;
            let removedChip = null;
            // Re-derive each chip's key the same way the getter does, then drop the match.
            const remaining = raw.filter((f, idx) => {
                if (!f || typeof f !== 'object' || !f.field) return true;
                const op = f.operator || '=';
                const k = `${f.field}|${op}|${idx}`;
                if (k === key) {
                    removedChip = f;
                    return false;
                }
                return true;
            });
            this.dashboardFiltersJson = JSON.stringify(remaining);
            this.persistFiltersDebounced();
            if (removedChip) {
                this.filterUndoSnapshot = previousJson;
                const val = Array.isArray(removedChip.value) ? removedChip.value.join(', ') : removedChip.value;
                this.filterUndoLabel = `Removed filter: ${removedChip.field} ${removedChip.operator || '='} ${val ?? ''}`;
                if (this._filterUndoTimer) clearTimeout(this._filterUndoTimer);
                this._filterUndoTimer = setTimeout(() => {
                    this.filterUndoSnapshot = null;
                    this.filterUndoLabel = '';
                    this._filterUndoTimer = null;
                }, 8000);
            }
            // Re-run the dashboard so removed filter takes effect.
            if (this.activeRunId || this.runCompletedAt) {
                this.runDashboard();
            }
        } catch (e) {
            // Malformed JSON — leave filters alone.
        }
    }

    handleUndoFilterRemove() {
        if (!this.filterUndoSnapshot) return;
        this.dashboardFiltersJson = this.filterUndoSnapshot;
        this.persistFiltersDebounced();
        this.filterUndoSnapshot = null;
        this.filterUndoLabel = '';
        if (this._filterUndoTimer) {
            clearTimeout(this._filterUndoTimer);
            this._filterUndoTimer = null;
        }
        if (this.activeRunId || this.runCompletedAt) {
            this.runDashboard();
        }
    }

    connectedCallback() {
        applyBrandTheme(this);
        this.loadDashboards();
    }

    disconnectedCallback() {
        this.clearRunPoll();
        this.unsubscribeFromRunEvents();
    }

    // Tracks PoP keys we've already fetched (or are fetching) so the async
    // queries run exactly once per tile/report/period config. Without this
    // guard, splicing the overlay back onto componentViews would re-trigger
    // renderedCallback and loop forever.
    _popFetched = new Set();

    renderedCallback() {
        if (!Array.isArray(this.componentViews) || this.componentViews.length === 0) return;
        for (const view of this.componentViews) {
            if (!view.hasPeriodComparison || !view._popKey) continue;
            if (this._popFetched.has(view._popKey)) continue;
            this._popFetched.add(view._popKey);
            // Fire-and-forget; fetchPeriodComparison is resilient and re-checks
            // the key before splicing so a stale fetch can't clobber a newer one.
            this.fetchPeriodComparison(view.id);
        }
    }

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        const incomingDashboardId = pageRef?.state?.c__dashboardId;
        if (!incomingDashboardId || incomingDashboardId === this.selectedDashboardId) {
            return;
        }
        this.selectedDashboardId = incomingDashboardId;
        if (this.dashboardOptions.length > 0) {
            this.loadSelected();
        } else {
            this.pendingDashboardId = incomingDashboardId;
        }
    }

    async loadDashboards() {
        const dashboards = await listDashboards({ searchTerm: '' });
        this.dashboardOptions = dashboards.map((dashboard) => ({ label: dashboard.Name, value: dashboard.Id }));
        if (this.pendingDashboardId) {
            this.selectedDashboardId = this.pendingDashboardId;
            this.pendingDashboardId = null;
            await this.loadSelected();
        }
    }

    handleDashboardChange(event) {
        this.selectedDashboardId = event.detail.value;
        this.loadSelected();
    }

    handleDashboardMenuSelect(event) {
        if (event.detail.value === 'reload') {
            this.loadSelected();
        }
        if (event.detail.value === 'export') {
            this.exportDashboardComponents();
        }
        if (event.detail.value === 'snapshots') {
            this.toggleSnapshotPanel();
        }
        if (event.detail.value === 'refreshAll') {
            this.refreshAllComponents();
        }
    }

    // ---- Snapshot history panel (Phase 1 UAT) ----
    // Lets the user re-open a saved snapshot without leaving for the
    // Dashboard Runs tab. Lazy-loads on first open.
    @track snapshotPanelOpen = false;
    @track snapshotRows = [];
    snapshotsLoading = false;

    get snapshotMenuDisabled() {
        return !this.selectedDashboardId || this.loading;
    }

    get hasSnapshotRows() {
        return this.snapshotRows.length > 0;
    }

    async toggleSnapshotPanel() {
        if (!this.selectedDashboardId) return;
        this.snapshotPanelOpen = !this.snapshotPanelOpen;
        if (this.snapshotPanelOpen) {
            await this.refreshSnapshots();
        }
    }

    closeSnapshotPanel() {
        this.snapshotPanelOpen = false;
    }

    async refreshSnapshots() {
        if (!this.selectedDashboardId) return;
        this.snapshotsLoading = true;
        try {
            const rows = await listSnapshots({ dashboardId: this.selectedDashboardId, maxResults: 20 });
            this.snapshotRows = (rows || []).map((run) => ({
                id: run.Id,
                name: run.Name,
                completedAt: run.Completed_At__c,
                status: run.Status__c,
                componentCount: run.Component_Count__c,
                completedCount: run.Completed_Component_Count__c,
                failedCount: run.Failed_Component_Count__c
            }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not load snapshots',
                message: error?.body?.message || error.message,
                variant: 'error'
            }));
        } finally {
            this.snapshotsLoading = false;
        }
    }

    resumeRunPolling() {
        if (!this.activeRunId) return;
        this.runPollLimitReached = false;
        this.runPollAttempts = 0;
        this.runningDashboard = true;
        this.runMessage = 'Resumed polling…';
        this.loadRun();
    }

    handleOpenSnapshot(event) {
        const runId = event.currentTarget.dataset.id;
        if (!runId) return;
        this.clearRunPoll();
        this.unsubscribeFromRunEvents();
        this.activeRunId = runId;
        this.runningDashboard = false;
        this.runPollAttempts = 0;
        this.snapshotPanelOpen = false;
        this.loadRun();
    }

    async loadSelected() {
        if (!this.selectedDashboardId) {
            return;
        }
        this.clearRunPoll();
        this.activeRunId = null;
        this.runStatus = null;
        this.runMessage = null;
        this.runCompletedAt = null;
        this.loading = true;
        try {
            const payload = await loadDashboard({ dashboardId: this.selectedDashboardId, includeResults: false });
            this.dashboardName = payload.dashboard?.Name;
            this.ensureDashboardOption(this.selectedDashboardId, this.dashboardName);
            this.dashboardFiltersJson = payload.dashboard?.Filter_JSON__c || '[]';
            // Phase 1 v9: override the dashboard-level default with the running
            // user's saved filter state (if any). Loaded once per dashboard
            // open; the persist-on-change wiring takes over after that.
            await this.loadUserFilterPreference();
            // Phase B: read theme/palette so the viewer can re-style the
            // canvas + pass per-tile colors into crChart.
            this.dashboardTheme = payload.dashboard?.Theme__c || 'Light';
            this.dashboardPalette = payload.dashboard?.Palette__c || 'Aurora';
            this.componentViews = (payload.components || []).map((component) =>
                this.toComponentView(
                    component,
                    component.Report_Definition__c && payload.componentResults
                        ? payload.componentResults[component.Id]
                        : null
                )
            );
            await this.loadLatestRunPreview();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Dashboard error',
                    message: error?.body?.message || error.message,
                    variant: 'error'
                })
            );
        } finally {
            this.loading = false;
        }
    }

    // ---- Persistent filter state per (user, dashboard) — Phase 1 v9 ----
    //
    // Loaded once per dashboard open; saved on every change with a debounce so
    // dragging a slider or removing multiple chips doesn't write per keystroke.
    // Errors are silent on purpose — preference persistence is a nice-to-have,
    // never a correctness requirement, and toast spam on the dashboard view is
    // worse than the failure itself.
    _persistTimer = null;
    _persistInFlight = false;

    async loadUserFilterPreference() {
        if (!this.selectedDashboardId) return;
        try {
            const pref = await getDashboardPreference({ dashboardId: this.selectedDashboardId });
            if (pref && pref.filterStateJson) {
                this.dashboardFiltersJson = pref.filterStateJson;
            }
        } catch (_e) {
            // Silent — see method comment.
        }
    }

    persistFiltersDebounced() {
        if (this._persistTimer) clearTimeout(this._persistTimer);
        this._persistTimer = setTimeout(() => {
            this._persistTimer = null;
            this.persistFiltersNow();
        }, 600);
    }

    async persistFiltersNow() {
        if (!this.selectedDashboardId || this._persistInFlight) return;
        this._persistInFlight = true;
        try {
            await saveDashboardPreference({
                dashboardId: this.selectedDashboardId,
                filterStateJson: this.dashboardFiltersJson || '[]'
            });
        } catch (_e) {
            // Silent — see loadUserFilterPreference comment.
        } finally {
            this._persistInFlight = false;
        }
    }

    ensureDashboardOption(dashboardId, dashboardName) {
        if (!dashboardId || !dashboardName || this.dashboardOptions.some((option) => option.value === dashboardId)) {
            return;
        }
        this.dashboardOptions = [{ label: dashboardName, value: dashboardId }, ...this.dashboardOptions];
    }

    // Phase G: toggle the help drawer when the toolbar ? button is clicked
    // (first click opens, next click closes).
    // Phase J1: AI feature flag from CR_AI_Settings__mdt.Provider__c.
    // When false, the Explain button stays hidden and the panel is never
    // mounted, so deploys to orgs that haven't approved AI yet expose
    // zero AI UI.
    // View-only users (no Create on Dashboard__c) don't see Edit / chart-type /
    // builder controls. Server-side guards enforce it regardless; this is UX.
    @track canBuild = false;
    @wire(canBuildDashboards)
    wiredCanBuild({ data }) {
        if (data !== undefined) this.canBuild = data === true;
    }

    // Default-engine flag (CR_Report_Feature_Flag.Default_Chart_Engine). When
    // true, all Chart.js-family tiles (bar/line/donut/pie) render via ECharts
    // instead. Default false → no behavior change until an admin flips it.
    @track _echartsDefault = false;
    @wire(isEChartsDefault)
    wiredEChartsDefault({ data }) {
        if (data !== undefined) this._echartsDefault = data === true;
    }

    @track _aiEnabled = false;
    @wire(aiIsEnabled)
    wiredAiEnabled({ data, error }) {
        // Defensive: a missing classAccesses entry on the running user's
        // permission set silently fails the wire (error populated, data
        // undefined). Logging surfaces the cause when the Explain button
        // fails to appear in spite of Provider=Anthropic. The strict
        // === true was changed to !!data so future shape drift (e.g.
        // wrapped response) doesn't accidentally suppress the button.
        if (error) {
            // eslint-disable-next-line no-console
            console.warn('CR_AIService.isEnabled wire error', error);
            return;
        }
        this._aiEnabled = !!data;
    }
    get aiEnabled() {
        return this._aiEnabled;
    }
    get aiExplainDisabled() {
        return !this.selectedDashboardId || this.loading;
    }
    openAiSummary() {
        const panel = this.template.querySelector('c-cr-ai-panel');
        if (panel && typeof panel.open === 'function') {
            panel.open();
        }
    }

    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    editDashboard() {
        if (!this.selectedDashboardId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Custom_Dashboard_Builder' },
            state: { c__dashboardId: this.selectedDashboardId }
        });
    }

    async loadLatestRunPreview() {
        const runs = await listRecentRuns({ dashboardId: this.selectedDashboardId, maxResults: 1 });
        const latestRun = runs?.[0];
        if (!latestRun) {
            // No prior run — auto-trigger one so newly-added components don't sit empty
            // until the user manually clicks Refresh. Fire-and-forget; loadRun handles
            // status polling once the run completes.
            if (this.componentViews?.some((c) => c.hasReport)) {
                try {
                    this.startAsyncRun(false);
                } catch (e) {
                    /* user can still click Refresh manually */
                }
            }
            return;
        }
        this.activeRunId = latestRun.Id;
        this.runningDashboard = !this.isTerminalStatus(latestRun.Status__c);
        await this.loadRun();
    }

    runDashboard() {
        this.startAsyncRun(false);
    }

    snapshotDashboard() {
        this.startAsyncRun(true);
    }

    async startAsyncRun(snapshot) {
        if (!this.selectedDashboardId) {
            return;
        }
        this.clearRunPoll();
        this.runningDashboard = true;
        this.runPollAttempts = 0;
        this.runPollLimitReached = false;
        try {
            this.activeRunId = await enqueueRun({ dashboardId: this.selectedDashboardId, snapshot });
            this.runStatus = 'Queued';
            this.runMessage = snapshot ? 'Snapshot run queued.' : 'Dashboard run queued.';
            // Subscribe to live progress events. Polling fallback still runs in case empApi delivery fails.
            this.subscribeToRunEvents();
            await this.loadRun();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Dashboard run error',
                    message: error?.body?.message || error.message,
                    variant: 'error'
                })
            );
            this.runningDashboard = false;
        }
    }

    async loadRun() {
        if (!this.activeRunId) {
            return;
        }
        // Guard against concurrent loadRun calls. Both the setTimeout poll
        // chain AND the empApi event handler fire loadRun(); without this
        // guard each call would spawn its own setTimeout chain, causing tiles
        // to redraw twice as often (visible as flicker on dashboards with
        // active runs). Drop the call if one is already in flight — the
        // current cycle will pick up any state changes anyway.
        if (this._loadRunInFlight) {
            return;
        }
        this._loadRunInFlight = true;
        try {
            const payload = await getRun({ runId: this.activeRunId });
            this.applyRunPayload(payload);
            if (this.isTerminalStatus(this.runStatus)) {
                this.runningDashboard = false;
                this.clearRunPoll();
                this.unsubscribeFromRunEvents();
            } else if (this.runPollAttempts < this.maxPollAttempts) {
                this.runPollAttempts += 1;
                // Clear any previous poll handle before scheduling a new one
                // so the chain stays single-threaded even if a prior call
                // somehow leaked through.
                if (this.runPollHandle) {
                    clearTimeout(this.runPollHandle);
                    this.runPollHandle = null;
                }
                this.runPollHandle = setTimeout(() => this.loadRun(), this.pollDelayMs);
            } else {
                this.runningDashboard = false;
                this.clearRunPoll();
                this.runPollLimitReached = true;
                this.runMessage = 'Run is still processing. Click "Keep checking" to resume polling.';
            }
        } catch (error) {
            this.runningDashboard = false;
            this.clearRunPoll();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Run status error',
                    message: error?.body?.message || error.message,
                    variant: 'error'
                })
            );
        } finally {
            this._loadRunInFlight = false;
        }
    }

    applyRunPayload(payload) {
        const run = payload?.run;
        this.runStatus = run?.Status__c;
        this.runMessage = run?.Message__c;
        this.runCompletedAt = run?.Completed_At__c;
        const results = payload?.componentResults || {};
        const componentRunsByComponentId = new Map();
        (payload?.componentRuns || []).forEach((componentRun) => {
            if (componentRun.Dashboard_Component__c) {
                componentRunsByComponentId.set(componentRun.Dashboard_Component__c, componentRun);
            }
        });

        this.componentViews = this.componentViews.map((component) => {
            const componentRun = componentRunsByComponentId.get(component.id);
            const result = componentRun ? results[componentRun.Id] : null;
            return this.toComponentView(component, result, {
                componentRun,
                refreshedAt: componentRun?.Completed_At__c || component.refreshedAt
            });
        });
    }

    async exportDashboardComponents() {
        if (!this.selectedDashboardId) {
            return;
        }
        this.exportingDashboard = true;
        try {
            const result = await enqueueDashboardExports({ dashboardId: this.selectedDashboardId });
            const count = result?.exportIds?.length || 0;
            const warning = result?.warnings?.length ? ` ${result.warnings.join(' ')}` : '';
            this.dispatchEvent(
                new ShowToastEvent({
                    title: count > 0 ? 'Dashboard exports queued' : 'No exports queued',
                    message: `${count} export job(s) queued.${warning}`,
                    variant: count > 0 ? 'success' : 'warning'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Export error',
                    message: error?.body?.message || error.message,
                    variant: 'error'
                })
            );
        } finally {
            this.exportingDashboard = false;
        }
    }

    // Phase 1 v8: refresh every widget that has a Report_Definition__c in
    // ONE Apex round-trip instead of N. Saves ~(N-1) × RTT on dashboards
    // with multiple tiles. Per-widget failures are reported via the result's
    // errorMessage field; one bad report doesn't sink the whole refresh.
    async refreshAllComponents() {
        const targets = this.componentViews.filter((view) => view.hasReport && view.reportDefinitionId);
        if (targets.length === 0) return;
        const ids = targets.map((view) => view.reportDefinitionId);

        // Mark every targeted widget as refreshing so the spinners light up
        // simultaneously — matches what a parallel UX should look like even
        // though the work is still serialized inside the one Apex call.
        const targetIds = new Set(targets.map((view) => view.id));
        this.componentViews = this.componentViews.map((view) =>
            targetIds.has(view.id) ? { ...view, isRefreshing: true, refreshDisabled: true } : view
        );

        try {
            const resultsByDefId = await runReportsByIds({
                reportDefinitionIds: ids,
                pageSize: 250,
                dashboardFiltersJson: this.effectiveFiltersJson
            });
            const refreshedAt = new Date().toISOString();
            this.componentViews = this.componentViews.map((view) => {
                if (!targetIds.has(view.id)) return view;
                const result = resultsByDefId[view.reportDefinitionId];
                return this.toComponentView(view, result || {
                    errorMessage: `No result returned for "${view.name}"`,
                    columns: [], rows: [], rowCount: 0
                }, { refreshedAt });
            });
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Refresh All failed',
                message: error?.body?.message || error.message,
                variant: 'error'
            }));
            // Reset spinners even on whole-batch failure.
            this.componentViews = this.componentViews.map((view) =>
                targetIds.has(view.id) ? { ...view, isRefreshing: false, refreshDisabled: false } : view
            );
        }
    }

    get refreshAllDisabled() {
        return !this.componentViews || this.componentViews.length === 0
            || this.componentViews.every((view) => !view.hasReport);
    }

    async refreshComponent(event) {
        const componentId = event.currentTarget.dataset.id;
        const component = this.componentViews.find((view) => view.id === componentId);
        if (!component || !component.hasReport) {
            return;
        }

        this.componentViews = this.componentViews.map((view) =>
            view.id === componentId ? { ...view, isRefreshing: true, refreshDisabled: true } : view
        );

        try {
            const result = await runReportById({
                reportDefinitionId: component.reportDefinitionId,
                pageToken: null,
                pageSize: 250,
                dashboardFiltersJson: this.effectiveFiltersJson
            });
            this.componentViews = this.componentViews.map((view) =>
                view.id === componentId
                    ? this.toComponentView(component, result, { refreshedAt: new Date().toISOString() })
                    : view
            );
        } catch (error) {
            const result = {
                errorMessage: `Component "${component.name}" failed: ${error?.body?.message || error.message}`,
                columns: [],
                rows: [],
                rowCount: 0
            };
            this.componentViews = this.componentViews.map((view) =>
                view.id === componentId
                    ? this.toComponentView(component, result, { refreshedAt: new Date().toISOString() })
                    : view
            );
        }
    }

    openReport(event) {
        const componentId = event.currentTarget.dataset.id;
        const component = this.componentViews.find((view) => view.id === componentId);
        if (!component || !component.reportDefinitionId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Custom_Report_Viewer' },
            state: {
                c__reportId: component.reportDefinitionId,
                c__dashboardId: this.selectedDashboardId,
                c__dashboardName: encodeURIComponent(this.dashboardName || 'Dashboard'),
                c__dashboardFilters: encodeURIComponent(this.dashboardFiltersJson || '[]'),
                c__autoRun: 'true'
            }
        });
    }

    // Build table-tile rows, optionally grouped. Returns a flat list of either
    // header pseudo-rows ({isHeader:true,label,count,colspan}) or data rows
    // ({isHeader:false,key,cells}). Grouping keys off the raw value of
    // groupByKey; ungrouped returns plain data rows (isHeader:false).
    // Evaluate conditional-formatting rules against a single cell's raw value.
    // Rules are tried in order; the FIRST rule that targets this column AND
    // matches sets the cell's inline style. Returns '' when nothing matches
    // (or no rules), so callers leave the cell untouched.
    //   - numeric operators (> >= < <=) and 'between' coerce both sides to
    //     Number and skip when either is NaN.
    //   - '=' / '!=' compare as numbers when both sides parse numeric, else
    //     as case-insensitive strings.
    //   - 'contains' is a case-insensitive substring test.
    evaluateConditionalFormats(columnKey, rawValue, rules) {
        if (!Array.isArray(rules) || rules.length === 0) return '';
        for (const rule of rules) {
            if (!rule || rule.column !== columnKey) continue;
            if (this.cfRuleMatches(rule, rawValue)) {
                const parts = [];
                if (rule.background) parts.push(`background-color:${rule.background};`);
                if (rule.text) parts.push(`color:${rule.text};`);
                return parts.join('');
            }
        }
        return '';
    }

    cfRuleMatches(rule, rawValue) {
        const op = rule.operator;
        const num = (v) => {
            if (v === null || v === undefined || v === '') return NaN;
            return Number(v);
        };
        if (op === '>' || op === '>=' || op === '<' || op === '<=') {
            const a = num(rawValue);
            const b = num(rule.value);
            if (Number.isNaN(a) || Number.isNaN(b)) return false;
            if (op === '>') return a > b;
            if (op === '>=') return a >= b;
            if (op === '<') return a < b;
            return a <= b;
        }
        if (op === 'between') {
            const a = num(rawValue);
            const lo = num(rule.value);
            const hi = num(rule.valueTo);
            if (Number.isNaN(a) || Number.isNaN(lo) || Number.isNaN(hi)) return false;
            const min = Math.min(lo, hi);
            const max = Math.max(lo, hi);
            return a >= min && a <= max;
        }
        if (op === 'contains') {
            const hay = (rawValue === null || rawValue === undefined) ? '' : String(rawValue);
            const needle = (rule.value === null || rule.value === undefined) ? '' : String(rule.value);
            return hay.toLowerCase().indexOf(needle.toLowerCase()) !== -1;
        }
        if (op === '=' || op === '!=') {
            const a = num(rawValue);
            const b = num(rule.value);
            let equal;
            if (!Number.isNaN(a) && !Number.isNaN(b)) {
                equal = a === b;
            } else {
                const sa = (rawValue === null || rawValue === undefined) ? '' : String(rawValue);
                const sb = (rule.value === null || rule.value === undefined) ? '' : String(rule.value);
                equal = sa.toLowerCase() === sb.toLowerCase();
            }
            return op === '=' ? equal : !equal;
        }
        return false;
    }

    // Sort a copy of the raw data rows by a column, client-side. Numeric when
    // every present value in the column parses to a finite Number, else a
    // case-insensitive locale string compare. Returns a NEW array; the input is
    // left untouched so the natural order is preserved when no sort is active.
    sortDataRows(rawRows, sort) {
        if (!sort || !sort.column || !Array.isArray(rawRows) || rawRows.length === 0) {
            return rawRows;
        }
        const col = sort.column;
        const dir = sort.dir === 'asc' ? 1 : -1;
        const present = rawRows
            .map((r) => (r ? r[col] : undefined))
            .filter((v) => v !== null && v !== undefined && v !== '');
        const numeric = present.length > 0
            && present.every((v) => Number.isFinite(this.toNumber(v)));
        const indexed = rawRows.map((row, i) => ({ row, i }));
        indexed.sort((a, b) => {
            const av = a.row ? a.row[col] : undefined;
            const bv = b.row ? b.row[col] : undefined;
            const aEmpty = av === null || av === undefined || av === '';
            const bEmpty = bv === null || bv === undefined || bv === '';
            // Empty values sort last regardless of direction.
            if (aEmpty && bEmpty) return a.i - b.i;
            if (aEmpty) return 1;
            if (bEmpty) return -1;
            let cmp;
            if (numeric) {
                cmp = this.toNumber(av) - this.toNumber(bv);
            } else {
                cmp = String(av).localeCompare(String(bv), undefined, { numeric: true, sensitivity: 'base' });
            }
            if (cmp === 0) return a.i - b.i; // stable for ties
            return cmp * dir;
        });
        return indexed.map((x) => x.row);
    }

    // Compute the grand-total footer row for a table tile from the RAW data
    // rows (group headers excluded by construction — they aren't data rows).
    // Returns a single { key, cells:[{key,value,...}] } pseudo-row, or null
    // when no totals are configured. Numeric aggs coerce to Number and skip
    // non-numeric values; count is the data-row count.
    buildTotalsRow(rawRows, columns, compId, tableTotals) {
        if (!Array.isArray(tableTotals) || tableTotals.length === 0) return null;
        // Map each configured total to its column for quick lookup.
        const byColumn = new Map();
        for (const t of tableTotals) {
            if (t && t.column) byColumn.set(t.column, t.agg || 'sum');
        }
        if (byColumn.size === 0) return null;
        const rows = Array.isArray(rawRows) ? rawRows : [];
        let labelPlaced = false;
        const cells = columns.map((column, ci) => {
            const cell = { key: `${compId}-total-${column.key}`, value: '' };
            const agg = byColumn.get(column.key);
            if (agg) {
                cell.value = this.computeTableTotal(rows, column.key, agg);
            } else if (!labelPlaced && ci === 0) {
                // Put the "Total" label in the first column if it isn't itself
                // an aggregated column.
                cell.value = 'Total';
                labelPlaced = true;
            }
            return cell;
        });
        // If the first column WAS an aggregated column, surface the label in
        // the first non-aggregated column instead, so the footer reads clearly.
        if (!labelPlaced) {
            const firstPlain = columns.findIndex((c) => !byColumn.has(c.key));
            if (firstPlain !== -1) cells[firstPlain].value = 'Total';
        }
        return { key: `${compId}-totals`, cells };
    }

    computeTableTotal(rows, columnKey, agg) {
        if (agg === 'count') {
            return this.formatNumber(rows.length);
        }
        const nums = [];
        for (const row of rows) {
            const n = this.toNumber(row ? row[columnKey] : undefined);
            if (Number.isFinite(n)) nums.push(n);
        }
        if (nums.length === 0) return '';
        let result;
        if (agg === 'sum') {
            result = nums.reduce((s, n) => s + n, 0);
        } else if (agg === 'avg') {
            result = nums.reduce((s, n) => s + n, 0) / nums.length;
        } else if (agg === 'min') {
            result = Math.min(...nums);
        } else if (agg === 'max') {
            result = Math.max(...nums);
        } else {
            return '';
        }
        return this.formatNumber(result);
    }

    buildTileRows(rawRows, columns, compId, groupByKey, conditionalFormats) {
        const cfRules = Array.isArray(conditionalFormats) ? conditionalFormats : [];
        const hasCf = cfRules.length > 0;
        const mkData = (row, rowIndex) => ({
            key: `${compId}-${rowIndex}`,
            isHeader: false,
            rowClass: '',
            cells: columns.map((column) => {
                const value = row[column.key];
                const cell = {
                    key: `${compId}-${rowIndex}-${column.key}`,
                    value
                };
                if (hasCf) {
                    const style = this.evaluateConditionalFormats(column.key, value, cfRules);
                    if (style) cell.style = style;
                }
                return cell;
            })
        });
        if (!groupByKey) return rawRows.map(mkData);
        const groupCol = columns.find((c) => c.key === groupByKey);
        const groupColLabel = groupCol ? groupCol.label : '';
        const colspan = columns.length;
        const groups = new Map();
        rawRows.forEach((row, rowIndex) => {
            const raw = row[groupByKey];
            const label = (raw === null || raw === undefined || raw === '') ? '(empty)' : String(raw);
            if (!groups.has(label)) groups.set(label, []);
            groups.get(label).push({ row, rowIndex });
        });
        const labels = Array.from(groups.keys()).sort((a, b) =>
            String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' }));
        const out = [];
        labels.forEach((label, gi) => {
            const items = groups.get(label);
            out.push({
                key: `${compId}-grp-${gi}`,
                isHeader: true,
                rowClass: 'cr-tile-group-header',
                groupColLabel,
                label,
                count: items.length,
                colspan
            });
            items.forEach(({ row, rowIndex }) => out.push(mkData(row, rowIndex)));
        });
        return out;
    }

    toComponentView(component, result, overrides = {}) {
        const hasReport = !!component.Report_Definition__c || !!component.reportDefinitionId;
        const reportDefinitionId = component.Report_Definition__c || component.reportDefinitionId;
        const errorMessage = result && result.errorMessage;
        const columns = (result && result.columns) || [];
        const visualization = this.parseVisualization(component.Visualization_JSON__c || component.visualization);
        const visualizationType = this.resolveVisualizationType(visualization);
        const kpiOptions = this.extractKpiOptions(visualization);
        const chart = this.buildChartModel(component.Id || component.id, result, visualizationType, kpiOptions);
        const effectiveVisualizationType = chart.effectiveType || visualizationType;
        const componentRun = overrides.componentRun;
        const runStatus = componentRun?.Status__c || component.runStatus;
        const warnings = result?.warnings || [];
        const warningItems = warnings.map((warning, index) => ({
            key: `${component.Id || component.id}-warning-${index}`,
            message: warning
        }));
        // Visual grouping for table tiles: when the source report defines a
        // default group field (Definition_JSON "viewGroupBy", echoed on the run
        // result), cluster detail rows under a header per distinct value —
        // mirroring the report viewer. No grouping when the field is absent.
        const tileGroupBy = !hasReport || errorMessage
            ? null
            : (result && result.viewGroupBy && columns.some((c) => c.key === result.viewGroupBy)
                ? result.viewGroupBy
                : null);
        // Conditional formatting rules (table tiles) come off the same parsed
        // viz blob. Only an array of rules is honored; anything else is ignored
        // so legacy/non-table tiles render exactly as before.
        const tileConditionalFormats = Array.isArray(visualization?.conditionalFormats)
            ? visualization.conditionalFormats
            : null;
        // Client-side column sort (table tiles): sort the RAW data rows up
        // front so it composes with grouping, conditional formatting, and the
        // totals footer below. Sort state is per-tile and ephemeral; absent ->
        // natural order (zero regression).
        const compId = component.Id || component.id;
        const tileSort = this.tileSorts[compId] || null;
        const rawDataRows = !hasReport || errorMessage ? [] : ((result && result.rows) || []);
        const sortedDataRows = (tileSort && tileSort.column
            && columns.some((c) => c.key === tileSort.column))
            ? this.sortDataRows(rawDataRows, tileSort)
            : rawDataRows;
        const rows = !hasReport || errorMessage
            ? []
            : this.buildTileRows(sortedDataRows, columns, compId, tileGroupBy, tileConditionalFormats);
        // Table totals footer: only for table tiles with a configured,
        // non-empty tableTotals array. Aggregated over ALL data rows (group
        // headers excluded). null -> no footer (zero regression).
        const tileTableTotals = Array.isArray(visualization?.tableTotals) && !errorMessage
            ? visualization.tableTotals
            : null;
        const totalsRow = (hasReport && !errorMessage && tileTableTotals)
            ? this.buildTotalsRow(rawDataRows, columns, compId, tileTableTotals)
            : null;
        // Header models carry the sort indicator (▲/▼ on the active column).
        const tableColumns = columns.map((column) => {
            const active = tileSort && tileSort.column === column.key;
            return {
                key: column.key,
                label: column.label,
                sortIndicator: active ? (tileSort.dir === 'asc' ? ' ▲' : ' ▼') : '',
                ariaSort: active ? (tileSort.dir === 'asc' ? 'ascending' : 'descending') : 'none'
            };
        });
        // Phase D / E2: text/image/LWC tiles bypass the report-driven chart pipeline.
        const isTextTile = visualization && visualization.type === 'richtext';
        const isImageTile = visualization && visualization.type === 'image';
        const isLwcTile = visualization && visualization.type === 'lwc';
        return {
            id: component.Id || component.id,
            name: component.Name || component.name,
            layoutStyle: this.componentLayoutStyle(component),
            reportDefinitionId,
            hasReport,
            drilldownDisabled: !hasReport,
            refreshDisabled: !hasReport || runStatus === 'Running' || runStatus === 'Queued',
            // Phase D / E2 flags + content
            isTextTile,
            isImageTile,
            isLwcTile,
            isLwcKpi: isLwcTile && visualization?.lwcName === 'crDashboardKpiTileWidget',
            isLwcClock: isLwcTile && visualization?.lwcName === 'crDashboardClockWidget',
            lwcWidgetProps: visualization?.widgetProps || {},
            isReportTile: !isTextTile && !isImageTile && !isLwcTile,
            richTextHtml: visualization?.html || '',
            imageUrl: visualization?.url || '',
            imageAlt: visualization?.altText || '',
            imageStyle: `object-fit:${visualization?.fit || 'contain'};`,
            // Phase E1 / F2: explicit axis overrides plumbed through to crChart.
            // When useChartFromReport is set, the user wants the report's
            // defaults — pass empty arrays so crChart auto-detects.
            yAxisFields: visualization?.useChartFromReport
                ? []
                : (Array.isArray(visualization?.yAxis) ? visualization.yAxis : []),
            xAxisField: visualization?.useChartFromReport
                ? ''
                : (visualization?.xAxis || ''),
            hasError: !!errorMessage,
            errorMessage,
            visualization,
            visualizationType,
            effectiveVisualizationType,
            visualizationLabel: this.visualizationLabel(visualizationType, effectiveVisualizationType),
            showTable: hasReport && !errorMessage && !!result && (effectiveVisualizationType === 'table' || (!chart.hasChart && !chart.chartEmpty)),
            showMetric: chart.showMetric,
            showGauge: chart.showGauge,
            // Chart.js wrapper handles bar / line / donut / pie. SVG metric+gauge stay
            // as they are — they're KPI tiles, not Chart.js charts. heatmap/treemap
            // also flow through c-cr-chart but via its ECharts engine (showEChart).
            showLibChart: chart.showBar || chart.showLine || chart.showDonut || chart.showPie || chart.showEChart,
            chartLibType: chart.showEChart
                ? chart.effectiveType
                : (this.tileChartTypeOverrides[component.Id || component.id]
                    || (chart.showPie ? 'pie'
                        : chart.showDonut ? 'doughnut'
                        : chart.showLine ? 'line'
                        : chart.effectiveType === 'horizontal' ? 'horizontal'
                        : 'bar')),
            // heatmap/treemap always route to ECharts. When the Default_Chart_Engine
            // flag is on, bar/line/donut/pie route to ECharts too; otherwise they use
            // Chart.js. isEChartTile stays = showEChart (the BI types with no Chart.js
            // swap) so the per-tile chart-type picker behavior is unchanged regardless
            // of which engine is rendering.
            chartEngine: (this._echartsDefault || chart.showEChart) ? 'echarts' : 'chartjs',
            isEChartTile: chart.showEChart,
            // Deep-clone so the chart engine can mutate without colliding with LWC's reactive proxy.
            // When the chart was synthesized (count-by-category fallback for reports
            // with no numeric column), feed the synthetic data instead of the raw result.
            chartResult: (chart.showBar || chart.showLine || chart.showDonut || chart.showPie || chart.showEChart)
                ? (chart.synthResult
                    ? JSON.parse(JSON.stringify(chart.synthResult))
                    : (result ? JSON.parse(JSON.stringify({ columns: result.columns || [], rows: result.rows || [] })) : null))
                : null,
            chartEmpty: chart.chartEmpty,
            chartEmptyMessage: chart.chartEmptyMessage,
            chartFallbackNotice: chart.chartFallbackNotice,
            chart,
            noResult: hasReport && !errorMessage && !result && runStatus !== 'Running' && runStatus !== 'Queued',
            isLoading: hasReport && !errorMessage && !result && (runStatus === 'Running' || runStatus === 'Queued'),
            hasRows: rows.length > 0,
            rowCount: result && result.rowCount !== undefined && result.rowCount !== null ? result.rowCount : rows.length,
            columns,
            // Header models with per-column sort indicator (table tiles).
            tableColumns,
            rows,
            // Grand-total footer row (table tiles with tableTotals); null otherwise.
            totalsRow,
            hasTotalsRow: !!totalsRow,
            // Raw (untransformed) data rows + resolved group-by key retained so
            // a header-sort click can re-sort + rebuild the tile client-side
            // without a re-query.
            _rawRows: rawDataRows,
            _tileGroupBy: tileGroupBy,
            refreshedAt: overrides.refreshedAt || component.refreshedAt || (result ? new Date().toISOString() : null),
            runStatus,
            runMessage: componentRun?.Message__c,
            hasWarnings: warnings.length > 0 || componentRun?.Is_Truncated__c,
            warningItems,
            isRefreshing: false,
            // Period-over-period: flag tiles that have it configured so the
            // renderedCallback knows to fire the two scoped queries. The actual
            // overlay is spliced onto chart.* asynchronously by
            // fetchPeriodComparison. _popKey changes whenever the tile/report/
            // period config changes, so the fetch runs again only when needed.
            hasPeriodComparison: this.tileWantsPeriodComparison(visualization, effectiveVisualizationType),
            _popKey: this.tileWantsPeriodComparison(visualization, effectiveVisualizationType)
                ? this._popKeyParts(component.Id || component.id, reportDefinitionId, visualization)
                : null
        };
    }

    tileWantsPeriodComparison(visualization, effectiveVisualizationType) {
        const pc = visualization && visualization.periodComparison;
        return !!(pc && pc.enabled && pc.dateField
            && (effectiveVisualizationType === 'metric' || effectiveVisualizationType === 'gauge'));
    }

    _popKeyParts(componentId, reportDefinitionId, visualization) {
        const pc = (visualization && visualization.periodComparison) || {};
        return `${componentId}|${reportDefinitionId}|${pc.dateField || ''}|${pc.period || ''}`;
    }

    // Re-derive a view's current PoP key from its own state, for the race guard
    // in fetchPeriodComparison.
    _popKeyFor(view) {
        return this._popKeyParts(view.id, view.reportDefinitionId, view.visualization);
    }

    componentLayoutStyle(component) {
        const rawWidth = component.Width__c !== undefined && component.Width__c !== null ? component.Width__c : component.w;
        const rawHeight = component.Height__c !== undefined && component.Height__c !== null ? component.Height__c : component.h;
        const width = this.toPositiveInteger(rawWidth, 4, 1, 12);
        const height = this.toPositiveInteger(rawHeight, 3, 2, 10);
        return `grid-column: span ${width}; min-height: ${Math.max(11, height * 4.25)}rem;`;
    }

    parseVisualization(value) {
        if (!value) {
            return { type: 'auto' };
        }
        if (typeof value === 'object') {
            return value;
        }
        try {
            return JSON.parse(value) || { type: 'auto' };
        } catch {
            return { type: 'auto' };
        }
    }

    resolveVisualizationType(visualization) {
        const normalized = this.normalizeVisualizationType(visualization?.type);
        if (normalized === 'table' && visualization?.locked !== true) {
            return 'auto';
        }
        return normalized;
    }

    normalizeVisualizationType(type) {
        const normalized = (type || 'auto').toLowerCase();
        return SUPPORTED_VISUALIZATIONS.has(normalized) ? normalized : 'auto';
    }

    get tileChartTypeOptions() {
        return TILE_CHART_TYPE_OPTIONS;
    }

    async handleTileChartTypeChange(event) {
        const componentId = event.currentTarget.dataset.id;
        const newType = event.detail.value;
        if (!componentId || !newType) return;
        // Capture previous override for rollback if the server save fails.
        const previousOverride = this.tileChartTypeOverrides[componentId];
        // Optimistic update so the chart re-renders immediately.
        this.tileChartTypeOverrides = { ...this.tileChartTypeOverrides, [componentId]: newType };
        this.componentViews = this.componentViews.map((c) => {
            if (c.id !== componentId) return c;
            return { ...c, chartLibType: newType };
        });
        try {
            await saveComponentChartType({ componentId, chartType: newType });
        } catch (error) {
            // Roll back optimistic update.
            const reverted = { ...this.tileChartTypeOverrides };
            if (previousOverride === undefined) {
                delete reverted[componentId];
            } else {
                reverted[componentId] = previousOverride;
            }
            this.tileChartTypeOverrides = reverted;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not save chart type',
                message: error?.body?.message || error?.message || 'Unknown error',
                variant: 'error'
            }));
        }
    }

    // Header-sort click on a table tile. Toggles asc->desc->asc on repeat
    // clicks of the same column; a different column starts at asc. Re-sorts the
    // tile's retained raw rows and rebuilds only the table-related view fields
    // client-side (no re-query). Composes with grouping, conditional formatting,
    // and the totals footer because it sorts the DATA rows up front.
    handleHeaderSort(event) {
        const componentId = event.currentTarget.dataset.id;
        const column = event.currentTarget.dataset.column;
        if (!componentId || !column) return;
        const view = this.componentViews.find((v) => v.id === componentId);
        if (!view || !view.showTable) return;
        const prev = this.tileSorts[componentId];
        let dir = 'asc';
        if (prev && prev.column === column) {
            dir = prev.dir === 'asc' ? 'desc' : 'asc';
        }
        const next = { column, dir };
        this.tileSorts = { ...this.tileSorts, [componentId]: next };
        this.componentViews = this.componentViews.map((v) =>
            v.id === componentId ? { ...v, ...this.rebuildTileTable(v, next) } : v
        );
    }

    // Recompute the sort-dependent table fields (rows + header models) for a
    // tile from its retained raw rows. Group-by + conditional formats are
    // re-derived off the tile's own visualization so the rebuild matches what
    // toComponentView would have produced for the same sort.
    rebuildTileTable(view, sort) {
        const columns = view.columns || [];
        const compId = view.id;
        const viz = view.visualization || {};
        const rawRows = view._rawRows || [];
        const groupBy = view._tileGroupBy || null;
        const cf = Array.isArray(viz.conditionalFormats) ? viz.conditionalFormats : null;
        const sortedRows = (sort && sort.column && columns.some((c) => c.key === sort.column))
            ? this.sortDataRows(rawRows, sort)
            : rawRows;
        const rows = this.buildTileRows(sortedRows, columns, compId, groupBy, cf);
        const tableColumns = columns.map((column) => {
            const active = sort && sort.column === column.key;
            return {
                key: column.key,
                label: column.label,
                sortIndicator: active ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : '',
                ariaSort: active ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'
            };
        });
        return { rows, tableColumns, hasRows: rows.length > 0 };
    }

    visualizationLabel(type, effectiveType = type) {
        const labels = {
            auto: 'Auto visual',
            table: 'Table',
            bar: 'Bar chart',
            horizontal: 'Horizontal bar chart',
            line: 'Line chart',
            donut: 'Donut chart',
            pie: 'Pie chart',
            metric: 'Metric',
            gauge: 'Gauge',
            heatmap: 'Heatmap',
            treemap: 'Treemap'
        };
        if (type === 'auto' && effectiveType && effectiveType !== 'auto') {
            return `Auto: ${labels[effectiveType] || labels.table}`;
        }
        return labels[type] || labels.auto;
    }

    buildChartModel(componentId, result, visualizationType, kpiOptions = null) {
        const base = {
            hasChart: false,
            showMetric: false,
            showGauge: false,
            showBar: false,
            showLine: false,
            showDonut: false,
            showEChart: false,
            chartEmpty: false,
            chartEmptyMessage: 'No chartable rows returned.',
            points: [],
            donutItems: [],
            metricValue: null,
            metricLabel: null,
            metricSubtext: null,
            gaugeValue: null,
            gaugeMax: null,
            gaugeNeedleX: 110,
            gaugeNeedleY: 110,
            gaugeArcDashArray: '0 100',
            linePath: '',
            lineAreaPath: '',
            chartTruncated: false,
            effectiveType: visualizationType
        };
        if (!result || result.errorMessage || visualizationType === 'table') {
            return base;
        }

        const columns = result.columns || [];
        const rows = result.rows || [];
        const valueColumn = this.findValueColumn(columns, rows);
        if (!valueColumn) {
            // No numeric column. If user picked a chart type, synthesize a
            // "count by category" chart by grouping rows by their first text
            // column. This makes raw-list reports chartable without forcing the
            // user to add aggregations in the Report Builder.
            const wantsChart = visualizationType !== 'auto' && visualizationType !== 'table';
            if (wantsChart && rows.length > 0 && columns.length > 0) {
                const synthChart = this.buildSyntheticCountChart(componentId, columns, rows, visualizationType, base, kpiOptions);
                if (synthChart) return synthChart;
            }
            // Couldn't synthesize a chart — fall back to a table view.
            const isExplicitChart = visualizationType !== 'auto' && visualizationType !== 'table';
            return {
                ...base,
                effectiveType: 'table',
                chartFallbackNotice: isExplicitChart
                    ? `Showing as table — the report has no numeric column for the ${visualizationType} chart. Add a SUM/COUNT/AVG aggregation to see a chart.`
                    : null
            };
        }
        const labelColumn = this.findLabelColumn(columns, valueColumn);
        const sourcePoints = rows
            .map((row, index) => this.toChartPoint(componentId, row, index, labelColumn, valueColumn))
            .filter((point) => Number.isFinite(point.value));

        if (visualizationType === 'auto') {
            return this.buildAutoChartModel(base, sourcePoints, valueColumn, rows, labelColumn, kpiOptions);
        }
        if (visualizationType === 'metric') {
            return this.buildMetricModel(base, sourcePoints, valueColumn, rows.length, kpiOptions);
        }
        if (visualizationType === 'gauge') {
            return this.buildGaugeModel(base, sourcePoints, valueColumn, kpiOptions);
        }
        if (visualizationType === 'donut') {
            return this.buildDonutModel(base, sourcePoints, valueColumn);
        }
        if (visualizationType === 'pie') {
            return this.buildDonutModel(base, sourcePoints, valueColumn, true);
        }
        if (visualizationType === 'line') {
            return this.buildLineModel(base, sourcePoints, valueColumn);
        }
        if (visualizationType === 'horizontal') {
            // Same model shape as a vertical bar — the actual axis flip happens in
            // crChart via Chart.js indexAxis when chartLibType === 'horizontal'.
            return { ...this.buildBarModel(base, sourcePoints, valueColumn), effectiveType: 'horizontal' };
        }
        if (ECHARTS_TILE_TYPES.has(visualizationType)) {
            // heatmap / treemap render through c-cr-chart's ECharts engine. The SVG
            // bar/line/donut/metric/gauge models here don't apply; we just flag the
            // tile as an ECharts chart and hand the raw result straight to c-cr-chart,
            // which builds the heatmap/treemap from columns + rows itself.
            return {
                ...base,
                hasChart: true,
                showEChart: true,
                metricLabel: valueColumn.label || valueColumn.key,
                effectiveType: visualizationType
            };
        }
        return this.buildBarModel(base, sourcePoints, valueColumn);
    }

    buildAutoChartModel(base, sourcePoints, valueColumn, rows, labelColumn, kpiOptions = null) {
        if (!sourcePoints.length) {
            return { ...base, effectiveType: 'table' };
        }
        if (sourcePoints.length === 1) {
            return { ...this.buildMetricModel(base, sourcePoints, valueColumn, rows.length, kpiOptions), effectiveType: 'metric' };
        }
        if (this.looksLikeTrend(labelColumn, rows)) {
            return { ...this.buildLineModel(base, sourcePoints, valueColumn), effectiveType: 'line' };
        }
        return { ...this.buildBarModel(base, sourcePoints, valueColumn), effectiveType: 'bar' };
    }

    // Single source of truth for the metric tile's headline number: the SUM of
    // the measure column across the chartable source points. Shared with the
    // period-over-period path so current/prior periods aggregate identically to
    // the tile itself.
    aggregateMetric(sourcePoints) {
        return (sourcePoints || []).reduce((sum, point) => sum + point.value, 0);
    }

    buildMetricModel(base, sourcePoints, valueColumn, rowCount, kpiOptions = null) {
        if (!sourcePoints.length) {
            return { ...base, chartEmpty: true };
        }
        const total = this.aggregateMetric(sourcePoints);
        const kpi = this.computeKpiStatus(total, kpiOptions);
        return {
            ...base,
            hasChart: true,
            showMetric: true,
            // Raw number drives the count-up animation; formatted value is kept for
            // tests, exports, and as a non-animating fallback.
            metricRawValue: total,
            metricValue: this.formatNumber(total),
            metricLabel: valueColumn.label || valueColumn.key,
            metricSubtext: `${rowCount || sourcePoints.length} source row(s)`,
            // KPI threshold + target overlay (null/empty when unconfigured, so the
            // template's if:true guards leave the tile rendering exactly as before).
            valueColor: kpi.valueColor,
            metricValueStyle: kpi.valueColor ? `color:${kpi.valueColor};` : '',
            hasKpiVariance: kpi.hasVariance,
            kpiVarianceText: kpi.varianceText,
            kpiVarianceArrow: kpi.arrow,
            kpiVarianceStyle: kpi.varianceColor ? `color:${kpi.varianceColor};` : ''
        };
    }

    buildGaugeModel(base, sourcePoints, valueColumn, kpiOptions = null) {
        if (!sourcePoints.length) {
            return { ...base, chartEmpty: true };
        }
        const value = Math.max(0, sourcePoints[0].value);
        const maxObserved = Math.max(...sourcePoints.map((point) => Math.max(0, point.value)), value);
        const max = maxObserved <= 0 ? 100 : Math.ceil(maxObserved * 1.25);
        const ratio = Math.max(0, Math.min(value / max, 1));
        const angle = -180 + ratio * 180;
        const radians = (angle * Math.PI) / 180;
        // The needle is rendered as a fixed line pointing straight up; CSS rotation
        // around the pivot drives both the static position AND the sweep transition.
        // -90deg = leftmost (ratio=0), 0deg = up (ratio=0.5), 90deg = rightmost (ratio=1).
        const needleRotationDeg = angle + 90;
        const kpi = this.computeKpiStatus(value, kpiOptions);
        return {
            ...base,
            hasChart: true,
            showGauge: true,
            gaugeValue: this.formatNumber(value),
            gaugeMax: this.formatNumber(max),
            metricLabel: valueColumn.label || valueColumn.key,
            gaugeNeedleX: 110 + Math.cos(radians) * 68,
            gaugeNeedleY: 110 + Math.sin(radians) * 68,
            gaugeNeedleStyle: `transform: rotate(${needleRotationDeg}deg);`,
            gaugeArcDashArray: `${Math.round(ratio * 100)} 100`,
            // KPI threshold overlay: color the progress arc + value by the matched
            // band; expose the variance line. Empty/null when unconfigured.
            gaugeValueStyle: kpi.valueColor ? `stroke:${kpi.valueColor};` : '',
            gaugeTextStyle: kpi.valueColor ? `fill:${kpi.valueColor};` : '',
            valueColor: kpi.valueColor,
            hasKpiVariance: kpi.hasVariance,
            kpiVarianceText: kpi.varianceText,
            kpiVarianceArrow: kpi.arrow,
            kpiVarianceStyle: kpi.varianceColor ? `color:${kpi.varianceColor};` : ''
        };
    }

    // Normalize the KPI config off the parsed viz blob into a plain options
    // object, or null when nothing usable is configured. Only honored for the
    // single-value KPI tiles (metric/gauge); other tiles never pass it in.
    extractKpiOptions(visualization) {
        if (!visualization || typeof visualization !== 'object') return null;
        const target = Number(visualization.kpiTarget);
        const hasTarget = visualization.kpiTarget != null
            && visualization.kpiTarget !== ''
            && Number.isFinite(target);
        const bands = Array.isArray(visualization.kpiThresholds)
            ? visualization.kpiThresholds
                .filter((t) => t && Number.isFinite(Number(t.upTo)) && t.color)
                .map((t) => ({ upTo: Number(t.upTo), color: t.color }))
            : [];
        if (!hasTarget && bands.length === 0) return null;
        return {
            target: hasTarget ? target : null,
            goodDirection: visualization.kpiGoodDirection === 'down' ? 'down' : 'up',
            thresholds: bands
        };
    }

    // Given a numeric value + KPI options, return the matched band color and the
    // variance-vs-target overlay. Bands match ascending: the FIRST band whose
    // upTo >= value wins; a value above every band falls back to the last band's
    // color (treated as the "above all" color). All fields are empty/false when
    // options is null or the value isn't finite — callers render unchanged.
    computeKpiStatus(value, kpiOptions) {
        const blank = {
            valueColor: '',
            hasVariance: false,
            varianceText: '',
            arrow: '',
            varianceColor: ''
        };
        if (!kpiOptions || !Number.isFinite(value)) return blank;
        const out = { ...blank };
        const bands = kpiOptions.thresholds || [];
        if (bands.length > 0) {
            const sorted = [...bands].sort((a, b) => a.upTo - b.upTo);
            const match = sorted.find((b) => value <= b.upTo);
            out.valueColor = match ? match.color : sorted[sorted.length - 1].color;
        }
        if (kpiOptions.target != null && Number.isFinite(kpiOptions.target)) {
            const variance = value - kpiOptions.target;
            const pct = kpiOptions.target !== 0
                ? (variance / kpiOptions.target) * 100
                : null;
            out.hasVariance = true;
            out.arrow = variance > 0 ? '▲' : (variance < 0 ? '▼' : '');
            const pctText = pct != null ? ` (${variance >= 0 ? '+' : ''}${this.formatNumber(pct)}%)` : '';
            out.varianceText = `${variance >= 0 ? '+' : ''}${this.formatNumber(variance)}${pctText} vs target`;
            // Color honors goodDirection: a positive delta is good when higher is
            // better, bad when lower is better; zero is neutral grey.
            const good = '#2e844a';
            const bad = '#ea001e';
            const neutral = '#706e6b';
            if (variance === 0) {
                out.varianceColor = neutral;
            } else if (kpiOptions.goodDirection === 'down') {
                out.varianceColor = variance < 0 ? good : bad;
            } else {
                out.varianceColor = variance > 0 ? good : bad;
            }
        }
        return out;
    }

    // ---- Period-over-period (PoP) comparison (metric / gauge tiles) ----

    // Derive the single metric value from a raw run result, using the SAME
    // aggregation the tile renders with so current/prior periods are consistent:
    //   metric -> SUM of the measure column (or synthetic row-count when the
    //             report has no numeric column).
    //   gauge  -> the FIRST point's value (clamped at >= 0), matching
    //             buildGaugeModel.
    // Returns a finite number, or null when the result has no usable rows.
    computeTileMetric(result, vizType) {
        if (!result || result.errorMessage) return null;
        const columns = result.columns || [];
        const rows = result.rows || [];
        if (!rows.length || !columns.length) return null;
        const valueColumn = this.findValueColumn(columns, rows);
        let sourcePoints;
        if (valueColumn) {
            const labelColumn = this.findLabelColumn(columns, valueColumn);
            sourcePoints = rows
                .map((row, index) => this.toChartPoint('pop', row, index, labelColumn, valueColumn))
                .filter((point) => Number.isFinite(point.value));
        } else {
            // No numeric column: mirror buildSyntheticCountChart's row-count by
            // first non-numeric column so PoP matches the synthesized tile.
            const labelColumn = columns.find((c) => c.numeric !== true) || columns[0];
            if (!labelColumn) return null;
            const counts = new Map();
            for (const row of rows) {
                const raw = row?.[labelColumn.key];
                const label = raw === null || raw === undefined || raw === '' ? '(blank)' : String(raw);
                counts.set(label, (counts.get(label) || 0) + 1);
            }
            sourcePoints = Array.from(counts.values()).map((count) => ({ value: count }));
        }
        if (!sourcePoints.length) return null;
        if (vizType === 'gauge') {
            return Math.max(0, sourcePoints[0].value);
        }
        return this.aggregateMetric(sourcePoints);
    }

    // Compute the current/prior period start boundaries client-side. Returns
    // { currentStart, priorStart, now } as Date objects (local time). The viewer
    // formats them to 'YYYY-MM-DD' for the date-range filter clauses.
    //   month   -> first day of this / previous month
    //   quarter -> first day of this / previous quarter
    //   year    -> Jan 1 this / last year
    //   week    -> Monday of this / previous week
    computePeriodBounds(period, now = new Date()) {
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        let currentStart;
        let priorStart;
        if (period === 'year') {
            currentStart = new Date(today.getFullYear(), 0, 1);
            priorStart = new Date(today.getFullYear() - 1, 0, 1);
        } else if (period === 'quarter') {
            const q = Math.floor(today.getMonth() / 3);
            currentStart = new Date(today.getFullYear(), q * 3, 1);
            priorStart = new Date(today.getFullYear(), q * 3 - 3, 1);
        } else if (period === 'week') {
            // Monday-based week. getDay(): 0=Sun..6=Sat; shift Sunday to 7.
            const dow = today.getDay() === 0 ? 7 : today.getDay();
            currentStart = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (dow - 1));
            priorStart = new Date(currentStart.getFullYear(), currentStart.getMonth(), currentStart.getDate() - 7);
        } else {
            // month (default)
            currentStart = new Date(today.getFullYear(), today.getMonth(), 1);
            priorStart = new Date(today.getFullYear(), today.getMonth() - 1, 1);
        }
        return { currentStart, priorStart, now };
    }

    fmtDate(d) {
        const y = d.getFullYear();
        const m = String(d.getMonth() + 1).padStart(2, '0');
        const day = String(d.getDate()).padStart(2, '0');
        return `${y}-${m}-${day}`;
    }

    // Build a small PoP overlay object (delta / pct / arrow / color) from the
    // current + prior period metric values. goodDirection inverts the color
    // (▲ green by default; if 'down', ▲ is red). Empty when prior is null.
    buildPopOverlay(current, prior, vizType, kpiOptions) {
        const out = {
            showMetricPop: false,
            popText: '',
            popArrow: '',
            popStyle: '',
            popPriorValue: null,
            popDelta: null,
            popPct: null
        };
        if (!Number.isFinite(current) || !Number.isFinite(prior)) return out;
        const delta = current - prior;
        const pct = prior !== 0 ? (delta / prior) * 100 : null;
        const arrow = delta > 0 ? '▲' : (delta < 0 ? '▼' : '');
        const pctText = pct != null ? ` (${delta >= 0 ? '+' : ''}${this.formatNumber(pct)}%)` : '';
        const goodDirection = kpiOptions && kpiOptions.goodDirection === 'down' ? 'down' : 'up';
        const good = '#2e844a';
        const bad = '#ea001e';
        const neutral = '#706e6b';
        let color = neutral;
        if (delta !== 0) {
            if (goodDirection === 'down') color = delta < 0 ? good : bad;
            else color = delta > 0 ? good : bad;
        }
        out.showMetricPop = true;
        out.popPriorValue = prior;
        out.popDelta = delta;
        out.popPct = pct;
        out.popArrow = arrow;
        out.popText = `${delta >= 0 ? '+' : ''}${this.formatNumber(delta)}${pctText} vs prior ${vizType === 'gauge' ? 'period' : 'period'}`;
        out.popStyle = `color:${color};`;
        return out;
    }

    // Fire the two scoped PoP queries (current + prior period) for a tile, then
    // splice the computed overlay back onto that tile's component view. Resilient
    // by design: any error leaves the tile's normal value intact and skips the
    // PoP line. Guarded by a per-tile key so re-renders don't refetch endlessly.
    async fetchPeriodComparison(componentId) {
        const view = this.componentViews.find((v) => v.id === componentId);
        if (!view || !view.reportDefinitionId) return;
        const pc = view.visualization && view.visualization.periodComparison;
        if (!pc || !pc.enabled || !pc.dateField) return;
        const vizType = view.effectiveVisualizationType;
        if (vizType !== 'metric' && vizType !== 'gauge') return;
        const bounds = this.computePeriodBounds(pc.period);
        const currentStart = this.fmtDate(bounds.currentStart);
        const priorStart = this.fmtDate(bounds.priorStart);
        const nowStr = this.fmtDate(bounds.now);
        const field = pc.dateField;
        const currentFilters = JSON.stringify([
            { field, operator: '>=', value: currentStart },
            { field, operator: '<', value: nowStr }
        ]);
        const priorFilters = JSON.stringify([
            { field, operator: '>=', value: priorStart },
            { field, operator: '<', value: currentStart }
        ]);
        try {
            const currentResult = await runReportById({
                reportDefinitionId: view.reportDefinitionId,
                pageToken: null,
                pageSize: 250,
                dashboardFiltersJson: currentFilters
            });
            const priorResult = await runReportById({
                reportDefinitionId: view.reportDefinitionId,
                pageToken: null,
                pageSize: 250,
                dashboardFiltersJson: priorFilters
            });
            const currentVal = this.computeTileMetric(currentResult, vizType);
            const priorVal = this.computeTileMetric(priorResult, vizType);
            if (!Number.isFinite(currentVal) || !Number.isFinite(priorVal)) return;
            const kpiOptions = this.extractKpiOptions(view.visualization);
            const overlay = this.buildPopOverlay(currentVal, priorVal, vizType, kpiOptions);
            // Splice the overlay onto the tile, overriding the headline value
            // with the CURRENT-period metric. Skip if the tile/report/period key
            // changed underneath us (re-render raced our query).
            this.componentViews = this.componentViews.map((v) => {
                if (v.id !== componentId) return v;
                if (v._popKey !== this._popKeyFor(v)) return v;
                const chart = { ...v.chart };
                chart.metricRawValue = currentVal;
                chart.metricValue = this.formatNumber(currentVal);
                chart.gaugeValue = this.formatNumber(currentVal);
                chart.showMetricPop = overlay.showMetricPop;
                chart.popText = overlay.popText;
                chart.popArrow = overlay.popArrow;
                chart.popStyle = overlay.popStyle;
                chart.popPriorValue = overlay.popPriorValue;
                chart.popDelta = overlay.popDelta;
                chart.popPct = overlay.popPct;
                return { ...v, chart };
            });
        } catch (popError) {
            // Leave the tile's normal value intact; PoP is purely additive.
            this.logPopError(popError);
        }
    }

    // Swallow PoP query errors (kept as a method so the catch binding is used
    // and eslint stays quiet; intentionally silent — no toast spam).
    logPopError() {
        /* no-op: period comparison is additive, never blocks the tile */
    }

    buildBarModel(base, sourcePoints, valueColumn) {
        const points = sourcePoints.slice(0, CHART_POINT_LIMIT);
        if (!points.length) {
            return { ...base, chartEmpty: true };
        }
        const max = Math.max(...points.map((point) => Math.abs(point.value)), 1);
        const chartHeight = 132;
        const chartWidth = 300;
        const gap = points.length > 8 ? 6 : 10;
        const barWidth = Math.max(10, Math.floor((chartWidth - gap * Math.max(points.length - 1, 0)) / points.length));
        const baseline = 158;
        const chartPoints = points.map((point, index) => {
            const height = Math.max(2, Math.round((Math.abs(point.value) / max) * chartHeight));
            const x = 44 + index * (barWidth + gap);
            const y = baseline - height;
            return {
                ...point,
                x,
                y,
                barWidth,
                height,
                labelX: x + barWidth / 2,
                labelY: 184,
                valueY: Math.max(14, y - 6),
                color: this.activePaletteColors[index % this.activePaletteColors.length]
            };
        });
        return {
            ...base,
            hasChart: true,
            showBar: true,
            metricLabel: valueColumn.label || valueColumn.key,
            points: chartPoints,
            chartTruncated: sourcePoints.length > points.length
        };
    }

    buildLineModel(base, sourcePoints, valueColumn) {
        const points = sourcePoints.slice(0, CHART_POINT_LIMIT);
        if (!points.length) {
            return { ...base, chartEmpty: true };
        }
        const max = Math.max(...points.map((point) => Math.abs(point.value)), 1);
        const chartHeight = 132;
        const chartWidth = 300;
        const left = 44;
        const top = 20;
        const step = points.length === 1 ? 0 : chartWidth / (points.length - 1);
        const chartPoints = points.map((point, index) => {
            const x = left + index * step;
            const y = top + chartHeight - (Math.abs(point.value) / max) * chartHeight;
            return {
                ...point,
                x,
                y,
                labelX: x,
                labelY: 184
            };
        });
        const linePath = chartPoints.map((point, index) => `${index === 0 ? 'M' : 'L'} ${point.x} ${point.y}`).join(' ');
        const lineAreaPath = chartPoints.length > 1
            ? `${linePath} L ${chartPoints[chartPoints.length - 1].x} ${top + chartHeight} L ${left} ${top + chartHeight} Z`
            : '';
        return {
            ...base,
            hasChart: true,
            showLine: true,
            metricLabel: valueColumn.label || valueColumn.key,
            points: chartPoints,
            linePath,
            lineAreaPath,
            chartTruncated: sourcePoints.length > points.length
        };
    }

    buildDonutModel(base, sourcePoints, valueColumn, asPie = false) {
        const positivePoints = sourcePoints.filter((point) => point.value > 0).slice(0, DONUT_POINT_LIMIT);
        if (!positivePoints.length) {
            return {
                ...base,
                chartEmpty: true,
                chartEmptyMessage: `${asPie ? 'Pie' : 'Donut'} charts need positive numeric values.`
            };
        }
        const total = positivePoints.reduce((sum, point) => sum + point.value, 0);
        let cursor = 0;
        const gradientStops = [];
        const donutItems = positivePoints.map((point, index) => {
            const degrees = total === 0 ? 0 : (point.value / total) * 360;
            const start = cursor;
            const end = cursor + degrees;
            const color = this.activePaletteColors[index % this.activePaletteColors.length];
            cursor = end;
            gradientStops.push(`${color} ${start}deg ${end}deg`);
            return {
                ...point,
                color,
                colorStyle: `background:${color};`,
                percent: `${Math.round((point.value / total) * 100)}%`
            };
        });
        return {
            ...base,
            hasChart: true,
            showDonut: !asPie,
            showPie: asPie,
            metricLabel: valueColumn.label || valueColumn.key,
            metricValue: this.formatNumber(total),
            donutStyle: `background:conic-gradient(${gradientStops.join(', ')});`,
            donutItems,
            chartTruncated: sourcePoints.length > positivePoints.length
        };
    }

    findValueColumn(columns, rows) {
        const numericColumn = columns.find((column) => column.numeric === true);
        if (numericColumn) {
            return numericColumn;
        }
        return columns.find((column) => rows.some((row) => Number.isFinite(this.toNumber(row?.[column.key]))));
    }

    findLabelColumn(columns, valueColumn) {
        return columns.find((column) => column.key !== valueColumn.key && column.numeric !== true) ||
            columns.find((column) => column.key !== valueColumn.key) ||
            valueColumn;
    }

    looksLikeTrend(labelColumn, rows) {
        const labelName = `${labelColumn?.label || ''} ${labelColumn?.key || ''}`.toLowerCase();
        if (labelName.includes('date') || labelName.includes('month') || labelName.includes('year') || labelName.includes('period')) {
            return true;
        }
        const sample = rows.slice(0, 4).map((row) => row?.[labelColumn.key]).filter((value) => value !== undefined && value !== null);
        return sample.length > 1 && sample.every((value) =>
            typeof value === 'string' && /[-/]/.test(value) && !Number.isNaN(Date.parse(value))
        );
    }

    // When the report has no numeric column but the user picked a chart, group
    // rows by their first non-numeric column and use the count of rows per
    // group as the chart value. Lets a "list of records" report still produce
    // a meaningful chart (e.g., "count of records by Owner").
    buildSyntheticCountChart(componentId, columns, rows, visualizationType, base, kpiOptions = null) {
        const labelColumn = columns.find((c) => c.numeric !== true) || columns[0];
        if (!labelColumn) return null;
        const counts = new Map();
        for (const row of rows) {
            const raw = row?.[labelColumn.key];
            const label = raw === null || raw === undefined || raw === ''
                ? '(blank)'
                : String(raw);
            counts.set(label, (counts.get(label) || 0) + 1);
        }
        if (counts.size === 0) return null;
        const sourcePoints = Array.from(counts.entries()).map(([label, count], index) => ({
            key: `${componentId}-synth-${index}`,
            label,
            shortLabel: this.truncateLabel(label),
            value: count,
            formattedValue: this.formatNumber(count)
        }));
        const synthValueColumn = { key: '__synthCount', label: `Count of ${labelColumn.label || labelColumn.key}`, numeric: true };
        const fallbackNote = `Auto-grouped: counting rows by ${labelColumn.label || labelColumn.key} because the report has no numeric column. Add an aggregation in the Report Builder for full control.`;
        let chart;
        if (visualizationType === 'metric') chart = this.buildMetricModel(base, sourcePoints, synthValueColumn, rows.length, kpiOptions);
        else if (visualizationType === 'gauge') chart = this.buildGaugeModel(base, sourcePoints, synthValueColumn, kpiOptions);
        else if (visualizationType === 'donut') chart = this.buildDonutModel(base, sourcePoints, synthValueColumn);
        else if (visualizationType === 'pie') chart = this.buildDonutModel(base, sourcePoints, synthValueColumn, true);
        else if (visualizationType === 'line') chart = this.buildLineModel(base, sourcePoints, synthValueColumn);
        else chart = this.buildBarModel(base, sourcePoints, synthValueColumn);
        // Attach a synthetic result that c-cr-chart can render. c-cr-chart's own
        // findValueColumn looks for `column.numeric === true` first, which our
        // synthetic value column has — so it will plot the count.
        const synthRows = Array.from(counts.entries()).map(([label, count]) => ({
            [labelColumn.key]: label,
            __synthCount: count
        }));
        return {
            ...chart,
            chartFallbackNotice: fallbackNote,
            synthResult: {
                columns: [labelColumn, synthValueColumn],
                rows: synthRows
            }
        };
    }

    toChartPoint(componentId, row, index, labelColumn, valueColumn) {
        const rawLabel = row?.[labelColumn.key];
        const label = rawLabel === undefined || rawLabel === null || rawLabel === '' ? `Row ${index + 1}` : String(rawLabel);
        const value = this.toNumber(row?.[valueColumn.key]);
        return {
            key: `${componentId}-chart-${index}`,
            label,
            shortLabel: this.truncateLabel(label),
            value,
            formattedValue: this.formatNumber(value)
        };
    }

    toNumber(value) {
        if (value === null || value === undefined || value === '') {
            return NaN;
        }
        if (typeof value === 'number') {
            return value;
        }
        const normalized = String(value).replace(/[$,%\s]/g, '');
        return Number(normalized);
    }

    formatNumber(value) {
        if (!Number.isFinite(value)) {
            return '';
        }
        return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(value);
    }

    truncateLabel(value) {
        const label = value || '';
        return label.length > 12 ? `${label.slice(0, 11)}...` : label;
    }

    toPositiveInteger(value, fallback, min, max) {
        const parsed = Number.parseInt(value, 10);
        if (!Number.isFinite(parsed)) {
            return fallback;
        }
        return Math.min(Math.max(parsed, min), max);
    }

    isTerminalStatus(status) {
        return status === 'Complete' || status === 'Partial' || status === 'Failed';
    }

    clearRunPoll() {
        if (this.runPollHandle) {
            clearTimeout(this.runPollHandle);
            this.runPollHandle = null;
        }
    }

    // ---- Real-time run progress via Platform Event channel ----

    async subscribeToRunEvents() {
        if (this._eventSubscription) return;
        try {
            const subscription = await empSubscribe(this.runEventChannel, -1, (msg) => this.handleRunEvent(msg));
            this._eventSubscription = subscription;
            if (!this._eventErrorListenerAdded) {
                empOnError(() => {
                    // Connection error on the empApi channel — polling fallback handles it.
                });
                this._eventErrorListenerAdded = true;
            }
        } catch (error) {
            // Subscribe failed — polling fallback still drives progress updates.
        }
    }

    async unsubscribeFromRunEvents() {
        if (!this._eventSubscription) return;
        const sub = this._eventSubscription;
        this._eventSubscription = null;
        try {
            await empUnsubscribe(sub);
        } catch (error) {
            // ignore
        }
    }

    handleRunEvent(message) {
        const payload = message?.data?.payload || {};
        if (!this.activeRunId) return;
        // Both sides serialize the run Id to 18 chars; compare loosely on the 15-char prefix
        // to be safe across mixed-case/15-char references.
        const eventRunId = payload.Dashboard_Run_Id__c || '';
        if (eventRunId.substring(0, 15) !== String(this.activeRunId).substring(0, 15)) return;
        // Fire-and-forget refresh; loadRun will unsubscribe if the run reached a terminal status.
        this.loadRun();
    }
}