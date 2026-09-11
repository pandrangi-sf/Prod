import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import { updateRecord } from 'lightning/uiRecordApi';
import listReports from '@salesforce/apex/CR_ReportDefinitionService.listReportsOrdered';
import canBuildReports from '@salesforce/apex/CR_ReportDefinitionService.canBuildReports';
import runReportById from '@salesforce/apex/CR_QueryEngine.runReportById';
import runReportByIdSorted from '@salesforce/apex/CR_QueryEngine.runReportByIdSorted';
import getGroupSummary from '@salesforce/apex/CR_QueryEngine.getGroupSummary';
import getReportRowCount from '@salesforce/apex/CR_QueryEngine.getReportRowCount';
import getCrossGroupSummary from '@salesforce/apex/CR_QueryEngine.getCrossGroupSummary';
import getDistinctValues from '@salesforce/apex/CR_QueryEngine.getDistinctValues';
import getActivePresets from '@salesforce/apex/CR_FilterPresetService.getActivePresets';
import deleteReport from '@salesforce/apex/CR_ReportDefinitionService.deleteReport';
import enqueueExport from '@salesforce/apex/CR_ExportService.enqueueExport';
import enqueueFilteredExport from '@salesforce/apex/CR_ExportService.enqueueFilteredExport';
import listRecentExports from '@salesforce/apex/CR_ExportService.listRecentExports';
import USER_ID from '@salesforce/user/Id';
import isEChartsDefault from '@salesforce/apex/CR_ReportConfigService.isEChartsDefault';
import { scoreChartTypes, fitIcon, fitRank } from 'c/crChartAdvisor';
import { computePivot } from 'c/crPivotEngine';
import { exportToExcel, exportToPdf } from 'c/crExporters';
import { applyBrandTheme } from 'c/crBrandTheme';

const PIVOT_NUMERIC_TYPES = new Set(['CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT', 'NUMBER']);

const EXPORT_QUEUE_LIMIT = 10;
const EXPORT_POLL_INTERVAL_MS = 4000;
const EXPORT_POLL_MAX_ATTEMPTS = 12;

export default class CrReportViewer extends NavigationMixin(LightningElement) {
    @api defaultReportId;
    @api defaultReportName;
    @api autoRunOnLoad = false;
    @api hideReportSelector = false;
    @api hideExportButton = false;
    @api reportPageSize = 100;

    @track reportOptions = [];
    @track reportRecords = [];
    @track columns = [];
    @track displayRows = [];
    @track exportRows = [];
    @track chartResult = null;
    @track chartType = 'bar';
    @track listSort = 'LastModifiedDate|DESC';
    @track resultSortKey = null;
    @track resultSortDir = 'asc';
    // Master/detail mode. 'list' shows the SF-style report table; 'runner' shows the
    // single-report runner (toolbar + result tabs). Default 'list' so users land on
    // the catalog. defaultReportId / hideReportSelector skip straight to runner.
    @track viewMode = 'list';
    @track listSearchTerm = '';
    // Catalog table-level facet: narrow the report list to a single folder
    // (empty = all folders). Complements the free-text search + sort.
    @track listFolderFilter = '';
    // View-only users (no Create on Report_Definition__c) don't see Edit/Delete.
    @track canBuild = false;

    // Field|direction values map to listReportsOrdered's (sortBy, sortDir) inputs.
    listSortOptions = [
        { label: 'Recently Modified', value: 'LastModifiedDate|DESC' },
        { label: 'Recently Created', value: 'CreatedDate|DESC' },
        { label: 'Recently Run', value: 'Last_Run_At__c|DESC' },
        { label: 'Name (A–Z)', value: 'Name|ASC' },
        { label: 'Name (Z–A)', value: 'Name|DESC' }
    ];

    _ECHARTS_TYPES = new Set(['heatmap', 'treemap', 'gauge']);

    // Advisor-driven chart type options. Each option carries a fit verdict
    // (recommended / available / notFitting) and a one-line caption that the
    // combobox renders as the option description. Sorted recommended-first so
    // the dropdown nudges users toward sensible picks; nothing is disabled,
    // any chart type is still selectable.
    get chartTypeOptions() {
        const verdicts = scoreChartTypes(this.columns, this._unfilteredRows);
        return verdicts
            .map((v) => ({
                label: v.label,
                value: v.type,
                iconName: fitIcon(v.fit),
                description: v.caption,
                _rank: fitRank(v.fit)
            }))
            .sort((a, b) => a._rank - b._rank);
    }

    // Verdict for the chart the user has currently selected — surfaced under
    // the chart so the user always sees the rationale (or warning) for the
    // current pick.
    get chartTypeVerdict() {
        const verdicts = scoreChartTypes(this.columns, this._unfilteredRows);
        return verdicts.find((v) => v.type === this.chartType) || null;
    }

    get chartTypeVerdictClass() {
        const v = this.chartTypeVerdict;
        if (!v) return 'chart-caption';
        return `chart-caption chart-caption--${v.fit}`;
    }

    get chartTypeVerdictIcon() {
        const v = this.chartTypeVerdict;
        return v ? fitIcon(v.fit) : 'utility:info_alt';
    }

    get hasChartCaption() {
        const v = this.chartTypeVerdict;
        return !!(v && v.caption);
    }

    // Default-engine flag. When on, every chart type renders via ECharts; when
    // off, only the BI types (heatmap/treemap/gauge) do and the rest use
    // Chart.js. Default false → no behavior change until an admin flips it.
    @track _echartsDefault = false;
    @wire(isEChartsDefault)
    wiredEChartsDefault({ data }) {
        if (data !== undefined) this._echartsDefault = data === true;
    }

    get chartEngine() {
        return (this._echartsDefault || this._ECHARTS_TYPES.has(this.chartType)) ? 'echarts' : 'chartjs';
    }

    // Results-tab view toggle: classic HTML table (default) vs the virtualized
    // AG Grid. Opt-in and additive — the grid renders the same filtered
    // {columns, rows} (chartResult) the table tracks, so toggling never changes
    // the data, only the renderer.
    @track gridView = false;
    toggleGridView() {
        this.gridView = !this.gridView;
    }
    get gridToggleLabel() {
        return this.gridView ? 'Classic table' : 'Grid view';
    }
    get gridToggleIcon() {
        return this.gridView ? 'utility:table' : 'utility:apps';
    }

    // ---- Pivot tab ----
    // Cross-tab over the same filtered rows the table/chart use (chartResult).
    // Config: rows field, optional columns field, measure field + aggregation.
    @track pivotRowField;
    @track pivotColField;
    @track pivotMeasureField;
    @track pivotAgg = 'sum';
    @track pivotResult = null;
    @track pivotError = null;

    get pivotFieldOptions() {
        // Mirror the visible column set (exclude internal paired-Id columns).
        return this.visibleColumns.map((c) => ({ label: c.label || c.key, value: c.key }));
    }
    // Columns field allows "(none)" → simple grouped aggregate.
    get pivotColFieldOptions() {
        return [{ label: '(none)', value: '' }, ...this.pivotFieldOptions];
    }
    get pivotMeasureOptions() {
        const numeric = this.visibleColumns
            .filter((c) => PIVOT_NUMERIC_TYPES.has(String(c.dataType || '').toUpperCase()))
            .map((c) => ({ label: c.label || c.key, value: c.key }));
        // Count needs no measure; offer it as an explicit choice.
        return [{ label: 'Count of rows', value: '__count__' }, ...numeric];
    }
    get pivotAggOptions() {
        return [
            { label: 'Sum', value: 'sum' },
            { label: 'Count', value: 'count' },
            { label: 'Average', value: 'avg' },
            { label: 'Min', value: 'min' },
            { label: 'Max', value: 'max' }
        ];
    }
    get hasPivotResult() {
        return !!this.pivotResult && this.pivotResult.rows && this.pivotResult.rows.length > 0;
    }
    // Reflect current measure selection in the combobox: Count-of-rows when the
    // count agg is active with no measure, otherwise the chosen measure field.
    get pivotMeasureValue() {
        return (this.pivotAgg === 'count' && !this.pivotMeasureField) ? '__count__' : this.pivotMeasureField;
    }

    handlePivotRowChange(event) { this.pivotRowField = event.detail.value; this.recomputePivot(); }
    handlePivotColChange(event) { this.pivotColField = event.detail.value || null; this.recomputePivot(); }
    handlePivotMeasureChange(event) {
        const v = event.detail.value;
        if (v === '__count__') {
            this.pivotMeasureField = null;
            this.pivotAgg = 'count';
        } else {
            this.pivotMeasureField = v;
            if (this.pivotAgg === 'count') this.pivotAgg = 'sum';
        }
        this.recomputePivot();
    }
    handlePivotAggChange(event) { this.pivotAgg = event.detail.value; this.recomputePivot(); }

    recomputePivot() {
        const src = this.chartResult || { columns: this.columns, rows: [] };
        const out = computePivot(src, {
            rowField: this.pivotRowField,
            colField: this.pivotColField || null,
            measureField: this.pivotMeasureField,
            agg: this.pivotAgg
        });
        if (out.error) {
            this.pivotError = out.error;
            this.pivotResult = null;
        } else {
            this.pivotError = null;
            this.pivotResult = { columns: out.columns, rows: out.rows };
        }
    }

    // The columns the user actually sees: full query columns minus the internal
    // Id columns that exist only to power Name→Id hyperlinks (buildLinkedColumnMap
    // pairs Name→Id; the Id is the hidden value side). Grid + exports + pivot
    // pickers use this so "what you see ≈ what you get".
    get _hiddenIdKeys() {
        const cols = (this.chartResult && this.chartResult.columns) || this.columns || [];
        return new Set([...this.buildLinkedColumnMap(cols).values()]);
    }
    get visibleResult() {
        const base = this.chartResult || { columns: this.columns || [], rows: [] };
        const hidden = this._hiddenIdKeys;
        return {
            columns: (base.columns || []).filter((c) => !hidden.has(c.key)),
            rows: base.rows || []
        };
    }
    get visibleColumns() {
        return this.visibleResult.columns;
    }

    // ---- Client-side exports (lazy-loaded on click) ----
    get currentReportName() {
        const rec = (this.reportRecords || []).find((r) => r.id === this.selectedReportId);
        return (rec && rec.name) || this.defaultReportName || 'Vital Report';
    }
    get exportFileBase() {
        return this.currentReportName.replace(/[^\w.-]+/g, '_').slice(0, 80) || 'report';
    }
    @track _exporting = false;
    get exportBusy() {
        return this._exporting;
    }

    async handleExportExcel() {
        if (this._exporting) return;
        this._exporting = true;
        try {
            await exportToExcel(this, this.visibleResult, `${this.exportFileBase}.xlsx`);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Excel export failed',
                message: (e && e.message) || 'Could not generate the Excel file.',
                variant: 'error'
            }));
        } finally {
            this._exporting = false;
        }
    }

    async handleExportPdf() {
        if (this._exporting) return;
        this._exporting = true;
        try {
            await exportToPdf(this, this.visibleResult, `${this.exportFileBase}.pdf`, this.currentReportName);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'PDF export failed',
                message: (e && e.message) || 'Could not generate the PDF file.',
                variant: 'error'
            }));
        } finally {
            this._exporting = false;
        }
    }

    // Download the current chart as a PNG via the engine's native export
    // (ECharts getDataURL / Chart.js canvas.toDataURL) — reads the canvas
    // backing store, so it's shadow-DOM-safe (no html2canvas).
    handleDownloadChartPng() {
        const chart = this.template.querySelector('c-cr-chart');
        const url = chart && chart.getPngDataUrl ? chart.getPngDataUrl() : null;
        if (!url) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Chart not ready',
                message: 'Render the chart first, then try the PNG download.',
                variant: 'warning'
            }));
            return;
        }
        const a = document.createElement('a');
        a.href = url;
        a.download = `${this.exportFileBase}-chart.png`;
        a.click();
    }

    handleChartTypePick(event) {
        this.chartType = event.detail.value;
    }

    // Phase 3 v10: column-header filters.
    //   _unfilteredRows: raw row objects from the last runReport, untouched.
    //   _columnFilters:  Map<columnKey, Set<allowedStringValue>>. An entry
    //                    means "only show rows whose column value is in this
    //                    set." Empty map = no filtering.
    //   _openFilterColumn: which column's filter panel is currently open
    //                    (one at a time, click-to-toggle).
    @track _unfilteredRows = [];
    @track _columnFilters = new Map();
    @track _openFilterColumn = null;
    // Server-sourced distinct values per column (all matching records, not just the
    // loaded page). Populated lazily when a column's filter panel is opened.
    @track _distinctByColumn = new Map();
    _distinctLoading = new Set();

    // ---- Group By (visual grouping of detail rows under collapsible headers) ----
    //   _groupByKey:      column.key to group on (null = no grouping). Pure display
    //                     transform — detail rows are clustered, never aggregated.
    //   _collapsedGroups: Set<groupLabel> of currently-collapsed groups.
    //   _groupByTouched:  once the user picks a value, stop applying the report's
    //                     saved default (viewGroupBy) on subsequent loads.
    @track _groupByKey = null;
    // Full group breakdown (value + true count) from a server aggregate, so grouping reflects the
    // ENTIRE result set instead of only the loaded page. Empty = fall back to loaded-window groups.
    @track _serverGroups = [];
    @track _collapsedGroups = new Set();
    _groupByTouched = false;
    // Commit 2: per-column filter mode + inline search.
    //   _columnFilterModes:    Map<colKey, 'isOneOf' | 'contains' | 'startsWith'>
    //                          (default 'isOneOf' which is the existing checkbox behavior)
    //   _columnTextFilters:    Map<colKey, string>  for 'contains' / 'startsWith' modes
    //   _columnSearchTerms:    Map<colKey, string>  inline-search inside the
    //                          checkbox popup, filters the visible options
    @track _columnFilterModes = new Map();
    @track _columnTextFilters = new Map();
    @track _columnSearchTerms = new Map();

    // Quick Filters v1 — top-level filter bar above the result table.
    // Auto-detects applicable fields from the current report's columns and
    // shows only the controls that are relevant. All clauses are merged into
    // dashboardFiltersJson via buildCombinedFiltersJson so they push down to
    // the server (no client-only fakery).
    @track _quickDatePreset = 'all';
    @track _quickDateField = null;
    @track _quickDateCustomStart = null;
    @track _quickDateCustomEnd = null;
    @track _quickTopN = '100';
    @track _quickMyRecords = false;
    @track _quickActiveOnly = false;
    @track _selectedPresetKey = '';
    @track _presetRecords = [];
    @track _timeGrain = 'none';
    // Server-computed date-grain buckets (value + true count over the WHOLE result set) for the
    // Time Grain "Group by month/quarter/…". Empty = fall back to bucketing the loaded page.
    @track _timeGrainBuckets = [];
    // Total rows the report returns under the current filters (for "Showing 100 of 14,166").
    @track _totalRowCount = null;
    // Two-dimension breakdown (grain x field) when both a Time Grain and a field Group By are set.
    @track _crossGroups = [];
    // Cross-group load state. _crossGroupPending is true while the server summary is in flight;
    // _crossGroupError holds a message when it failed. Both drive an explicit notice row instead of
    // silently degrading to a single-dimension view (which read to users as "the other grouping got
    // cleared" — i.e. looked like mutual exclusion).
    @track _crossGroupPending = false;
    @track _crossGroupError = null;

    selectedReportId;
    dashboardFiltersJson = null;
    sourceDashboardId = null;
    sourceDashboardName = null;
    nextPageToken;
    // True when the last load was an aggregate (grouped) query. Aggregate results come back
    // whole (no pagination), so sorting them in the browser is correct. Tabular results are
    // paginated, so a user sort must re-query the server (see handleColumnSort / runWithToken).
    _aggregateResult = false;
    // True when the currently displayed rows are already ordered by the server (a tabular column
    // sort was pushed down). Suppresses the client-side re-sort, which would reorder by rendered
    // cell text and could corrupt the server's real-field ordering (e.g. dates).
    _serverSorted = false;
    loading = false;
    exportLoading = false;
    activeTab = 'results';
    _exportPollTimer;
    _exportPollAttempts = 0;
    @track exportPollLimitReached = false;
    _pendingAutoRun = false;
    _lastStateKey = null;

    connectedCallback() {
        applyBrandTheme(this);
        this.loadReports();
        // Phase 3 v11: close any open filter menu when the user clicks
        // outside it. Uses composedPath() so we unwind LWC shadow-DOM
        // boundaries and correctly recognise the menu / its trigger button.
        this._documentClickHandler = (event) => {
            if (!this._openFilterColumn) return;
            const path = (event.composedPath && event.composedPath()) || [];
            for (const el of path) {
                if (!el || !el.classList) continue;
                if (el.classList.contains('column-filter-menu')) return;
                if (el.classList.contains('column-filter-trigger')) return;
            }
            this._openFilterColumn = null;
        };
        document.addEventListener('click', this._documentClickHandler);
    }

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (!pageRef) return;
        this.applyIncomingState(pageRef.state || {});
    }

    @wire(canBuildReports)
    wiredCanBuild({ data }) {
        if (data !== undefined) this.canBuild = data === true;
    }

    disconnectedCallback() {
        this.stopExportPolling();
        if (this._documentClickHandler) {
            document.removeEventListener('click', this._documentClickHandler);
            this._documentClickHandler = null;
        }
    }

    get disableRun() {
        return !this.selectedReportId || this.loading;
    }

    get disableEditDelete() {
        return !this.selectedReportId || this.loading;
    }

    get disableNext() {
        // Tabular keyset pagination is Id-ordered; while a user column sort is active the server
        // returns a single sorted window, so paging by Id would return mis-ordered rows. Disable
        // Next while a tabular sort is active (aggregate results are unpaginated anyway).
        if (this.resultSortKey && !this._aggregateResult) {
            return true;
        }
        return !this.nextPageToken || this.loading;
    }

    get hasRows() {
        return this.displayRows.length > 0;
    }

    // True once a report has been loaded into the viewer (columns have data),
    // regardless of whether the current filter state produces any rows. Used
    // to keep the Quick Filters bar visible even when filters narrow results
    // to zero — otherwise users have no UI to clear the filter that emptied
    // the table.
    get isReportLoaded() {
        return Array.isArray(this.columns) && this.columns.length > 0;
    }

    // True when a report is loaded but the current filter state produced no
    // rows. Drives a "no rows match" empty-state message that's distinct
    // from the "no report yet" placeholder.
    get hasFilteredOutAllRows() {
        return this.isReportLoaded && !this.hasRows;
    }

    get hasExports() {
        return this.exportRows.length > 0;
    }

    get hasDashboardFilters() {
        return this.dashboardFiltersJson && this.dashboardFiltersJson.trim() !== '[]';
    }

    get showReportSelector() {
        return !this.toBoolean(this.hideReportSelector);
    }

    get showExportAction() {
        return !this.toBoolean(this.hideExportButton);
    }

    get toolbarClass() {
        return this.showReportSelector ? 'toolbar' : 'toolbar toolbar_compact';
    }

    get filteredReportRecords() {
        const term = (this.listSearchTerm || '').trim().toLowerCase();
        const folder = this.listFolderFilter || '';
        const source = this.reportRecords || [];
        const filtered = source.filter((r) => {
            const matchesTerm = !term
                || (r.name || '').toLowerCase().includes(term)
                || (r.description || '').toLowerCase().includes(term)
                || (r.folder || '').toLowerCase().includes(term)
                || (r.category || '').toLowerCase().includes(term)
                || (r.createdByName || '').toLowerCase().includes(term);
            const matchesFolder = !folder || (r.folder || '') === folder;
            return matchesTerm && matchesFolder;
        });
        return filtered.map((r) => ({
            ...r,
            publicLabel: r.isPublic ? 'Yes' : 'No',
            publicClass: r.isPublic ? 'badge badge_yes' : 'badge badge_no'
        }));
    }

    // Distinct folders present in the catalog, for the Folder facet dropdown.
    // Hidden in the UI unless there are at least two folders to choose between.
    get listFolderOptions() {
        const folders = new Set();
        for (const r of (this.reportRecords || [])) {
            const f = (r.folder || '').trim();
            if (f) folders.add(f);
        }
        const opts = Array.from(folders)
            .sort((a, b) => a.localeCompare(b))
            .map((f) => ({ label: f, value: f }));
        return [{ label: 'All folders', value: '' }, ...opts];
    }
    get hasFolderFacet() {
        return this.listFolderOptions.length > 2;
    }
    handleListFolderChange(event) {
        this.listFolderFilter = (event.detail && event.detail.value) || '';
    }

    get hasReports() {
        return (this.reportRecords || []).length > 0;
    }

    get hasFilteredReports() {
        return this.filteredReportRecords.length > 0;
    }

    get showListMode() {
        // Single-report embeds (defaultReportId set or selector hidden) skip the list entirely.
        if (this.defaultReportId || this.toBoolean(this.hideReportSelector)) return false;
        return this.viewMode === 'list';
    }

    get showRunnerMode() {
        return !this.showListMode;
    }

    get listResultCount() {
        const total = (this.reportRecords || []).length;
        const shown = this.filteredReportRecords.length;
        return shown === total ? `${total} reports` : `${shown} of ${total} reports`;
    }

    get effectivePageSize() {
        // Quick-filter Top N is now a numeric-string value matching the
        // combobox options (50 / 100 / 250 / 500). Parse and cap.
        if (this._quickTopN) {
            const n = Number.parseInt(this._quickTopN, 10);
            if (Number.isFinite(n)) return Math.min(Math.max(n, 1), 500);
        }
        const parsed = Number.parseInt(this.reportPageSize, 10);
        if (!Number.isFinite(parsed)) {
            return 100;
        }
        return Math.min(Math.max(parsed, 1), 500);
    }

    get dashboardFilterMessage() {
        const name = this.sourceDashboardName || 'dashboard';
        return `Running with filters from ${name}.`;
    }

    async loadReports() {
        const [sortBy, sortDir] = this.listSort.split('|');
        const reports = await listReports({ searchTerm: '', sortBy, sortDir });
        this.reportOptions = reports.map((report) => ({ label: report.name, value: report.id }));
        this.reportRecords = reports;
        this.applyConfiguredReport();
        if (this._pendingAutoRun && this.selectedReportId) {
            this._pendingAutoRun = false;
            await this.run();
        }
    }

    handleListSortChange(event) {
        this.listSort = event.detail.value;
        this.loadReports();
    }

    handleListSearchChange(event) {
        // Be paranoid about where the typed value lives. lightning-input dispatches
        // both 'input' and 'change' events; depending on the event type and the
        // shadow-DOM mode, one of detail.value or target.value can be missing.
        // Pick whichever is a string (empty string is fine, undefined is not).
        const fromDetail = event && event.detail ? event.detail.value : undefined;
        const fromTarget = event && event.target ? event.target.value : undefined;
        const value = typeof fromDetail === 'string' ? fromDetail
            : typeof fromTarget === 'string' ? fromTarget
            : '';
        this.listSearchTerm = value;
    }

    handleOpenReport(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.selectedReportId = id;
        this.viewMode = 'runner';
        // Auto-run on open so the user immediately sees rows; matches SF's report-link behavior.
        this.run();
    }

    handleEditFromList(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.selectedReportId = id;
        this.handleEdit();
    }

    async handleDeleteFromList(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.selectedReportId = id;
        await this.handleDelete();
        await this.loadReports();
    }

    // ---- Admin: rename a report (name only) ----
    // Uses the UI API updateRecord (no Apex) so FLS/permissions are enforced
    // natively; the catalog action is gated to canBuild (admins/builders).
    @track renameModalOpen = false;
    @track renameId = null;
    @track renameValue = '';
    @track renameSaving = false;

    openRenameModal(event) {
        const id = event.currentTarget.dataset.id;
        const rec = (this.reportRecords || []).find((r) => r.id === id);
        if (!rec) return;
        this.renameId = id;
        this.renameValue = rec.name || '';
        this.renameModalOpen = true;
    }
    handleRenameInput(event) {
        this.renameValue = (event.detail && event.detail.value) || '';
    }
    cancelRename() {
        this.renameModalOpen = false;
        this.renameId = null;
        this.renameValue = '';
    }
    get renameSaveDisabled() {
        return this.renameSaving || !(this.renameValue || '').trim();
    }
    async confirmRename() {
        const name = (this.renameValue || '').trim();
        if (!name) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Name required', message: 'Enter a report name.', variant: 'warning' }));
            return;
        }
        if (name.length > 80) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Name too long', message: 'Report name must be 80 characters or fewer.', variant: 'warning' }));
            return;
        }
        this.renameSaving = true;
        const id = this.renameId;
        try {
            await updateRecord({ fields: { Id: id, Name: name } });
            // listReportsOrdered is @AuraEnabled(cacheable=true), so a refetch can
            // return the stale name until a hard reload. Patch the in-memory list
            // optimistically so the catalog row + picker update immediately.
            this.reportRecords = (this.reportRecords || []).map((r) => (r.id === id ? { ...r, name } : r));
            this.reportOptions = (this.reportOptions || []).map((o) => (o.value === id ? { ...o, label: name } : o));
            this.dispatchEvent(new ShowToastEvent({ title: 'Report renamed', message: `Renamed to "${name}".`, variant: 'success' }));
            this.cancelRename();
        } catch (e) {
            const msg = (e && e.body && e.body.message) || (e && e.message) || 'Could not rename the report.';
            this.dispatchEvent(new ShowToastEvent({ title: 'Rename failed', message: msg, variant: 'error' }));
        } finally {
            this.renameSaving = false;
        }
    }

    // Phase G: toggle the help drawer when the toolbar ? button is clicked
    // (first click opens, next click closes).
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    backToList() {
        this.viewMode = 'list';
        this.selectedReportId = null;
        this.columns = [];
        this.displayRows = [];
        this.nextPageToken = null;
        // QA round 3: same full-reset as handleReportChange. Returning to
        // the catalog should leave no filter state hanging on for the next
        // report to inherit.
        this.resetAllFilterState();
    }

    handleColumnSort(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (this.resultSortKey === key) {
            this.resultSortDir = this.resultSortDir === 'asc' ? 'desc' : 'asc';
        } else {
            this.resultSortKey = key;
            this.resultSortDir = 'asc';
        }
        // Aggregate reports return the whole (small) grouped set, so sorting in the browser is
        // correct and cheap. Tabular reports are paginated — sorting only the loaded page made
        // date-range reports look like they held only the first day or two of data. Re-query the
        // server so the sort spans the whole result set.
        if (this._aggregateResult) {
            this.applyResultSort();
        } else {
            this.nextPageToken = null;
            this.runWithToken(null, true);
        }
    }

    // Salesforce compound fields (Address, Location, Name) come back from SOQL as
    // nested objects, not flat values. Without this, the LWC template would render
    // them via implicit toString() as "[object Object]". We collapse them to a
    // human-readable single line; the sort comparator then has a real string to
    // compare against. Non-objects pass through unchanged.
    // Phase 3 v12: server does the filtering via dashboardFiltersJson
    // pushdown, so this method just builds display cells from the rows the
    // server returned (which are already filtered to the user's column-filter
    // selection). The chart is rebuilt from the same rows so it tracks the
    // table. Sort state is re-applied at the end.
    rebuildDisplayRowsAndChart() {
        // Time Grain (Group by month/day/week/…) now renders as server-computed bucket headers in
        // tableRows — the whole result set, with true counts. We no longer collapse the loaded page
        // into buckets here: that client-side roll-up only saw the loaded page, which produced
        // empty / duplicate / non-deterministic buckets and a timezone-rolled label.
        const rawRows = this._unfilteredRows || [];
        const rows = rawRows;
        // Build cells (with v8 record links + v9 Name→Id pairing).
        const linkedColumnMap = this.buildLinkedColumnMap(this.columns);
        this.displayRows = rows.map((row, rowIndex) => ({
            key: `${row.Id || rowIndex}`,
            cells: this.columns.map((column) => {
                const rawValue = this.formatCellValue(row[column.key]);
                let linkUrl = this.detectRecordLink(rawValue, column);
                if (!linkUrl && linkedColumnMap.has(column.key)) {
                    const idColumnKey = linkedColumnMap.get(column.key);
                    const idValue = row[idColumnKey];
                    if (typeof idValue === 'string' && this.looksLikeSfId(idValue)) {
                        linkUrl = `/lightning/r/${encodeURIComponent(idValue)}/view`;
                    }
                }
                // QA-C2: null / empty values render as em-dash so a 100%-null
                // column doesn't look like a load failure. Matches the
                // "(empty)" convention the column-filter popover uses for
                // null buckets. Exports use the raw value path, not this
                // display transform, so CSV files stay unaffected.
                const isEmpty = rawValue === null || rawValue === undefined || rawValue === '';
                return {
                    key: `${rowIndex}-${column.key}`,
                    value: isEmpty ? '—' : rawValue,
                    isEmpty,
                    cellClass: isEmpty ? 'cr-cell cr-cell--empty' : 'cr-cell',
                    linkUrl,
                    isLink: !!linkUrl
                };
            })
        }));
        // 3. Chart pulls from the same filtered rows so it tracks the table.
        this.chartResult = JSON.parse(JSON.stringify({
            columns: this.columns,
            rows: rows
        }));
        // 4. If a CLIENT sort is active, reapply it on the freshly-built cells. When the rows
        // were sorted server-side (tabular column sort), the order is already correct by the real
        // field — re-sorting here by rendered cell text could corrupt it, so skip.
        if (this.resultSortKey && !this._serverSorted) {
            this.applyResultSort();
        }
    }

    // Phase 3 v10: column header decorators — adds filter UI state per column.
    // Used by the template to render the filter icon, the open/close state of
    // its popup, the distinct-value options, and the currently-checked subset.
    get decoratedColumns() {
        return this.columns.map((col) => {
            const mode = this._columnFilterModes.get(col.key) || 'isOneOf';
            const hasIsOneOfFilter = this._columnFilters.has(col.key);
            const hasTextFilter = this._columnTextFilters.has(col.key)
                && (this._columnTextFilters.get(col.key) || '').length > 0;
            const hasFilter = (mode === 'isOneOf' && hasIsOneOfFilter)
                || (mode !== 'isOneOf' && hasTextFilter);
            const isOpen = this._openFilterColumn === col.key;
            return {
                ...col,
                isFilterMenuOpen: isOpen,
                hasActiveFilter: hasFilter,
                filterIcon: hasFilter ? 'utility:filterList' : 'utility:filter',
                filterTooltip: hasFilter ? `Filter active on ${col.label} (click to edit)` : `Filter ${col.label}`,
                filterIconVariant: hasFilter ? 'brand' : 'border-filled',
                filterMode: mode,
                isOneOfMode: mode === 'isOneOf',
                isContainsMode: mode === 'contains',
                isStartsWithMode: mode === 'startsWith',
                searchTerm: this._columnSearchTerms.get(col.key) || '',
                textFilterValue: this._columnTextFilters.get(col.key) || '',
                filterOptions: isOpen && mode === 'isOneOf' ? this.getFilterOptionsForColumn(col.key) : [],
                activeFilterValues: hasIsOneOfFilter ? Array.from(this._columnFilters.get(col.key)) : [],
                // ARIA label for the popover dialog so screen reader users
                // hear "Filter: <column>" when entering it via Tab.
                filterDialogLabel: `Filter: ${col.label || col.key}`
            };
        });
    }

    get filterModeOptions() {
        return [
            { label: 'Is one of', value: 'isOneOf' },
            { label: 'Contains', value: 'contains' },
            { label: 'Starts with', value: 'startsWith' }
        ];
    }

    // Distinct-value options, filtered by the inline search term if one is set.
    // Inline search is case-insensitive, substring-matched against each option's
    // display label so "(empty)" stays findable when the user types "em".
    getFilterOptionsForColumn(columnKey) {
        const distinct = new Map();
        // Prefer the server's distinct values (every matching record). Fall back to the
        // loaded rows only while that's in flight, or for non-groupable columns —
        // otherwise the picker would only ever offer values from the current page.
        const serverValues = this._distinctByColumn.get(columnKey);
        if (serverValues && serverValues.length) {
            for (const raw of serverValues) {
                const normalized = this.normalizeFilterValue(raw);
                if (!distinct.has(normalized)) {
                    const label = normalized === '' ? '(empty)' : String(this.formatCellValue(raw));
                    distinct.set(normalized, label);
                }
            }
        }
        for (const row of this._unfilteredRows || []) {
            const raw = row[columnKey];
            const normalized = this.normalizeFilterValue(raw);
            if (!distinct.has(normalized)) {
                const label = normalized === '' ? '(empty)' : String(this.formatCellValue(raw));
                distinct.set(normalized, label);
            }
        }
        const term = (this._columnSearchTerms.get(columnKey) || '').toLowerCase().trim();
        const filterFn = term
            ? (entry) => entry[1].toLowerCase().includes(term)
            : () => true;
        return Array.from(distinct.entries())
            .filter(filterFn)
            .sort((a, b) => a[1].localeCompare(b[1]))
            .map(([value, label]) => ({ label, value }));
    }

    handleFilterModeChange(event) {
        const colKey = event.target.dataset.key;
        const newMode = event.detail.value;
        if (!colKey) return;
        const modes = new Map(this._columnFilterModes);
        modes.set(colKey, newMode);
        this._columnFilterModes = modes;
        // Switching modes clears the other-mode value so the user sees a clean
        // state for the new operator. The user can re-apply if they meant both
        // to be active (which the engine doesn't support per-column anyway).
        if (newMode === 'isOneOf') {
            const tf = new Map(this._columnTextFilters);
            tf.delete(colKey);
            this._columnTextFilters = tf;
        } else {
            const cf = new Map(this._columnFilters);
            cf.delete(colKey);
            this._columnFilters = cf;
        }
        // No auto-run — wait for user to type the value + click Apply, or pick
        // checkbox values, so we don't blast empty queries between mode flips.
    }

    handleFilterSearchInput(event) {
        const colKey = event.target.dataset.key;
        if (!colKey) return;
        const term = event.target.value || '';
        const map = new Map(this._columnSearchTerms);
        if (term) map.set(colKey, term);
        else map.delete(colKey);
        this._columnSearchTerms = map;
    }

    handleTextFilterInput(event) {
        const colKey = event.target.dataset.key;
        if (!colKey) return;
        const map = new Map(this._columnTextFilters);
        // Trim whitespace-only input so a stray space doesn't render the
        // filter icon as "active" with no actual filtering happening. Only
        // the trimmed value is stored.
        const v = (event.target.value || '').trim();
        if (v) map.set(colKey, v);
        else map.delete(colKey);
        this._columnTextFilters = map;
    }

    handleTextFilterApply(event) {
        const colKey = event.currentTarget.dataset.key;
        if (!colKey) return;
        // Length cap mirrors buildCombinedFiltersJson — too-long inputs
        // would silently be dropped from the WHERE clause. Warn the user
        // instead of letting them think the filter applied.
        const current = (this._columnTextFilters.get(colKey) || '').trim();
        if (current.length > 200) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Filter text too long',
                message: `Contains / Starts-with values are capped at 200 chars (yours is ${current.length}). Shorten the text and apply again.`,
                variant: 'warning'
            }));
            return;
        }
        this._openFilterColumn = null;
        this.run();
    }

    normalizeFilterValue(v) {
        if (v === null || v === undefined) return '';
        if (typeof v === 'object') return String(this.formatCellValue(v));
        return String(v);
    }

    toggleFilterMenu(event) {
        event.stopPropagation();
        const key = event.currentTarget.dataset.key;
        this._openFilterColumn = this._openFilterColumn === key ? null : key;
        if (this._openFilterColumn) {
            this.loadDistinctValues(this._openFilterColumn);
        }
    }

    /**
     * Pull the column's distinct values from the SERVER (all matching records), so the
     * picker isn't limited to whatever happened to be on the loaded page. Cached per
     * column; on failure we simply keep the page-derived fallback.
     */
    loadDistinctValues(columnKey) {
        if (!columnKey || !this.selectedReportId) return;
        if (this._distinctByColumn.has(columnKey) || this._distinctLoading.has(columnKey)) return;

        this._distinctLoading.add(columnKey);
        getDistinctValues({ reportId: this.selectedReportId, fieldPath: columnKey, maxValues: 500 })
            .then((values) => {
                if (Array.isArray(values) && values.length) {
                    const next = new Map(this._distinctByColumn);
                    next.set(columnKey, values);
                    this._distinctByColumn = next;
                }
            })
            .catch(() => {
                // Non-groupable field or query issue — page-derived options still work.
            })
            .finally(() => {
                this._distinctLoading.delete(columnKey);
            });
    }

    // Swallows click events inside the filter menu so they don't bubble up to
    // the column-sort handler on the <th>.
    stopPropagation(event) {
        event.stopPropagation();
    }

    closeFilterMenu() {
        this._openFilterColumn = null;
    }

    // QA-D2: Escape closes the popover (the dominant keyboard pattern for
    // dismissable overlays). Previously there was no Escape handler, so
    // keyboard users had to Shift+Tab back to the trigger to dismiss.
    handleFilterMenuKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.closeFilterMenu();
        }
    }

    handleFilterChange(event) {
        const colKey = (event.target && event.target.name)
            || (event.currentTarget && event.currentTarget.dataset && event.currentTarget.dataset.key);
        if (!colKey) {
            // eslint-disable-next-line no-console
            console.warn('[crReportViewer] filter change with no column key', event);
            return;
        }
        const newValues = (event.detail && event.detail.value) || [];
        const map = new Map(this._columnFilters);
        if (newValues.length === 0) {
            map.delete(colKey);
        } else {
            map.set(colKey, new Set(newValues));
        }
        this._columnFilters = map;
        // Phase 3 v12: server-side pushdown — re-run the report with the new
        // filter set so the full dataset is filtered, not just loaded rows.
        this.runWithToken(null);
    }

    // Phase 3 v12: merge URL-state dashboard filters with interactive column
    // filters into a single dashboardFiltersJson payload that
    // CR_QueryEngine.runReportById accepts. Column filters use the IN
    // operator with the array of selected values, which is already supported
    // by CR_QueryEngine.ALLOWED_OPERATORS.
    // Quick Filters v1: ALSO appends the relative-date / my-records /
    // active-only clauses produced by quickFilterClauses, so they push to
    // the server too.
    // Map a result-column key to a server-filterable field path. Aggregate
    // reports alias grouping columns as SOQL SELECT aliases (g0, g1, …) and
    // aggregates as (a0, …); those aliases can't appear in a WHERE clause
    // ("Field not found: g4"). A GROUP column's real field is its label;
    // AGGREGATE columns aren't WHERE-filterable at all (would need HAVING), so
    // we skip them. Regular tabular columns are already keyed by their field.
    filterFieldForColumn(colKey) {
        const col = (this.columns || []).find((c) => c.key === colKey);
        if (!col) return colKey;
        const dt = String(col.dataType || '').toUpperCase();
        if (dt === 'GROUP') return col.label || colKey;
        if (dt === 'AGGREGATE') return null;
        return colKey;
    }

    buildCombinedFiltersJson() {
        const inbound = this.dashboardFiltersJson ? this.parseJsonSafe(this.dashboardFiltersJson, []) : [];
        const columnFilters = [];
        for (const [colKey, allowed] of this._columnFilters) {
            const mode = this._columnFilterModes.get(colKey) || 'isOneOf';
            if (mode !== 'isOneOf') continue;
            if (allowed && allowed.size > 0) {
                const field = this.filterFieldForColumn(colKey);
                if (!field) continue;
                columnFilters.push({
                    field,
                    operator: 'IN',
                    value: Array.from(allowed)
                });
            }
        }
        // Text-mode filters (contains / startsWith) emit LIKE clauses.
        // Engine's ALLOWED_OPERATORS already supports LIKE.
        //
        // QA-A1 fixes:
        //   - Drop the client-side \% / \_ escaping. SOQL's string-literal
        //     parser strips bare backslashes before LIKE evaluates the
        //     pattern, turning intended literal-escapes back into wildcards
        //     and silently disabling the filter for any input containing %
        //     or _. Documented behavior: % and _ in user input ARE wildcards,
        //     same as Salesforce's native report builder.
        //   - Cap pattern length at MAX_FILTER_LENGTH. A 5000-char input
        //     produces SOQL that may exceed query-string limits, get rejected
        //     server-side, and (with the catch block in runWithToken) leave
        //     stale rows on screen — looking like the filter did nothing.
        //   - Trim leading/trailing whitespace explicitly so a single-space
        //     input doesn't get treated as a real filter (was visible only
        //     as an "active filter" pill with no observable narrowing).
        const MAX_FILTER_LENGTH = 200;
        for (const [colKey, text] of this._columnTextFilters) {
            const mode = this._columnFilterModes.get(colKey) || 'isOneOf';
            if (mode === 'isOneOf') continue;
            const trimmed = (text || '').trim();
            if (!trimmed) continue;
            if (trimmed.length > MAX_FILTER_LENGTH) continue;
            const value = mode === 'contains' ? `%${trimmed}%` : `${trimmed}%`;
            const field = this.filterFieldForColumn(colKey);
            if (!field) continue;
            columnFilters.push({
                field,
                operator: 'LIKE',
                value
            });
        }
        const combined = [
            ...inbound,
            ...columnFilters,
            ...this.quickFilterClauses,
            ...(this._presetExtraClauses || [])
        ];
        return combined.length ? JSON.stringify(combined) : null;
    }

    // ---- Quick Filters v1 ----

    // Detect date-typed columns in the current report. Used to decide whether
    // to show the relative-date dropdown and to populate the field picker.
    get dateColumnOptions() {
        return (this.columns || [])
            .filter((c) => {
                const t = (c.dataType || '').toLowerCase();
                return t === 'date' || t === 'datetime';
            })
            .map((c) => ({ label: c.label || c.key, value: c.key }));
    }

    get hasDateColumns() {
        return this.dateColumnOptions.length > 0;
    }

    // Auto-detect a likely Owner / Assigned-To field on the current report.
    // Broadened beyond "owner" because activity reports commonly use
    // Assigned_To__c instead. Match order is intentional — owner-ish keys
    // first, then assigned-to-ish keys — so a report with both prefers
    // OwnerId for the "My records" filter (more reliable User reference).
    // Is the resolved owner column an Id/User-reference, or a plain name string?
    // Drives which "me" token we send (see the My-records clause above).
    get ownerFieldIsId() {
        const key = this.ownerFieldKey;
        if (!key) return false;
        const col = (this.columns || []).find((c) => c.key === key);
        const dt = String((col && col.dataType) || '').toUpperCase();
        if (dt === 'ID' || dt === 'REFERENCE') return true;
        // Key shape as a fallback: OwnerId, Assigned_To_Id__c, ...
        return /(^|_)id$|_id__c$/i.test(key);
    }

    get ownerFieldKey() {
        const cols = this.columns || [];
        // Tier 1 — owner-named keys (most reliable): OwnerId, Owner__c,
        // Owner_User_Id__c, etc.
        const ownerByKey = cols.find((c) =>
            /owner/i.test(c.key || '') && /id$|^owner$|user/i.test(c.key || '')
        );
        if (ownerByKey) return ownerByKey.key;
        // Tier 2 — keys containing "assigned" (Assigned_To__c, AssignedToId,
        // Activity_Assigned__c, etc.)
        const assignedByKey = cols.find((c) => /assigned/i.test(c.key || ''));
        if (assignedByKey) return assignedByKey.key;
        // Tier 3 — fall back to LABEL matching. The Activities & Visits
        // report uses a column whose label is "Assigned To" but whose
        // underlying key is something the previous tiers don't match. If
        // the column's display label mentions Owner or Assigned, the
        // underlying field is almost certainly a User reference; we use
        // the column's key as-is for the filter clause.
        const byLabel = cols.find((c) => /owner|assigned/i.test(c.label || ''));
        return byLabel ? byLabel.key : null;
    }

    get hasOwnerField() {
        return !!this.ownerFieldKey;
    }

    // Auto-detect an active/closed/status field on the current report. Returns
    // {key, activeValue} where activeValue is the literal that means "active".
    // Conservative pattern match: only IsActive / Is_Active__c / IsClosed.
    get activeFieldInfo() {
        const cols = this.columns || [];
        const isActive = cols.find((c) => /^isactive$|^is_active__c$/i.test(c.key || ''));
        if (isActive) return { key: isActive.key, activeValue: true };
        const isClosed = cols.find((c) => /^isclosed$/i.test(c.key || ''));
        if (isClosed) return { key: isClosed.key, activeValue: false };
        return null;
    }

    get hasActiveField() {
        return !!this.activeFieldInfo;
    }

    get datePresetOptions() {
        return [
            { label: 'All time',     value: 'all' },
            { label: 'Today',        value: 'today' },
            { label: 'Yesterday',    value: 'yesterday' },
            { label: 'Last 7 days',  value: 'last7days' },
            { label: 'Last 30 days', value: 'last30days' },
            { label: 'This month',   value: 'thismonth' },
            { label: 'Last month',   value: 'lastmonth' },
            { label: 'This quarter', value: 'thisquarter' },
            { label: 'Year to date', value: 'ytd' },
            { label: 'Custom range…', value: 'custom' }
        ];
    }

    get topNOptions() {
        // Values are kept as the numeric string ("100", "250", ...) so a
        // saved preset that sets {"topN":"100"} matches the right option
        // when applied. Earlier version used "default" as the value for
        // 100, which caused the combobox to blank out when a preset assigned
        // _quickTopN to "100" (no matching option).
        return [
            { label: 'Show 50',  value: '50' },
            { label: 'Show 100', value: '100' },
            { label: 'Show 250', value: '250' },
            { label: 'Show 500', value: '500' }
        ];
    }

    get showCustomDateRange() {
        return this._quickDatePreset === 'custom';
    }

    get effectiveDateField() {
        return this._quickDateField || (this.dateColumnOptions[0] && this.dateColumnOptions[0].value);
    }

    // Compute the actual filter clauses emitted to the server based on quick-
    // filter state. Each clause is a {field, operator, value} that CR_QueryEngine
    // already accepts via ALLOWED_OPERATORS.
    get quickFilterClauses() {
        const clauses = [];
        // Relative-date filter
        if (this._quickDatePreset && this._quickDatePreset !== 'all' && this.effectiveDateField) {
            const range = this.computeDateRange(this._quickDatePreset);
            if (range.start) {
                clauses.push({ field: this.effectiveDateField, operator: '>=', value: range.start });
            }
            if (range.end) {
                clauses.push({ field: this.effectiveDateField, operator: '<', value: range.end });
            }
        }
        // My records. The owner column is either a real User lookup (an Id) or a
        // NAME text field — the fact tables store the rep as Assigned_To__c ("Rhonda
        // Blank"), not a User reference. Comparing a name column to a user Id matches
        // nothing and fails silently, so send the token that fits the column's type
        // and let the server resolve it for the running user.
        if (this._quickMyRecords && this.ownerFieldKey) {
            clauses.push({
                field: this.ownerFieldKey,
                operator: '=',
                value: this.ownerFieldIsId ? '$CURRENT_USER_ID' : '$CURRENT_USER'
            });
        }
        // Active only
        if (this._quickActiveOnly && this.activeFieldInfo) {
            clauses.push({
                field: this.activeFieldInfo.key,
                operator: '=',
                value: this.activeFieldInfo.activeValue
            });
        }
        return clauses;
    }

    computeDateRange(preset) {
        const now = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const fmt = (d) => {
            if (!d) return null;
            const y = d.getFullYear();
            const m = String(d.getMonth() + 1).padStart(2, '0');
            const day = String(d.getDate()).padStart(2, '0');
            return `${y}-${m}-${day}`;
        };
        const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
        switch (preset) {
            case 'today':
                return { start: fmt(today), end: fmt(addDays(today, 1)) };
            case 'yesterday':
                return { start: fmt(addDays(today, -1)), end: fmt(today) };
            case 'last7days':
                return { start: fmt(addDays(today, -7)), end: null };
            case 'last30days':
                return { start: fmt(addDays(today, -30)), end: null };
            case 'thismonth':
                return { start: fmt(new Date(today.getFullYear(), today.getMonth(), 1)), end: null };
            case 'lastmonth': {
                const firstThis = new Date(today.getFullYear(), today.getMonth(), 1);
                const firstLast = new Date(today.getFullYear(), today.getMonth() - 1, 1);
                return { start: fmt(firstLast), end: fmt(firstThis) };
            }
            case 'thisquarter': {
                const q = Math.floor(today.getMonth() / 3);
                return { start: fmt(new Date(today.getFullYear(), q * 3, 1)), end: null };
            }
            case 'ytd':
                return { start: fmt(new Date(today.getFullYear(), 0, 1)), end: null };
            case 'custom':
                return {
                    start: this._quickDateCustomStart || null,
                    // The end the user picks is INCLUSIVE — "Apr 30" must include April 30. The
                    // filter clause is "< end", so advance the end by one day; otherwise the whole
                    // end date is dropped (e.g. April 30's records vanished from an Apr 1–30 range).
                    end: this._quickDateCustomEnd ? this.nextDayIso(this._quickDateCustomEnd) : null
                };
            default:
                return { start: null, end: null };
        }
    }

    // Add one calendar day to a "YYYY-MM-DD" string using UTC math (no timezone shift), handling
    // month/year boundaries. Used to make an inclusive end date work with the "< end" clause.
    nextDayIso(dateStr) {
        const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(dateStr));
        if (!iso) return dateStr;
        const d = new Date(Date.UTC(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3])));
        d.setUTCDate(d.getUTCDate() + 1);
        const y = d.getUTCFullYear();
        const m = String(d.getUTCMonth() + 1).padStart(2, '0');
        const day = String(d.getUTCDate()).padStart(2, '0');
        return `${y}-${m}-${day}`;
    }

    handleQuickDatePresetChange(event) {
        this._quickDatePreset = event.detail.value;
        if (this._quickDatePreset !== 'custom') {
            this.run();
        }
    }

    handleQuickDateFieldChange(event) {
        this._quickDateField = event.detail.value;
        if (this._quickDatePreset !== 'all') this.run();
    }

    handleQuickDateCustomChange(event) {
        const which = event.target.dataset.which;
        if (which === 'start') this._quickDateCustomStart = event.detail.value;
        else if (which === 'end') this._quickDateCustomEnd = event.detail.value;
    }

    handleQuickDateCustomApply() {
        this.run();
    }

    handleQuickTopNChange(event) {
        this._quickTopN = event.detail.value;
        this.run();
    }

    handleQuickMyRecordsToggle() {
        this._quickMyRecords = !this._quickMyRecords;
        this.run();
    }

    handleQuickActiveOnlyToggle() {
        this._quickActiveOnly = !this._quickActiveOnly;
        this.run();
    }

    // ---- Commit 3: Saved Filter Presets (admin-curated CMD) ----

    @wire(getActivePresets)
    wiredPresets({ data }) {
        if (data) this._presetRecords = data;
    }

    get hasPresets() {
        return (this._presetRecords || []).length > 0;
    }

    get presetOptions() {
        const opts = (this._presetRecords || []).map((p) => ({ label: p.label, value: p.key }));
        return [{ label: 'Pick a preset…', value: '' }, ...opts];
    }

    handlePresetChange(event) {
        const key = event.detail.value;
        this._selectedPresetKey = key;
        if (!key) return;
        const preset = (this._presetRecords || []).find((p) => p.key === key);
        if (!preset || !preset.filterJson) return;
        let parsed;
        try { parsed = JSON.parse(preset.filterJson); }
        catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not apply preset',
                message: 'Filter JSON is not valid JSON. Ask an admin to fix the preset record.',
                variant: 'error'
            }));
            return;
        }
        this.applyPreset(parsed);
    }

    // Apply preset properties to the quick-filter state. Unrecognized or
    // missing keys are ignored so admins can extend the JSON shape later
    // without breaking older LWC builds. Time grain is also reset here so
    // a sticky "Group by month" from a previous pick doesn't survive into
    // a preset that didn't intend it.
    applyPreset(p) {
        if (typeof p.datePreset === 'string') this._quickDatePreset = p.datePreset;
        if (typeof p.dateField === 'string') this._quickDateField = p.dateField;
        if (typeof p.dateStart === 'string') this._quickDateCustomStart = p.dateStart;
        if (typeof p.dateEnd === 'string') this._quickDateCustomEnd = p.dateEnd;
        if (typeof p.topN === 'string' || typeof p.topN === 'number') {
            this._quickTopN = String(p.topN);
        }
        if (typeof p.myRecords === 'boolean') this._quickMyRecords = p.myRecords;
        if (typeof p.activeOnly === 'boolean') this._quickActiveOnly = p.activeOnly;
        // Reset to "No grouping" unless the preset explicitly sets a grain.
        this._timeGrain = typeof p.timeGrain === 'string' ? p.timeGrain : 'none';
        // Optional pass-through: pre-set column filter clauses (advanced use).
        // Each entry expected as {field, operator, value} matching CR_QueryEngine
        // ALLOWED_OPERATORS. Stored in a separate state slot consumed by
        // buildCombinedFiltersJson.
        if (Array.isArray(p.columnFilters)) {
            this._presetExtraClauses = p.columnFilters.filter(
                (c) => c && c.field && c.operator
            );
        } else {
            this._presetExtraClauses = [];
        }
        this.run();
    }

    @track _presetExtraClauses = [];

    // ---- Commit 4: Time Grain selector ----
    // Client-side row aggregation. When the user picks a grain (Day / Week /
    // Month / Quarter / Year), the loaded rows get re-bucketed by the active
    // date field's value truncated to that grain. Numeric columns sum within
    // each bucket; non-numeric non-date columns are blanked (would be lossy
    // to aggregate). Other Quick Filters still run server-side; this is a
    // pure display transform that runs after rows arrive.

    get timeGrainOptions() {
        return [
            { label: 'No grouping',    value: 'none' },
            { label: 'Group by day',   value: 'day' },
            { label: 'Group by week',  value: 'week' },
            { label: 'Group by month', value: 'month' },
            { label: 'Group by quarter', value: 'quarter' },
            { label: 'Group by year',  value: 'year' }
        ];
    }

    get showTimeGrain() {
        return this.hasDateColumns && this.displayRows.length > 0;
    }

    handleTimeGrainChange(event) {
        this._timeGrain = event.detail.value;
        this._timeGrainBuckets = [];
        this._crossGroups = [];
        // Server-side bucketing over the WHOLE result set. If a field Group By is also active, do
        // a two-level breakdown (grain x field); otherwise a single-level grain summary.
        if (this._timeGrain !== 'none' && !this._aggregateResult && this.effectiveDateField) {
            if (this._groupByKey) {
                this.refreshCrossGroups();
            } else {
                this.refreshTimeGrainBuckets();
            }
        } else {
            // Grain turned off — if a field Group By is still active, restore its server breakdown.
            if (this._groupByKey && !this._aggregateResult) {
                this.refreshServerGroups();
            }
            this.rebuildDisplayRowsAndChart();
        }
    }

    async refreshTimeGrainBuckets() {
        const dateField = this.effectiveDateField;
        if (!dateField || this._timeGrain === 'none' || this._aggregateResult || !this.selectedReportId) {
            this._timeGrainBuckets = [];
            this.rebuildDisplayRowsAndChart();
            return;
        }
        try {
            const buckets = await getGroupSummary({
                reportDefinitionId: this.selectedReportId,
                groupField: dateField,
                dashboardFiltersJson: this.buildCombinedFiltersJson(),
                granularity: this._timeGrain
            });
            this._timeGrainBuckets = buckets || [];
        } catch (e) {
            // Surface the failure instead of silently reverting to ungrouped rows — a silent
            // fallback is how a wrong-looking grouping could slip through unnoticed.
            this._timeGrainBuckets = [];
            this.dispatchEvent(new ShowToastEvent({
                title: 'Grouping could not be computed',
                message: 'The grouped totals failed to load. Showing ungrouped rows — please try again.',
                variant: 'error'
            }));
        }
        this.rebuildDisplayRowsAndChart();
    }

    // Total row count under the current filters, for the "Showing X of Y" label. Cheap COUNT.
    async refreshTotalCount() {
        if (!this.selectedReportId) {
            this._totalRowCount = null;
            return;
        }
        try {
            this._totalRowCount = await getReportRowCount({
                reportDefinitionId: this.selectedReportId,
                dashboardFiltersJson: this.buildCombinedFiltersJson()
            });
        } catch (e) {
            this._totalRowCount = null;
        }
    }

    // Both a Time Grain and a field Group By active on a tabular report -> two-level breakdown.
    get isCrossGrouped() {
        return this._timeGrain !== 'none' && !!this._groupByKey && !this._aggregateResult;
    }

    async refreshCrossGroups() {
        if (!this.isCrossGrouped || !this.selectedReportId || !this.effectiveDateField) {
            this._crossGroups = [];
            this._crossGroupPending = false;
            this._crossGroupError = null;
            return;
        }
        this._crossGroupPending = true;
        this._crossGroupError = null;
        try {
            const rows = await getCrossGroupSummary({
                reportDefinitionId: this.selectedReportId,
                field1: this.effectiveDateField,
                gran1: this._timeGrain,
                field2: this._groupByKey,
                gran2: null,
                dashboardFiltersJson: this.buildCombinedFiltersJson()
            });
            this._crossGroups = rows || [];
            if (!this._crossGroups.length) {
                // No rows for a two-level grouping over a non-empty result is itself suspect —
                // flag it rather than falling back to a one-dimension view that hides the problem.
                this._crossGroupError = 'No combined groups were returned for this Time Grain + Group By.';
            }
        } catch (e) {
            // Surface the real reason instead of silently degrading to a single-dimension view.
            // The silent fallback is exactly what made two-level grouping look like mutual exclusion.
            this._crossGroups = [];
            const msg = (e && e.body && e.body.message) || (e && e.message) || 'Unknown error.';
            this._crossGroupError = msg;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Two-level grouping could not be computed',
                message: `${msg} — showing the Time Grain and Group By separately is disabled to avoid a misleading view. Please retry or clear one of them.`,
                variant: 'error'
            }));
        } finally {
            this._crossGroupPending = false;
        }
    }

    // Bucket key for a value at the chosen grain. Returns a sortable string
    // (e.g., "2026-Q2", "2026-05", "2026-W22") suitable for both display
    // and dictionary aggregation.
    bucketDate(rawValue, grain) {
        if (rawValue === null || rawValue === undefined || rawValue === '') return null;
        // Accept Date objects, ISO strings, "YYYY-MM-DD" date-only strings, or
        // millisecond timestamps. The SOQL pipeline sometimes returns objects
        // for compound DateTime fields, which need a toString step first.
        let candidate = rawValue;
        if (typeof candidate === 'object' && typeof candidate.toString === 'function') {
            candidate = candidate.toString();
        }
        // Read Y/M/D from a leading "YYYY-MM-DD" directly. Do NOT hand the string to `new Date()`
        // and then read getMonth()/getDate() — those interpret the value in local time, and an
        // ISO date string parses as UTC midnight, which rolls back a day (and month, at the 1st)
        // in negative-offset zones. That was the "April shows as 2026-03" / single-bucket bug.
        let y;
        let m;
        let day;
        const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(candidate));
        if (iso) {
            y = Number(iso[1]);
            m = Number(iso[2]) - 1;
            day = Number(iso[3]);
        } else {
            const d = new Date(candidate);
            if (isNaN(d.getTime())) return null;
            y = d.getFullYear();
            m = d.getMonth();
            day = d.getDate();
        }
        switch (grain) {
            case 'day':
                return `${y}-${String(m + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
            case 'week': {
                // ISO-ish week: Monday-based, simple year-week.
                const tmp = new Date(Date.UTC(y, m, day));
                const dayNum = tmp.getUTCDay() || 7;
                tmp.setUTCDate(tmp.getUTCDate() + 4 - dayNum);
                const yearStart = new Date(Date.UTC(tmp.getUTCFullYear(), 0, 1));
                const weekNo = Math.ceil((((tmp - yearStart) / 86400000) + 1) / 7);
                return `${tmp.getUTCFullYear()}-W${String(weekNo).padStart(2, '0')}`;
            }
            case 'month':
                return `${y}-${String(m + 1).padStart(2, '0')}`;
            case 'quarter':
                return `${y}-Q${Math.floor(m / 3) + 1}`;
            case 'year':
                return String(y);
            default:
                return null;
        }
    }

    // Aggregate raw rows by the chosen time grain. Returns a NEW rows array
    // or the input untouched if grain is 'none', no date field detected, or
    // bucketing yields zero rows (e.g., date values don't parse). The
    // fallback-to-input behavior keeps the table populated even when the
    // grain doesn't apply cleanly, so a user picking a grain never sees a
    // blank screen.
    aggregateRowsByTimeGrain(rows) {
        if (this._timeGrain === 'none') return rows;
        const dateField = this.effectiveDateField;
        if (!dateField) return rows;
        // When the server grain buckets are available, they are the authoritative bucket list +
        // counts (whole result set). Loaded rows still fill numeric sums / representative values
        // best-effort. Without them, fall back to bucketing the loaded page.
        const serverBuckets = this._timeGrainBuckets || [];
        const useServer = serverBuckets.length > 0;
        if (!useServer && (!rows || rows.length === 0)) return rows;
        // Numeric columns sum within the bucket. 'AGGREGATE' columns are
        // already numeric measures from a grouped report — include them.
        const numericKeys = this.columns
            .filter((c) => {
                const t = (c.dataType || '').toUpperCase();
                return t === 'DOUBLE' || t === 'INTEGER' || t === 'CURRENCY'
                    || t === 'PERCENT' || t === 'AGGREGATE' || c.numeric === true;
            })
            .map((c) => c.key);
        // Mode columns: when aggregating, non-numeric non-date columns are
        // collapsed to the most common value within the bucket (instead of
        // being blanked). Preserves visible context like Owner / Status.
        const modeKeys = this.columns
            .filter((c) => c.key !== dateField && !numericKeys.includes(c.key))
            .map((c) => c.key);

        const buckets = new Map();
        const tallies = new Map(); // bucketKey -> { col -> { val -> count } }
        let skipped = 0;

        const seedBucket = (bucketKey, serverCount) => {
            const seed = { _rowCount: serverCount == null ? 0 : serverCount };
            this.columns.forEach((c) => { seed[c.key] = null; });
            seed[dateField] = bucketKey;
            seed.Id = `bucket_${bucketKey}`;
            numericKeys.forEach((k) => { seed[k] = 0; });
            buckets.set(bucketKey, seed);
            tallies.set(bucketKey, {});
        };

        // Authoritative buckets first: every grain value across the whole result set, true counts.
        if (useServer) {
            for (const b of serverBuckets) {
                const key = b.value == null || b.value === '' ? '(empty)' : b.value;
                seedBucket(key, b.count);
            }
        }

        for (const row of (rows || [])) {
            const bucket = this.bucketDate(row[dateField], this._timeGrain);
            if (!bucket) { skipped++; continue; }
            if (!buckets.has(bucket)) {
                // A loaded row whose bucket the server didn't list, or the no-server fallback path.
                seedBucket(bucket, useServer ? 0 : null);
            }
            const agg = buckets.get(bucket);
            const tal = tallies.get(bucket);
            // The server count is authoritative when present; only tally row counts when it isn't,
            // to avoid double-counting the loaded sample on top of the full-set count.
            if (!useServer) agg._rowCount++;
            numericKeys.forEach((k) => {
                const v = Number(row[k]);
                if (Number.isFinite(v)) agg[k] = (agg[k] || 0) + v;
            });
            modeKeys.forEach((k) => {
                const v = row[k];
                if (v === null || v === undefined || v === '') return;
                const sv = typeof v === 'object' ? JSON.stringify(v) : String(v);
                if (!tal[k]) tal[k] = {};
                tal[k][sv] = (tal[k][sv] || 0) + 1;
            });
        }

        // Resolve mode columns: pick the most-frequent value, suffixed with
        // " (+N)" if the bucket has more than one distinct value.
        for (const [bucketKey, agg] of buckets) {
            const tal = tallies.get(bucketKey) || {};
            modeKeys.forEach((k) => {
                const counts = tal[k];
                if (!counts) return;
                let best = null, bestCount = 0;
                let distinct = 0;
                for (const v of Object.keys(counts)) {
                    distinct++;
                    if (counts[v] > bestCount) { best = v; bestCount = counts[v]; }
                }
                if (best === null) return;
                agg[k] = distinct > 1 ? `${best} (+${distinct - 1})` : best;
            });
        }

        const result = Array.from(buckets.values())
            .sort((a, b) => String(a[dateField]).localeCompare(String(b[dateField])));

        // Defensive fallback: if every row's date failed to parse and we got
        // zero buckets out of >0 input rows, return the raw rows so the user
        // doesn't see an empty screen. They can switch back to "No grouping".
        if (result.length === 0 && rows && rows.length > 0) {
            // eslint-disable-next-line no-console
            console.warn('[crReportViewer] time grain produced 0 buckets from', rows.length,
                'rows on field', dateField, '— falling back to raw rows. Skipped:', skipped);
            return rows;
        }
        return result;
    }

    // ---- Group By selector + grouped table rendering ----
    // Visual grouping only: detail rows stay visible, clustered under a header
    // per distinct value of the chosen column. Distinct from the Time Grain
    // (which aggregates) and from server-side SQL GROUP BY (which collapses).

    get groupByOptions() {
        const opts = [{ label: 'No grouping', value: '' }];
        for (const c of this.columns) opts.push({ label: c.label, value: c.key });
        return opts;
    }

    // Two-level breakdown rows: outer grain bucket (with its total) then the field values nested
    // underneath, each with its server count. Built from the cross summary [{value1, value2, count}].
    crossGroupTableRows() {
        const dateColIdx = this.columns.findIndex((c) => c.key === this.effectiveDateField);
        const outerLabel = dateColIdx >= 0 ? this.columns[dateColIdx].label : 'Period';
        const fieldColIdx = this.columns.findIndex((c) => c.key === this._groupByKey);
        const innerLabel = fieldColIdx >= 0 ? this.columns[fieldColIdx].label : 'Group';
        const colspan = this.columns.length || 1;
        const outer = new Map();
        for (const g of this._crossGroups) {
            const o = g.value1 == null || g.value1 === '' ? '(empty)' : g.value1;
            const inner = g.value2 == null || g.value2 === '' ? '(empty)' : g.value2;
            if (!outer.has(o)) outer.set(o, { total: 0, rows: [] });
            const bucket = outer.get(o);
            bucket.total += g.count || 0;
            bucket.rows.push({ label: inner, count: g.count || 0 });
        }
        const outerKeys = Array.from(outer.keys()).sort((a, b) =>
            String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' }));
        const out = [];
        outerKeys.forEach((o, i) => {
            const bucket = outer.get(o);
            out.push({
                key: `cg-${i}`, isHeader: true, collapsible: false, rowClass: 'cr-group-header',
                groupColLabel: outerLabel, label: o, count: bucket.total, collapsed: true,
                toggleIcon: '', colspan
            });
            bucket.rows
                .sort((a, b) => b.count - a.count)
                .forEach((r, j) => {
                    out.push({
                        key: `cg-${i}-${j}`, isHeader: true, collapsible: false, rowClass: 'cr-group-header cr-group-subheader',
                        groupColLabel: innerLabel, label: r.label, count: r.count, collapsed: true,
                        toggleIcon: '', colspan
                    });
                });
        });
        return out;
    }

    get showGroupBy() {
        return this.columns.length > 0 && this.displayRows.length > 0;
    }

    // True whenever a Time Grain and a field Group By are both selected — drives a visible caption
    // so users can see the two controls are working together (not clearing each other).
    get isCombinedGrouping() {
        return this._timeGrain !== 'none' && !!this._groupByKey;
    }

    // Human caption for the active combined grouping, e.g. "Grouped by Month, then Record Type".
    get combinedGroupingLabel() {
        if (!this.isCombinedGrouping) return '';
        const grainNames = {
            day: 'Day', week: 'Week', month: 'Month', quarter: 'Quarter', year: 'Year'
        };
        const grain = grainNames[this._timeGrain] || this._timeGrain;
        const col = (this.columns || []).find((c) => c.key === this._groupByKey);
        const fieldLabel = (col && (col.label || col.key)) || this._groupByKey;
        return `Grouped by ${grain}, then ${fieldLabel}`;
    }

    get groupByValue() {
        return this._groupByKey || '';
    }

    get isGrouped() {
        return !!this._groupByKey && this.columns.some((c) => c.key === this._groupByKey);
    }

    handleGroupByChange(event) {
        const v = event.detail.value;
        this._groupByKey = v ? v : null;
        this._groupByTouched = true;
        this._collapsedGroups = new Set();
        this._serverGroups = [];
        this._crossGroups = [];
        // Full-dataset breakdown, server-side. If a Time Grain is also active, combine them into a
        // two-level breakdown (grain x field); otherwise a single-level field group.
        if (this._groupByKey && !this._aggregateResult) {
            if (this._timeGrain !== 'none' && this.effectiveDateField) {
                this.refreshCrossGroups();
            } else {
                this.refreshServerGroups();
            }
        } else if (this._timeGrain !== 'none' && !this._aggregateResult && this.effectiveDateField) {
            // Field Group By removed but a Time Grain is still active — restore the grain buckets.
            this.refreshTimeGrainBuckets();
        }
    }

    // The first DATE / DATETIME column, used as the default most-recent-first sort so a report
    // doesn't open on its oldest rows. Null when the report has no date column.
    _defaultDateSortKey() {
        const col = (this.columns || []).find((c) => {
            const dt = String((c && c.dataType) || '').toUpperCase();
            return dt === 'DATE' || dt === 'DATETIME';
        });
        return col ? col.key : null;
    }

    async refreshServerGroups() {
        if (!this._groupByKey || this._aggregateResult || !this.selectedReportId) {
            this._serverGroups = [];
            return;
        }
        try {
            const groups = await getGroupSummary({
                reportDefinitionId: this.selectedReportId,
                groupField: this._groupByKey,
                dashboardFiltersJson: this.buildCombinedFiltersJson(),
                granularity: null
            });
            this._serverGroups = groups || [];
        } catch (e) {
            // Fall back to grouping the loaded window if the summary call fails.
            this._serverGroups = [];
        }
    }

    toggleGroup(event) {
        const label = event.currentTarget.dataset.label;
        const next = new Set(this._collapsedGroups);
        if (next.has(label)) next.delete(label); else next.add(label);
        this._collapsedGroups = next;
    }

    collapseAllGroups() {
        const labels = (this.tableRows || []).filter((r) => r.isHeader).map((r) => r.label);
        this._collapsedGroups = new Set(labels);
    }

    expandAllGroups() {
        this._collapsedGroups = new Set();
    }

    // Unified list the table body iterates. Ungrouped: the flat display rows.
    // Grouped: a header pseudo-row before each group's (optionally hidden)
    // detail rows. Groups are ordered by label (numeric-aware). The grouping
    // value is read from the already-formatted display cell, so it matches what
    // the user sees and inherits the same empty-value ("—" → "(empty)") handling.
    get tableRows() {
        // Two-level breakdown: a Time Grain AND a field Group By together (e.g. month x Record
        // Type). Outer grain header with its total, field values nested underneath — all server
        // counts over the whole result set. While both are active we NEVER fall through to a
        // single-dimension view: doing so read to users as "the other grouping was cleared"
        // (looked like mutual exclusion). Instead show the cross rows, or an explicit notice.
        if (this.isCrossGrouped) {
            if (this._crossGroups && this._crossGroups.length) {
                return this.crossGroupTableRows();
            }
            const colspan = this.columns.length || 1;
            const notice = this._crossGroupPending
                ? 'Computing the combined Month × field breakdown…'
                : (this._crossGroupError || 'Combined grouping is unavailable.');
            return [{
                key: 'cg-notice', isHeader: true, collapsible: false,
                rowClass: 'cr-group-header', groupColLabel: 'Combined grouping',
                label: notice, count: '', colspan
            }];
        }
        // Time Grain (Group by month / day / week / …): one header per date bucket showing its
        // TRUE full-result-set count from the server. No page-local detail rows, so no empty or
        // duplicate buckets and no dependence on which page happens to be loaded. Isolate to a
        // single bucket (via a filter) to see the rows. Takes precedence over field grouping.
        if (this._timeGrain !== 'none' && this._timeGrainBuckets && this._timeGrainBuckets.length) {
            const dateColIdx = this.columns.findIndex((c) => c.key === this.effectiveDateField);
            const groupColLabel = dateColIdx >= 0 ? this.columns[dateColIdx].label : 'Period';
            const colspan = this.columns.length || 1;
            return [...this._timeGrainBuckets]
                .map((b) => ({ label: b.value == null || b.value === '' ? '(empty)' : b.value, count: b.count }))
                .sort((a, b) => String(a.label).localeCompare(String(b.label), undefined, { numeric: true, sensitivity: 'base' }))
                .map((g, i) => ({
                    key: `tg-${i}`,
                    isHeader: true,
                    collapsible: false,
                    rowClass: 'cr-group-header',
                    groupColLabel,
                    label: g.label,
                    count: g.count,
                    collapsed: true,
                    toggleIcon: '',
                    colspan
                }));
        }
        if (!this.isGrouped) {
            return this.displayRows.map((r) => ({ ...r, isHeader: false, rowClass: '' }));
        }
        const colIdx = this.columns.findIndex((c) => c.key === this._groupByKey);
        if (colIdx < 0) return this.displayRows.map((r) => ({ ...r, isHeader: false, rowClass: '' }));
        const groupColLabel = this.columns[colIdx].label;
        const colspan = this.columns.length;
        // Detail rows from the loaded window, keyed by the rendered group-cell value.
        const loaded = new Map();
        for (const row of this.displayRows) {
            const cell = row.cells[colIdx];
            const label = cell && !cell.isEmpty ? cell.value : '(empty)';
            if (!loaded.has(label)) loaded.set(label, []);
            loaded.get(label).push(row);
        }
        // Authoritative group list + true counts come from the server aggregate (whole result set).
        // Fall back to the loaded-window groups if the summary isn't available (call failed, or an
        // aggregate report that already returns whole).
        let groupList;
        if (this._serverGroups && this._serverGroups.length) {
            groupList = this._serverGroups.map((g) => ({
                label: g.value == null || g.value === '' ? '(empty)' : g.value,
                count: g.count
            }));
        } else {
            groupList = Array.from(loaded.keys()).map((k) => ({ label: k, count: loaded.get(k).length }));
        }
        // Safety net: if the server group list is in use, append any loaded-window group whose
        // label didn't match a server group (e.g. a date cell rendered differently than the
        // aggregate's formatted value) so its detail rows are never dropped from the view.
        if (this._serverGroups && this._serverGroups.length) {
            const serverLabels = new Set(groupList.map((g) => g.label));
            for (const label of loaded.keys()) {
                if (!serverLabels.has(label)) {
                    groupList.push({ label, count: loaded.get(label).length });
                }
            }
        }
        groupList.sort((a, b) =>
            String(a.label).localeCompare(String(b.label), undefined, { numeric: true, sensitivity: 'base' }));
        const out = [];
        groupList.forEach((g, i) => {
            const rows = loaded.get(g.label) || [];
            const collapsed = this._collapsedGroups.has(g.label);
            out.push({
                key: `grp-${i}`,
                isHeader: true,
                collapsible: true,
                rowClass: 'cr-group-header',
                groupColLabel,
                label: g.label,
                count: g.count,
                collapsed,
                toggleIcon: collapsed ? 'utility:chevronright' : 'utility:chevrondown',
                colspan
            });
            if (!collapsed) {
                for (const r of rows) out.push({ ...r, isHeader: false, rowClass: '' });
            }
        });
        return out;
    }

    get groupSummaryLabel() {
        if (!this.isGrouped) return '';
        const n = (this.tableRows || []).filter((r) => r.isHeader).length;
        return `${n} group${n === 1 ? '' : 's'}`;
    }

    // When a Group By is active, drive the chart by the same dimension: the
    // chart's x-axis becomes the group field, so it shows one bar/slice per
    // group value (summing a numeric measure if the report has one, else a
    // record count — c-cr-chart's own value-column detection handles both).
    // Null when ungrouped, so the chart keeps its existing auto-detect behavior.
    get chartGroupByField() {
        return this.isGrouped ? this._groupByKey : null;
    }

    get myRecordsPillClass() {
        return this._quickMyRecords ? 'quick-pill quick-pill--active' : 'quick-pill';
    }

    get activeOnlyPillClass() {
        return this._quickActiveOnly ? 'quick-pill quick-pill--active' : 'quick-pill';
    }

    get hasAnyQuickFilter() {
        return this.hasDateColumns || this.hasOwnerField || this.hasActiveField || this.displayRows.length > 0;
    }

    parseJsonSafe(text, fallback) {
        if (!text) return fallback;
        try { return JSON.parse(text); } catch (e) { return fallback; }
    }

    clearColumnFilter(event) {
        event.stopPropagation();
        const colKey = event.currentTarget.dataset.key;
        const cf = new Map(this._columnFilters); cf.delete(colKey); this._columnFilters = cf;
        const tf = new Map(this._columnTextFilters); tf.delete(colKey); this._columnTextFilters = tf;
        const st = new Map(this._columnSearchTerms); st.delete(colKey); this._columnSearchTerms = st;
        this._openFilterColumn = null;
        this.runWithToken(null);
    }

    clearAllFilters() {
        this._openFilterColumn = null;
        // Shares the same reset helper as handleReportChange / backToList.
        // Preserves _quickDateField (user's deliberate field pick from the
        // dropdown) — the user is clearing filters, not changing which
        // field date filters target.
        const preservedDateField = this._quickDateField;
        this.resetAllFilterState();
        this._quickDateField = preservedDateField;
        this.runWithToken(null);
    }

    get hasAnyActiveFilter() {
        return this._columnFilters.size > 0 || this._columnTextFilters.size > 0;
    }

    // Phase 3 v11: row-count getters so the user can see EXACTLY what the
    // filter affected. Important context: the filter only operates on rows
    // currently loaded in the browser (typically one server page). Reports
    // with more rows than the page size need a deliberate "Load more" or a
    // larger reportPageSize to filter across the full result set.
    get loadedRowCount() {
        return (this._unfilteredRows || []).length;
    }
    get visibleRowCount() {
        return (this.displayRows || []).length;
    }
    get hasMoreServerRows() {
        return !!this.nextPageToken;
    }
    get rowCountLabel() {
        const shown = this.visibleRowCount;
        const total = this._totalRowCount;
        const matching = this.hasAnyActiveFilter ? ' matching' : '';
        // When we know the true total, say "100 of 14,166" so page 1 never reads as the whole set.
        if (total != null && total > shown) {
            return `Showing ${shown} of ${total.toLocaleString()}${matching} rows — Next Page or Export for the rest`;
        }
        if (total != null) {
            return `Showing all ${total.toLocaleString()}${matching} row${total === 1 ? '' : 's'}`;
        }
        // Total not loaded yet (or the count call failed) — fall back to the prior wording.
        return this.hasMoreServerRows
            ? `Showing ${shown}${matching} on this page — more available, click Next Page`
            : `Showing ${shown}${matching} row${shown === 1 ? '' : 's'}`;
    }

    get activeFilterSummary() {
        const parts = [];
        for (const [colKey, allowed] of this._columnFilters) {
            const col = this.columns.find((c) => c.key === colKey);
            parts.push(`${col?.label || colKey} (${allowed.size})`);
        }
        return parts.join(' · ');
    }

    // Phase 3 v9: pair "Name" columns with their matching "Id" columns so a
    // Name cell (e.g., "Acme Inc" in Account_Name__c) becomes a link to the
    // parent record (Account_Id__c). Recognizes four patterns:
    //
    //   Name                          → Id                    (standard SF row's own Id)
    //   <Object>.Name                 → <Object>Id or <Object>.Id  (relationship traversal)
    //   <X>_Full_Name__c              → <X>_Id__c              (PRM Fact convention)
    //   <X>_Name__c                   → <X>_Id__c              (custom Text Id pattern)
    //   <X>Name                       → <X>Id                  (Standard SF PascalCase, e.g. AccountName)
    //
    // Returns a Map<nameColumnKey, idColumnKey>. Per-row Id validation happens
    // at cell-render time so empty Id cells don't produce broken links.
    looksLikeSfId(s) {
        return /^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(s);
    }

    buildLinkedColumnMap(columns) {
        const keys = new Set((columns || []).map((c) => c.key).filter(Boolean));
        const map = new Map();
        for (const col of (columns || [])) {
            const key = col.key;
            if (!key) continue;
            const candidates = [];
            if (key === 'Name') candidates.push('Id');
            if (key.endsWith('.Name')) {
                const obj = key.slice(0, -5);
                candidates.push(`${obj}Id`, `${obj}.Id`);
            }
            const fullNameMatch = key.match(/^(.+)_Full_Name__c$/i);
            if (fullNameMatch) candidates.push(`${fullNameMatch[1]}_Id__c`);
            const customNameMatch = key.match(/^(.+)_Name__c$/i);
            if (customNameMatch) candidates.push(`${customNameMatch[1]}_Id__c`);
            const pascalMatch = key.match(/^(.+)Name$/);
            if (pascalMatch && !key.endsWith('_Name') && key !== 'Name') {
                candidates.push(`${pascalMatch[1]}Id`);
            }
            for (const candidate of candidates) {
                if (keys.has(candidate)) {
                    map.set(key, candidate);
                    break;
                }
            }
        }
        return map;
    }

    // Phase 3 v8: detect Salesforce record IDs in cell values and emit a
    // /lightning/r/<id>/view link so the user can drill from a report row
    // to the underlying record. Two detection paths:
    //   1. Strong signal: the column's dataType is ID or REFERENCE (we know
    //      from describe). Always link.
    //   2. Weak signal: value looks like a 15/18-char alphanumeric SF Id.
    //      Catches custom text fields like Provider_Id__c that store IDs
    //      as strings.
    //
    // Link opens in a new tab so the user doesn't lose their report context.
    detectRecordLink(value, column) {
        if (typeof value !== 'string' || !value) return null;
        const strongType = column && column.dataType
            ? String(column.dataType).toUpperCase()
            : '';
        if (strongType === 'ID' || strongType === 'REFERENCE') {
            return `/lightning/r/${encodeURIComponent(value)}/view`;
        }
        // 15-char or 18-char alphanumeric ID heuristic. The 18-char form has
        // a 3-char checksum suffix but we don't validate it — false positives
        // on cells that happen to be 15/18-char alphanumerics are rare and
        // harmless (the link just goes to a 404 record view).
        if (/^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(value)) {
            return `/lightning/r/${encodeURIComponent(value)}/view`;
        }
        return null;
    }

    formatCellValue(value) {
        if (value === null || value === undefined) return '';
        if (typeof value !== 'object') return value;
        // Address: { street, city, state, postalCode, country, geocodeAccuracy, latitude, longitude }
        if ('street' in value || 'postalCode' in value || 'city' in value) {
            const parts = [];
            if (value.street) parts.push(value.street);
            const cityStateZip = [value.city, value.state, value.postalCode].filter(Boolean).join(' ').trim();
            if (cityStateZip) parts.push(cityStateZip);
            if (value.country) parts.push(value.country);
            return parts.join(', ');
        }
        // Location: { latitude, longitude }
        if ('latitude' in value && 'longitude' in value && Object.keys(value).length <= 3) {
            const lat = value.latitude;
            const lng = value.longitude;
            return lat != null && lng != null ? `${lat}, ${lng}` : '';
        }
        // Name (Person Account or User): { firstName, lastName, salutation, ... }
        if ('firstName' in value || 'lastName' in value) {
            return [value.salutation, value.firstName, value.middleName, value.lastName, value.suffix]
                .filter(Boolean).join(' ').trim();
        }
        // Unknown shape — JSON for visibility instead of "[object Object]".
        try { return JSON.stringify(value); } catch (e) { return ''; }
    }

    applyResultSort() {
        if (!this.resultSortKey) return;
        const key = this.resultSortKey;
        const dirMultiplier = this.resultSortDir === 'asc' ? 1 : -1;
        // displayRows holds the precomputed cell-array; sort by the matching cell value
        // so we honor the on-screen rendered order (works for tabular and aggregate).
        const cellIndex = this.columns.findIndex((c) => c.key === key);
        if (cellIndex < 0) return;
        const sorted = [...this.displayRows].sort((a, b) => {
            const av = a.cells[cellIndex]?.value;
            const bv = b.cells[cellIndex]?.value;
            if (av == null && bv == null) return 0;
            if (av == null) return 1;
            if (bv == null) return -1;
            const an = typeof av === 'number' ? av : Number(av);
            const bn = typeof bv === 'number' ? bv : Number(bv);
            if (!Number.isNaN(an) && !Number.isNaN(bn) && av !== '' && bv !== '') {
                return (an - bn) * dirMultiplier;
            }
            return String(av).localeCompare(String(bv)) * dirMultiplier;
        });
        this.displayRows = sorted;
        this.columns = this.columns.map((c) => ({
            ...c,
            sortIndicator: c.key === key ? (this.resultSortDir === 'asc' ? ' ▲' : ' ▼') : ''
        }));
    }

    handleReportChange(event) {
        this.selectedReportId = event.detail.value;
        this.dashboardFiltersJson = null;
        this.sourceDashboardId = null;
        this.sourceDashboardName = null;
        this.nextPageToken = null;
        this.columns = [];
        this.displayRows = [];
        this._unfilteredRows = [];
        this._openFilterColumn = null;
        // QA round 3: reset ALL filter state when switching reports, not
        // just column filters. Previously only _columnFilters was cleared;
        // the Quick Filter state (date preset, my records, active only,
        // selected preset, time grain) and column text filters survived
        // the report switch. When the new report didn't have the same
        // date field, the persisted clause caused SOQL errors like
        // "Relationship not found: Task in Task.Date_Meeting_Call__c".
        this.resetAllFilterState();
    }

    // Shared reset used by handleReportChange (full reset on new report),
    // clearAllFilters (user-triggered), and backToList (return-to-catalog).
    // Resets everything that affects what gets sent in dashboardFiltersJson
    // or aggregated client-side.
    resetAllFilterState() {
        this._columnFilters = new Map();
        this._columnTextFilters = new Map();
        this._columnFilterModes = new Map();
        this._columnSearchTerms = new Map();
        // Quick Filter state — picked up by quickFilterClauses getter
        this._quickDatePreset = 'all';
        this._quickDateField = null;
        this._quickDateCustomStart = null;
        this._quickDateCustomEnd = null;
        this._quickMyRecords = false;
        this._quickActiveOnly = false;
        this._quickTopN = '100';
        // Preset state
        this._selectedPresetKey = '';
        this._presetExtraClauses = [];
        // Time grain (display transform, but worth resetting for cleanliness)
        this._timeGrain = 'none';
        // Group By (display transform) — cleared so a new report re-applies its
        // own saved default (or none) instead of inheriting the prior report's.
        this._groupByKey = null;
        this._collapsedGroups = new Set();
        this._groupByTouched = false;
    }

    async run() {
        await this.runWithToken(null);
    }

    async nextPage() {
        await this.runWithToken(this.nextPageToken);
    }

    async runWithToken(token, preserveSort = false) {
        if (!this.selectedReportId) {
            return;
        }
        this.loading = true;
        try {
            // Phase 3 v12: always send the combined filter JSON (URL-state
            // dashboard filters + interactive column filters) to the server.
            // This makes column filters apply across the ENTIRE result set, not
            // just the loaded page. Pagination preserves filters automatically
            // because Next Page calls this same code path.
            //
            // When a user column sort is active on a tabular report, push the sort to the server
            // so ORDER BY spans the whole result set instead of just the loaded page (aggregate
            // reports return whole, so they keep the cheap client-side sort).
            const serverSort = preserveSort && !!this.resultSortKey && !this._aggregateResult;
            this._serverSorted = serverSort;
            const result = serverSort
                ? await runReportByIdSorted({
                      reportDefinitionId: this.selectedReportId,
                      pageToken: token,
                      pageSize: this.effectivePageSize,
                      dashboardFiltersJson: this.buildCombinedFiltersJson(),
                      sortField: this.resultSortKey,
                      sortDir: this.resultSortDir
                  })
                : await runReportById({
                      reportDefinitionId: this.selectedReportId,
                      pageToken: token,
                      pageSize: this.effectivePageSize,
                      dashboardFiltersJson: this.buildCombinedFiltersJson()
                  });
            this._aggregateResult = result.aggregateResult === true;
            // sortIndicator on every column drives the ▲/▼ glyph in the header.
            const glyph = this.resultSortDir === 'asc' ? ' ▲' : ' ▼';
            this.columns = (result.columns || []).map((c) => ({
                ...c,
                sortIndicator: serverSort && c.key === this.resultSortKey ? glyph : ''
            }));
            this._unfilteredRows = result.rows || [];
            // Do NOT reset _columnFilters here — the user may be paginating
            // through a filtered set, or running with active filters. They're
            // only reset on handleReportChange or backToList (fresh report).
            this._openFilterColumn = null;
            this.rebuildDisplayRowsAndChart();
            // Reset sort on a genuinely fresh load. A sort re-run (preserveSort) keeps the sort;
            // pagination keeps sort state because the user explicitly chose it.
            if (token == null && !preserveSort) {
                this.resultSortKey = null;
                this.resultSortDir = 'asc';
                // Fetch the true total for the "Showing X of Y" label (filters may have changed).
                this.refreshTotalCount();
                // Apply the report's saved default grouping (Definition_JSON
                // "viewGroupBy" field path, echoed by runReportById) unless the
                // user has already chosen a Group By for this report.
                if (!this._groupByTouched) {
                    const def = result.viewGroupBy;
                    this._groupByKey = (def && this.columns.some((c) => c.key === def)) ? def : null;
                    this._collapsedGroups = new Set();
                }
                // Default a tabular, ungrouped report with a date column to most-recent-first, so
                // page 1 doesn't land on the oldest rows (record-Id order) and look like the later
                // dates are missing. The initial unsorted load above was only needed to learn the
                // columns; re-run server-side sorted. Skips when the user turned off the default.
                const dateKey = this._defaultDateSortKey();
                if (!this._aggregateResult && !this._groupByKey && dateKey) {
                    this.resultSortKey = dateKey;
                    this.resultSortDir = 'desc';
                    return this.runWithToken(null, true);
                }
            } else if (!serverSort) {
                this.applyResultSort();
            }
            this.nextPageToken = result.nextPageToken;
            // Deep-clone for the chart wrapper. Chart.js mutates internally and LWC's
            // reactive proxy wraps these objects with a non-extensible flag that breaks
            // Chart.js's data updates if we pass the live arrays.
            this.chartResult = JSON.parse(JSON.stringify({
                columns: result.columns || [],
                rows: result.rows || []
            }));
            this.chartType = result.chartType || result.chart?.type || this.chartType || 'bar';
            // Keep the full-dataset group breakdown in sync with the current filters when grouped
            // (covers fresh loads, filter changes, and a report's saved default grouping).
            // Keep the server-side breakdowns in sync with the current filters. When both a Time
            // Grain and a field Group By are active, use the two-level cross breakdown instead.
            if (this.isCrossGrouped) {
                this._serverGroups = [];
                this._timeGrainBuckets = [];
                this.refreshCrossGroups();
            } else {
                this._crossGroups = [];
                if (this._groupByKey && !this._aggregateResult) {
                    this.refreshServerGroups();
                } else {
                    this._serverGroups = [];
                }
                if (this._timeGrain !== 'none' && !this._aggregateResult && this.effectiveDateField) {
                    this.refreshTimeGrainBuckets();
                } else {
                    this._timeGrainBuckets = [];
                }
            }
        } catch (error) {
            // QA-A1: clear stale data on error so the user sees the failure.
            // Previously, _unfilteredRows kept its previous value when the
            // server rejected a query (e.g., LIKE pattern too long), making
            // the new filter look like a successful no-op. Better to show an
            // empty table + the toast, so the user knows to fix their input.
            this._unfilteredRows = [];
            this.displayRows = [];
            this.toastError(error);
        } finally {
            this.loading = false;
        }
    }

    handleEdit() {
        if (!this.selectedReportId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Custom_Report_Builder' },
            state: { c__reportId: this.selectedReportId }
        });
    }

    async handleDelete() {
        if (!this.selectedReportId) return;
        const selectedOption = this.reportOptions.find((o) => o.value === this.selectedReportId);
        const reportLabel = selectedOption?.label || 'this report';
        const proceed = await LightningConfirm.open({
            label: 'Delete report',
            theme: 'warning',
            message: `Permanently delete "${reportLabel}"? This cannot be undone.`
        });
        if (!proceed) return;
        const deletedId = this.selectedReportId;
        this.loading = true;
        try {
            await deleteReport({ reportDefinitionId: deletedId });
            this.reportOptions = this.reportOptions.filter((o) => o.value !== deletedId);
            this.selectedReportId = null;
            this.columns = [];
            this.displayRows = [];
            this.nextPageToken = null;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Report deleted',
                message: reportLabel,
                variant: 'success'
            }));
        } catch (error) {
            this.toastError(error);
        } finally {
            this.loading = false;
        }
    }

    async exportReport() {
        try {
            const exportId = this.hasDashboardFilters
                ? await enqueueFilteredExport({
                    reportDefinitionId: this.selectedReportId,
                    dashboardFiltersJson: this.dashboardFiltersJson
                })
                : await enqueueExport({ reportDefinitionId: this.selectedReportId });
            this.activeTab = 'exports';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Export queued',
                message: 'Your CSV is being prepared. The Download button will appear here when it\'s ready.',
                variant: 'success'
            }));
            this._exportPollAttempts = 0;
            this.exportPollLimitReached = false;
            await this.loadExportQueue();
            // Suppress unused-var lint while keeping the call signature stable.
            void exportId;
        } catch (error) {
            this.toastError(error);
        }
    }

    async handleExportQueueActive() {
        this.activeTab = 'exports';
        await this.loadExportQueue();
    }

    async refreshExportQueue() {
        this._exportPollAttempts = 0;
        this.exportPollLimitReached = false;
        await this.loadExportQueue();
    }

    // Phase 1 UAT: resume polling after the export-queue auto-poll cap.
    // Identical effect to refreshExportQueue() — separate name keeps the
    // banner's call site obvious in the template.
    async resumeExportPolling() {
        await this.refreshExportQueue();
    }

    get hasActiveExports() {
        return this.exportRows.some((row) => row.isActive);
    }

    async loadExportQueue(showSpinner = true) {
        if (showSpinner) {
            this.exportLoading = true;
        }
        try {
            const rows = await listRecentExports({ reportDefinitionId: null, maxResults: EXPORT_QUEUE_LIMIT });
            this.exportRows = (rows || []).map((row) => this.normalizeExportRow(row));
            if (this.exportRows.some((row) => row.isActive)) {
                this.startExportPolling();
            } else {
                this.stopExportPolling();
            }
        } catch (error) {
            this.toastError(error);
            this.stopExportPolling();
        } finally {
            if (showSpinner) {
                this.exportLoading = false;
            }
        }
    }

    normalizeExportRow(row) {
        const status = row.status || 'Unknown';
        const normalizedStatus = status.toLowerCase();
        const isComplete = status === 'Complete' && !!row.contentVersionId;
        return {
            ...row,
            statusClass: `status-pill status-${normalizedStatus}`,
            isActive: status === 'Queued' || status === 'Running',
            isComplete,
            recordUrl: `/lightning/r/Report_Export__c/${row.exportId}/view`,
            downloadUrl: row.contentVersionId ? `/sfc/servlet.shepherd/version/download/${row.contentVersionId}` : null
        };
    }

    startExportPolling() {
        if (this._exportPollTimer || this.exportPollLimitReached) {
            return;
        }
        this._exportPollTimer = window.setInterval(async () => {
            this._exportPollAttempts += 1;
            if (this._exportPollAttempts > EXPORT_POLL_MAX_ATTEMPTS) {
                this.exportPollLimitReached = true;
                this.stopExportPolling(false);
                return;
            }
            await this.loadExportQueue(false);
        }, EXPORT_POLL_INTERVAL_MS);
    }

    stopExportPolling(reset = true) {
        if (this._exportPollTimer) {
            window.clearInterval(this._exportPollTimer);
            this._exportPollTimer = null;
        }
        if (reset) {
            this._exportPollAttempts = 0;
            this.exportPollLimitReached = false;
        }
    }

    applyIncomingState(state) {
        const reportId = state.c__reportId;
        const filters = this.decodeStateValue(state.c__dashboardFilters);
        const dashboardId = state.c__dashboardId || null;
        const dashboardName = this.decodeStateValue(state.c__dashboardName) || null;
        const autoRun = state.c__autoRun === 'true';
        const stateKey = `${reportId || ''}|${filters || ''}|${dashboardId || ''}|${autoRun}`;

        if (!reportId || stateKey === this._lastStateKey) {
            return;
        }

        this._lastStateKey = stateKey;
        this.selectedReportId = reportId;
        this.dashboardFiltersJson = filters || null;
        this.sourceDashboardId = dashboardId;
        this.sourceDashboardName = dashboardName;
        this.nextPageToken = null;
        this.columns = [];
        this.displayRows = [];

        if (autoRun) {
            this._pendingAutoRun = true;
            if (this.reportOptions.length > 0) {
                this._pendingAutoRun = false;
                this.run();
            }
        }
    }

    decodeStateValue(value) {
        if (!value) return null;
        try {
            return decodeURIComponent(value);
        } catch {
            return value;
        }
    }

    applyConfiguredReport() {
        if (this.selectedReportId) {
            return;
        }
        const configuredId = (this.defaultReportId || '').trim();
        const configuredName = (this.defaultReportName || '').trim().toLowerCase();
        let matchingOption;
        if (configuredId) {
            matchingOption = this.reportOptions.find((option) => option.value === configuredId);
            if (!matchingOption) {
                matchingOption = { label: configuredId, value: configuredId };
                this.reportOptions = [matchingOption, ...this.reportOptions];
            }
        } else if (configuredName) {
            matchingOption = this.reportOptions.find((option) => (option.label || '').trim().toLowerCase() === configuredName);
        }
        if (!matchingOption) {
            return;
        }
        this.selectedReportId = matchingOption.value;
        if (this.toBoolean(this.autoRunOnLoad)) {
            this._pendingAutoRun = true;
        }
    }

    toBoolean(value) {
        return value === true || value === 'true';
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