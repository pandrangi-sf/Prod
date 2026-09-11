import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import runReportById from '@salesforce/apex/CR_QueryEngine.runReportById';
import aiIsEnabled from '@salesforce/apex/CR_AIService.isEnabled';
import recommendChartType from '@salesforce/apex/CR_AIService.recommendChartType';
import { scoreChartTypes, fitIcon, fitRank } from 'c/crChartAdvisor';

const PREVIEW_ROW_LIMIT = 10;
const PREVIEW_DEBOUNCE_MS = 250;

// Chart-type icon grid. Mirrors the Display As icons in the native dialog.
const CHART_TYPES = [
    { value: 'bar',        label: 'Bar',            icon: 'utility:chart' },
    { value: 'horizontal', label: 'Horizontal Bar', icon: 'utility:rotate' },
    { value: 'line',       label: 'Line',           icon: 'utility:trend' },
    { value: 'area',       label: 'Area',           icon: 'utility:trend' },
    { value: 'donut',      label: 'Donut',          icon: 'utility:pie_chart' },
    { value: 'pie',        label: 'Pie',            icon: 'utility:pie_chart' },
    { value: 'metric',     label: 'Metric',         icon: 'utility:number_input' },
    { value: 'gauge',      label: 'Gauge',          icon: 'utility:speedometer' },
    { value: 'heatmap',    label: 'Heatmap',        icon: 'utility:metrics' },
    { value: 'treemap',    label: 'Treemap',        icon: 'utility:layers' },
    { value: 'table',      label: 'Table',          icon: 'utility:table' },
    { value: 'auto',       label: 'Auto',           icon: 'utility:dashboard_ext' }
];

const LEGEND_OPTIONS = [
    { label: 'Right',  value: 'right' },
    { label: 'Bottom', value: 'bottom' },
    { label: 'Top',    value: 'top' },
    { label: 'Hidden', value: 'none' }
];

const DISPLAY_UNIT_OPTIONS = [
    { label: 'Auto',           value: 'auto' },
    { label: 'Shortened',      value: 'shortened' },
    { label: 'Full',           value: 'full' },
    { label: 'Thousands (K)',  value: 'thousands' },
    { label: 'Millions (M)',   value: 'millions' }
];

const SORT_DIRECTION_OPTIONS = [
    { label: 'Ascending',  value: 'asc' },
    { label: 'Descending', value: 'desc' }
];

// Table totals footer aggregations (table tiles only). Kept in lockstep with
// the aggregator in crDashboardViewer (computeTableTotals).
const TABLE_TOTAL_AGG_OPTIONS = [
    { label: 'Sum',     value: 'sum' },
    { label: 'Average', value: 'avg' },
    { label: 'Count',   value: 'count' },
    { label: 'Min',     value: 'min' },
    { label: 'Max',     value: 'max' }
];

// Conditional-formatting operators. 'between' reveals a second value input;
// the rest use a single value. Kept in lockstep with the matcher in
// crDashboardViewer (evaluateConditionalFormats).
const CF_OPERATOR_OPTIONS = [
    { label: '=',        value: '=' },
    { label: '≠ (not equal)', value: '!=' },
    { label: '>',        value: '>' },
    { label: '≥',   value: '>=' },
    { label: '<',        value: '<' },
    { label: '≤',   value: '<=' },
    { label: 'between',  value: 'between' },
    { label: 'contains', value: 'contains' }
];

const THEME_OPTIONS = [
    { label: 'Light (Dashboard default)', value: 'inherit' },
    { label: 'Light',                     value: 'Light' },
    { label: 'Dark',                      value: 'Dark' }
];

// KPI target "good direction": up = higher value is better (default),
// down = lower value is better (cost / error-rate KPIs). Drives the variance
// arrow + color in the viewer (buildMetricModel / buildGaugeModel).
const KPI_DIRECTION_OPTIONS = [
    { label: 'Higher is better', value: 'up' },
    { label: 'Lower is better',  value: 'down' }
];

// Period-over-period comparison (metric / gauge tiles). The author picks a
// date field off the report's columns and a period grain; the viewer runs two
// scoped queries (current vs prior period) and shows the delta. Kept in
// lockstep with the boundary math in crDashboardViewer (computePeriodBounds).
const PC_PERIOD_OPTIONS = [
    { label: 'Week',    value: 'week' },
    { label: 'Month',   value: 'month' },
    { label: 'Quarter', value: 'quarter' },
    { label: 'Year',    value: 'year' }
];

export default class CrDashboardWidgetConfig extends LightningElement {
    // Inputs from parent
    @api reportId;
    @api reportName;
    @api initialViz;       // Object: existing visualization JSON (for edit-mode)
    @api isEditMode = false;
    // Phase D: kind=chart (default) | text | image. Selects the form body
    // and the persisted viz.type discriminator.
    @api widgetKind = 'chart';

    // Working state
    @track type = 'bar';
    @track title = '';
    @track subtitle = '';
    @track footer = '';
    @track legendPosition = 'right';
    @track displayUnits = 'auto';
    @track decimalPlaces = '';
    @track sortBy = '';
    @track sortDirection = 'desc';
    @track maxGroups = 100;
    @track widgetTheme = 'inherit';
    @track showValues = true;
    @track customLink = '';
    // Phase E1: explicit axis selections (column keys). Empty arrays /
    // empty string mean "auto-detect from the first numeric / first
    // categorical column" — same as before Phase E.
    @track yAxisFields = [];
    @track xAxisField = '';
    // Phase F2: when true, the widget defers chart/table configuration to
    // the report's defaults — the override fields below are locked in the
    // dialog and ignored at render time. Saved as flags on the viz JSON
    // so the user's intent survives reload.
    @track useChartFromReport = false;
    @track useTableFromReport = false;

    // Conditional formatting rules for table tiles. Each entry:
    //   { id, column, operator, value, valueTo, background, text }
    // `id` is a client-only key for the for:each / remove handlers; it is
    // stripped before the rules are emitted on the viz JSON.
    @track conditionalFormats = [];
    _cfSeq = 0;

    // Table totals footer rules (table tiles only). Each entry:
    //   { id, column, agg }
    // `id` is a client-only key for the for:each / remove handlers; it is
    // stripped before the rules are emitted on the viz JSON.
    @track tableTotals = [];
    _ttSeq = 0;

    // KPI target + threshold status colors (metric / gauge tiles only).
    //   kpiTarget        — optional numeric goal (string while edited).
    //   kpiGoodDirection — 'up' (higher is better, default) | 'down'.
    //   kpiThresholds    — ordered status bands { id, upTo, color }. `id` is a
    //                      client-only key for the for:each / remove handlers; it
    //                      is stripped before emit. The viewer colors the value by
    //                      the FIRST band whose upTo >= value (ascending).
    @track kpiTarget = '';
    @track kpiGoodDirection = 'up';
    @track kpiThresholds = [];
    _kpiSeq = 0;

    // Period-over-period comparison (metric / gauge tiles only).
    //   pcEnabled   — author toggle. Only emitted when ON and a date field set.
    //   pcDateField — column key off the report's columns the date range filters.
    //   pcPeriod    — 'week' | 'month' | 'quarter' | 'year'.
    @track pcEnabled = false;
    @track pcDateField = '';
    @track pcPeriod = 'month';

    // Live preview state
    @track previewLoading = false;
    @track previewError = null;
    @track previewResult = null;

    // Available sort fields (from preview's column metadata)
    @track availableColumns = [];

    // Phase J1: AI suggestion hint. Wired only when the feature is enabled,
    // fetched lazily on chart-type icon-grid mouse-enter so we don't burn
    // a callout per dialog open.
    @track _aiEnabled = false;
    @track _aiSuggestion = null;   // { chartType, reason }
    @track _aiFetched = false;
    @wire(aiIsEnabled)
    wiredAiEnabled({ data, error }) {
        if (error) {
            // eslint-disable-next-line no-console
            console.warn('CR_AIService.isEnabled wire error (widget config)', error);
            return;
        }
        this._aiEnabled = !!data;
    }

    // Phase D: text + image working state.
    @track richText = '';
    @track imageUrl = '';
    @track imageAlt = '';
    @track imageFit = 'contain';
    imageFitOptions = [
        { label: 'Contain (fit inside tile)', value: 'contain' },
        { label: 'Cover (fill tile, may crop)', value: 'cover' },
        { label: 'Fill (stretch)',             value: 'fill' }
    ];

    // Phase E2: LWC widget working state.
    @track lwcName = 'crDashboardKpiTileWidget';
    @track lwcPropsJson = '{}';
    @track lwcPropsError = '';

    // Hardcoded registry of LWCs allowed in the dashboard. Keep in lockstep
    // with the if:true switch in the builder/viewer tile bodies — adding a
    // new entry here without a matching renderer means the tile shows
    // "Unknown widget".
    lwcRegistry = [
        {
            value: 'crDashboardKpiTileWidget',
            label: 'KPI Tile',
            description: 'Static KPI card with headline, value, optional subtitle and tone color.',
            sampleProps: '{\n  "headline": "Pipeline",\n  "value": "$1.2M",\n  "subtitle": "Q2 to date",\n  "tone": "positive"\n}'
        },
        {
            value: 'crDashboardClockWidget',
            label: 'Clock',
            description: 'Live clock in any IANA timezone. Re-renders every second.',
            sampleProps: '{\n  "timezone": "America/New_York",\n  "format": "12h"\n}'
        }
    ];

    chartTypes = CHART_TYPES;
    legendOptions = LEGEND_OPTIONS;
    displayUnitOptions = DISPLAY_UNIT_OPTIONS;
    sortDirectionOptions = SORT_DIRECTION_OPTIONS;
    themeOptions = THEME_OPTIONS;
    cfOperatorOptions = CF_OPERATOR_OPTIONS;
    ttAggOptions = TABLE_TOTAL_AGG_OPTIONS;
    kpiDirectionOptions = KPI_DIRECTION_OPTIONS;
    pcPeriodOptions = PC_PERIOD_OPTIONS;

    _previewTimer = null;
    _disposed = false;

    connectedCallback() {
        const viz = this.initialViz || {};
        // Phase D: derive widgetKind from existing viz.type when editing, so
        // edit-mode lands on the right form even if parent didn't set it.
        if (this.isEditMode && viz.type) {
            if (viz.type === 'richtext') this.widgetKind = 'text';
            else if (viz.type === 'image') this.widgetKind = 'image';
            else if (viz.type === 'lwc') this.widgetKind = 'lwc';
            else this.widgetKind = 'chart';
        }

        if (this.widgetKind === 'text') {
            this.richText = viz.html || '';
            this.title = viz.title || 'Text';
        } else if (this.widgetKind === 'image') {
            this.imageUrl = viz.url || '';
            this.imageAlt = viz.altText || '';
            this.imageFit = viz.fit || 'contain';
            this.title = viz.title || 'Image';
        } else if (this.widgetKind === 'lwc') {
            // Honor the saved LWC name only if it's still in the registry —
            // a previously-saved name that's no longer allowlisted falls
            // back to the first registry entry, with a toast on apply.
            const inRegistry = (this.lwcRegistry || []).some((e) => e.value === viz.lwcName);
            this.lwcName = inRegistry ? viz.lwcName : (this.lwcRegistry[0]?.value || '');
            try {
                this.lwcPropsJson = viz.widgetProps
                    ? JSON.stringify(viz.widgetProps, null, 2)
                    : '{}';
            } catch {
                this.lwcPropsJson = '{}';
            }
            this.title = viz.title || (this.selectedLwcEntry?.label || 'Component');
        } else {
            this.type = viz.type || 'bar';
            this.title = viz.title || this.reportName || '';
            this.subtitle = viz.subtitle || '';
            this.footer = viz.footer || '';
            this.legendPosition = viz.legendPosition || 'right';
            this.displayUnits = viz.displayUnits || 'auto';
            this.decimalPlaces = viz.decimalPlaces != null ? String(viz.decimalPlaces) : '';
            this.sortBy = viz.sortBy || '';
            this.sortDirection = viz.sortDirection || 'desc';
            this.maxGroups = Number.isFinite(viz.maxGroups) ? viz.maxGroups : 100;
            this.widgetTheme = viz.theme || 'inherit';
            this.showValues = viz.showValues !== false;
            this.customLink = viz.customLink || '';
            this.yAxisFields = Array.isArray(viz.yAxis) ? viz.yAxis.slice() : [];
            this.xAxisField = viz.xAxis || '';
            this.useChartFromReport = !!viz.useChartFromReport;
            this.useTableFromReport = !!viz.useTableFromReport;
            // Conditional formatting (table tiles). Hydrate from the saved
            // viz blob, assigning client-only ids for the repeatable list.
            this.conditionalFormats = Array.isArray(viz.conditionalFormats)
                ? viz.conditionalFormats.map((r) => ({
                    id: `cf-${this._cfSeq++}`,
                    column: r && r.column ? r.column : '',
                    operator: r && r.operator ? r.operator : '=',
                    value: r && r.value != null ? String(r.value) : '',
                    valueTo: r && r.valueTo != null ? String(r.valueTo) : '',
                    background: r && r.background ? r.background : '#FFFFFF',
                    text: r && r.text ? r.text : '#000000'
                }))
                : [];

            // Table totals footer (table tiles). Hydrate from the saved viz
            // blob, assigning client-only ids for the repeatable list.
            this.tableTotals = Array.isArray(viz.tableTotals)
                ? viz.tableTotals.map((t) => ({
                    id: `tt-${this._ttSeq++}`,
                    column: t && t.column ? t.column : '',
                    agg: t && t.agg ? t.agg : 'sum'
                }))
                : [];

            // KPI target + thresholds (metric / gauge tiles). Hydrate from the
            // saved blob; assign client-only ids to the repeatable threshold list.
            this.kpiTarget = viz.kpiTarget != null && viz.kpiTarget !== ''
                ? String(viz.kpiTarget)
                : '';
            this.kpiGoodDirection = viz.kpiGoodDirection === 'down' ? 'down' : 'up';
            this.kpiThresholds = Array.isArray(viz.kpiThresholds)
                ? viz.kpiThresholds.map((t) => ({
                    id: `kpi-${this._kpiSeq++}`,
                    upTo: t && t.upTo != null ? String(t.upTo) : '',
                    color: t && t.color ? t.color : '#2E844A'
                }))
                : [];

            // Period-over-period comparison (metric / gauge). Hydrate from the
            // saved blob; absent / malformed -> defaults (disabled).
            const pc = viz.periodComparison;
            this.pcEnabled = !!(pc && pc.enabled);
            this.pcDateField = pc && pc.dateField ? pc.dateField : '';
            this.pcPeriod = pc && pc.period ? pc.period : 'month';

            if (this.reportId) {
                this.loadPreview();
            }
        }
    }

    disconnectedCallback() {
        this._disposed = true;
        if (this._previewTimer) {
            clearTimeout(this._previewTimer);
            this._previewTimer = null;
        }
    }

    // ---- Computed ----

    // Chart-type cards. Each card carries the Chart Advisor's verdict
    // (recommended / available / notFitting) so users see which chart types
    // suit the loaded data before clicking. Sorted recommended-first so good
    // picks appear earliest in the grid.
    get chartTypeCards() {
        const columns = this.previewResult?.columns || [];
        const rows = this.previewResult?.rows || [];
        const verdictByType = new Map();
        if (columns.length > 0) {
            for (const v of scoreChartTypes(columns, rows)) {
                verdictByType.set(v.type, v);
            }
        }
        return CHART_TYPES.map((t) => {
            const v = verdictByType.get(t.value);
            const fit = v ? v.fit : 'available';
            return {
                ...t,
                cardClass: [
                    'chart-card',
                    this.type === t.value ? 'chart-card_selected' : '',
                    `chart-card--${fit}`
                ].filter(Boolean).join(' '),
                fitIcon: v ? fitIcon(v.fit) : null,
                fitCaption: v ? v.caption : '',
                fitTitle: v ? `${t.label} — ${v.caption}` : t.label,
                _rank: fitRank(fit)
            };
        }).sort((a, b) => a._rank - b._rank);
    }

    get currentChartVerdict() {
        const columns = this.previewResult?.columns || [];
        const rows = this.previewResult?.rows || [];
        if (columns.length === 0) return null;
        const verdicts = scoreChartTypes(columns, rows);
        return verdicts.find((v) => v.type === this.type) || null;
    }
    get hasCurrentChartVerdict() {
        return !!this.currentChartVerdict;
    }
    get currentVerdictClass() {
        const v = this.currentChartVerdict;
        if (!v) return 'cfg-chart-caption';
        return `cfg-chart-caption cfg-chart-caption--${v.fit}`;
    }
    get currentVerdictIcon() {
        const v = this.currentChartVerdict;
        return v ? fitIcon(v.fit) : 'utility:info_alt';
    }
    get currentVerdictText() {
        const v = this.currentChartVerdict;
        return v ? v.caption : '';
    }

    get sortFieldOptions() {
        // First option = "(none)" so users can clear the sort.
        const opts = [{ label: '(no override)', value: '' }];
        for (const c of this.availableColumns) {
            opts.push({ label: c.label || c.key, value: c.key });
        }
        return opts;
    }

    // Phase E1: pickers feed off the same availableColumns the live preview
    // populates from the report's first 10 rows, but split by numeric vs
    // categorical so the user gets sensible options for each axis.
    //
    // Phase 1 (BI parity): always offer a synthetic "Count of records"
    // option at the top so reports with no numeric columns (very common for
    // CRM/activity reports) still have a sensible Y-axis pick. The chart
    // engine recognizes the '__count__' sentinel and counts rows per X-axis
    // group instead of summing a value column.
    get yAxisOptions() {
        const opts = [{ label: 'Count of records', value: '__count__' }];
        for (const c of this.availableColumns) {
            if (c.numeric) opts.push({ label: c.label || c.key, value: c.key });
        }
        return opts;
    }

    // True when the running report has no numeric columns. The dialog uses
    // this to (a) pre-select Count of records as the default Y-axis pick on
    // new widgets, and (b) show a one-line hint under the picker explaining
    // why the only sensible measure is "count".
    get hasNoNumericFields() {
        return !this.availableColumns.some((c) => c.numeric);
    }
    get xAxisOptions() {
        // Categorical / non-numeric columns make sensible X-axis groupings.
        const opts = [{ label: '(auto)', value: '' }];
        this.availableColumns
            .filter((c) => !c.numeric)
            .forEach((c) => opts.push({ label: c.label || c.key, value: c.key }));
        return opts;
    }

    get hasPreview() {
        return !!this.previewResult && !this.previewError;
    }

    get previewChartType() {
        // Map "auto"/"horizontal" to types crChart understands; crChart does
        // its own "auto" detection so we just pass through.
        return this.type;
    }

    // ---- Handlers ----

    handleTypeSelect(event) {
        const value = event.currentTarget.dataset.value;
        if (value) this.type = value;
    }

    // ---- Phase J1 AI hint ----
    get showAiHint() {
        return this._aiEnabled && this.showChartForm && !!this._aiSuggestion;
    }
    get aiHintText() {
        if (!this._aiSuggestion) return '';
        return `AI suggests "${this._aiSuggestion.chartType}" — ${this._aiSuggestion.reason}`;
    }
    async loadAiSuggestionIfNeeded() {
        if (!this._aiEnabled || this._aiFetched || !this.reportId) return;
        this._aiFetched = true;
        try {
            const rec = await recommendChartType({
                reportDefinitionId: this.reportId,
                currentType: this.type
            });
            this._aiSuggestion = rec || null;
        } catch (_) {
            // Hint is purely additive; silent on failure so the dialog
            // stays usable.
            this._aiSuggestion = null;
        }
    }
    handleChartGridFocus() {
        this.loadAiSuggestionIfNeeded();
    }

    handleTitleChange(e)        { this.title = e.detail.value; }
    handleSubtitleChange(e)     { this.subtitle = e.detail.value; }
    handleFooterChange(e)       { this.footer = e.detail.value; }
    handleLegendChange(e)       { this.legendPosition = e.detail.value; }
    handleDisplayUnitsChange(e) { this.displayUnits = e.detail.value; }
    handleDecimalChange(e)      { this.decimalPlaces = e.detail.value; }
    handleSortByChange(e)       { this.sortBy = e.detail.value; }
    handleSortDirChange(e)      { this.sortDirection = e.detail.value; }
    handleMaxGroupsChange(e)    {
        const n = parseInt(e.detail.value, 10);
        this.maxGroups = Number.isFinite(n) && n > 0 ? n : 100;
    }
    handleThemeChange(e)        { this.widgetTheme = e.detail.value; }
    handleShowValuesChange(e)   { this.showValues = e.detail.checked; }
    handleCustomLinkChange(e)   { this.customLink = e.detail.value; }
    handleYAxisChange(e)        {
        // lightning-dual-listbox emits an array of selected keys.
        this.yAxisFields = Array.isArray(e.detail.value) ? e.detail.value : [];
    }
    handleXAxisChange(e)        { this.xAxisField = e.detail.value; }
    handleUseChartFromReportChange(e) {
        this.useChartFromReport = e.detail.checked;
        // Clear the override fields so the saved viz JSON is consistent —
        // future me reading the saved record can tell at a glance whether
        // overrides were intentionally set.
        if (this.useChartFromReport) {
            this.yAxisFields = [];
            this.xAxisField = '';
            this.sortBy = '';
            this.maxGroups = 100;
            this.legendPosition = 'right';
            this.displayUnits = 'auto';
            this.decimalPlaces = '';
        }
    }
    handleUseTableFromReportChange(e) {
        this.useTableFromReport = e.detail.checked;
    }
    // Lock-state getter: every chart-config field uses this to decide whether
    // to render itself disabled. Keeps the dialog's intent obvious — toggling
    // the inheritance checkbox visibly greys out the overrides.
    get overrideFieldsDisabled() {
        return !!this.useChartFromReport;
    }

    // ---- Conditional formatting (table tiles) ----

    // Only meaningful for table visualizations; the section is hidden for
    // other chart types so authors aren't offered a no-op control.
    get showConditionalFormatting() {
        return this.showChartForm && this.type === 'table';
    }

    // Column picker options for each rule. Reuses the live-preview columns.
    get cfColumnOptions() {
        const opts = [{ label: '(select column)', value: '' }];
        for (const c of this.availableColumns) {
            opts.push({ label: c.label || c.key, value: c.key });
        }
        return opts;
    }

    // Decorate the raw rules with view-only flags the template needs (e.g.
    // whether to show the second value input for 'between').
    get conditionalFormatRows() {
        return this.conditionalFormats.map((r) => ({
            ...r,
            showValueTo: r.operator === 'between'
        }));
    }

    handleAddConditionalFormat() {
        this.conditionalFormats = [
            ...this.conditionalFormats,
            {
                id: `cf-${this._cfSeq++}`,
                column: '',
                operator: '=',
                value: '',
                valueTo: '',
                background: '#FFF3CD',
                text: '#000000'
            }
        ];
    }

    handleRemoveConditionalFormat(event) {
        const id = event.currentTarget.dataset.id;
        this.conditionalFormats = this.conditionalFormats.filter((r) => r.id !== id);
    }

    handleCfFieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const field = event.currentTarget.dataset.field;
        const value = event.detail ? event.detail.value : event.target.value;
        this.conditionalFormats = this.conditionalFormats.map((r) => {
            return r.id === id ? { ...r, [field]: value } : r;
        });
    }

    // Strip client-only fields and drop incomplete rules. A rule is valid
    // when it targets a column and (for non-'between') carries a value, or
    // (for 'between') carries both bounds.
    get cleanConditionalFormats() {
        return this.conditionalFormats
            .filter((r) => {
                if (!r.column || !r.operator) return false;
                if (r.operator === 'between') {
                    return r.value !== '' && r.value != null
                        && r.valueTo !== '' && r.valueTo != null;
                }
                return r.value !== '' && r.value != null;
            })
            .map((r) => {
                const out = {
                    column: r.column,
                    operator: r.operator,
                    value: r.value,
                    background: r.background || '',
                    text: r.text || ''
                };
                if (r.operator === 'between') out.valueTo = r.valueTo;
                return out;
            });
    }

    // ---- Table totals footer (table tiles) ----

    // Only meaningful for table visualizations; hidden for other chart types
    // so authors aren't offered a no-op control.
    get showTableTotals() {
        return this.showChartForm && this.type === 'table';
    }

    // Column picker options for each total. Reuses the live-preview columns.
    get ttColumnOptions() {
        const opts = [{ label: '(select column)', value: '' }];
        for (const c of this.availableColumns) {
            opts.push({ label: c.label || c.key, value: c.key });
        }
        return opts;
    }

    get tableTotalRows() {
        return this.tableTotals;
    }

    handleAddTableTotal() {
        this.tableTotals = [
            ...this.tableTotals,
            { id: `tt-${this._ttSeq++}`, column: '', agg: 'sum' }
        ];
    }

    handleRemoveTableTotal(event) {
        const id = event.currentTarget.dataset.id;
        this.tableTotals = this.tableTotals.filter((t) => t.id !== id);
    }

    handleTableTotalChange(event) {
        const id = event.currentTarget.dataset.id;
        const field = event.currentTarget.dataset.field;
        const value = event.detail ? event.detail.value : event.target.value;
        this.tableTotals = this.tableTotals.map((t) =>
            t.id === id ? { ...t, [field]: value } : t
        );
    }

    // Strip client-only ids and drop incomplete totals. A total is valid when
    // it targets a column and carries a known aggregation.
    get cleanTableTotals() {
        return this.tableTotals
            .filter((t) => !!t.column && !!t.agg)
            .map((t) => ({ column: t.column, agg: t.agg }));
    }

    // ---- KPI target & thresholds (metric / gauge tiles) ----

    // Section is meaningful only for the single-value KPI tiles.
    get showKpiThresholds() {
        return this.showChartForm && (this.type === 'metric' || this.type === 'gauge');
    }

    handleKpiTargetChange(e)    { this.kpiTarget = e.detail ? e.detail.value : e.target.value; }
    handleKpiDirectionChange(e) { this.kpiGoodDirection = e.detail.value; }

    handleAddKpiThreshold() {
        this.kpiThresholds = [
            ...this.kpiThresholds,
            { id: `kpi-${this._kpiSeq++}`, upTo: '', color: '#2E844A' }
        ];
    }

    handleRemoveKpiThreshold(event) {
        const id = event.currentTarget.dataset.id;
        this.kpiThresholds = this.kpiThresholds.filter((t) => t.id !== id);
    }

    handleKpiThresholdChange(event) {
        const id = event.currentTarget.dataset.id;
        const field = event.currentTarget.dataset.field;
        const value = event.detail ? event.detail.value : event.target.value;
        this.kpiThresholds = this.kpiThresholds.map((t) =>
            t.id === id ? { ...t, [field]: value } : t
        );
    }

    // Strip client-only ids and drop incomplete bands (a band needs both a
    // numeric upTo and a color). Order is preserved — the viewer matches the
    // FIRST band whose upTo >= value, so author order is the band order.
    get cleanKpiThresholds() {
        return this.kpiThresholds
            .filter((t) => t.upTo !== '' && t.upTo != null && !Number.isNaN(Number(t.upTo)) && !!t.color)
            .map((t) => ({ upTo: Number(t.upTo), color: t.color }));
    }

    // ---- Period-over-period comparison (metric / gauge tiles) ----

    // Section is meaningful only for the single-value KPI tiles.
    get showPeriodComparison() {
        return this.showChartForm && (this.type === 'metric' || this.type === 'gauge');
    }

    // Date-field picker options. Reuses the live-preview columns (any column
    // can carry a date; the query engine filters on it regardless of type).
    get pcDateFieldOptions() {
        const opts = [{ label: '(select date field)', value: '' }];
        for (const c of this.availableColumns) {
            opts.push({ label: c.label || c.key, value: c.key });
        }
        return opts;
    }

    handlePcEnabledChange(e)   { this.pcEnabled = e.detail.checked; }
    handlePcDateFieldChange(e) { this.pcDateField = e.detail.value; }
    handlePcPeriodChange(e)    { this.pcPeriod = e.detail.value; }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    get lwcOptions() {
        return this.lwcRegistry.map((e) => ({ label: e.label, value: e.value }));
    }
    get selectedLwcEntry() {
        return this.lwcRegistry.find((e) => e.value === this.lwcName) || this.lwcRegistry[0];
    }
    get lwcDescription() {
        return this.selectedLwcEntry?.description || '';
    }
    get lwcSamplePropsHelp() {
        const sample = this.selectedLwcEntry?.sampleProps;
        return sample ? `Example:\n${sample}` : '';
    }
    handleLwcNameChange(e) {
        this.lwcName = e.detail.value;
        // Pre-fill sample props if the user hasn't customized yet.
        const trimmed = (this.lwcPropsJson || '').trim();
        if (trimmed === '' || trimmed === '{}') {
            this.lwcPropsJson = this.selectedLwcEntry?.sampleProps || '{}';
        }
    }
    handleLwcPropsChange(e) {
        this.lwcPropsJson = e.detail.value;
        // Inline-validate JSON so we don't surprise the user at save time.
        try {
            JSON.parse(this.lwcPropsJson || '{}');
            this.lwcPropsError = '';
        } catch (err) {
            this.lwcPropsError = err.message || 'Invalid JSON';
        }
    }

    handleApply() {
        let viz;
        if (this.widgetKind === 'text') {
            viz = {
                type: 'richtext',
                title: this.title || 'Text',
                html: this.richText || ''
            };
        } else if (this.widgetKind === 'image') {
            if (!this.imageUrl || !this.imageUrl.trim()) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Image URL required',
                    message: 'Provide an image URL before adding the widget.',
                    variant: 'warning'
                }));
                return;
            }
            viz = {
                type: 'image',
                title: this.title || 'Image',
                url: this.imageUrl.trim(),
                altText: this.imageAlt || '',
                fit: this.imageFit
            };
        } else if (this.widgetKind === 'lwc') {
            // Re-validate the LWC name against the registry — defense in
            // depth for the case where the registry shrunk between dialog
            // open and save (or the saved viz was hand-edited).
            const inRegistry = this.lwcRegistry.some((e) => e.value === this.lwcName);
            if (!inRegistry) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Component not allowlisted',
                    message: `"${this.lwcName}" is not in the dashboard LWC registry.`,
                    variant: 'error'
                }));
                return;
            }
            let widgetProps;
            try {
                widgetProps = this.lwcPropsJson && this.lwcPropsJson.trim()
                    ? JSON.parse(this.lwcPropsJson)
                    : {};
            } catch (err) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Invalid component props',
                    message: err.message || 'Properties must be valid JSON.',
                    variant: 'error'
                }));
                return;
            }
            viz = {
                type: 'lwc',
                title: this.title || this.selectedLwcEntry?.label || 'Component',
                lwcName: this.lwcName,
                widgetProps
            };
        } else {
            viz = {
                type: this.type,
                title: this.title || '',
                subtitle: this.subtitle || '',
                footer: this.footer || '',
                legendPosition: this.legendPosition,
                displayUnits: this.displayUnits,
                decimalPlaces: this.decimalPlaces ? Number(this.decimalPlaces) : null,
                sortBy: this.sortBy || null,
                sortDirection: this.sortDirection,
                maxGroups: this.maxGroups,
                theme: this.widgetTheme,
                showValues: !!this.showValues,
                customLink: this.customLink || '',
                // Phase E1: explicit axis overrides. Empty arrays / blank
                // string mean "let crChart auto-detect" (legacy behavior).
                // When useChartFromReport is set, we still send the arrays
                // through but the renderer ignores them per the flag below.
                yAxis: Array.isArray(this.yAxisFields) ? this.yAxisFields.slice() : [],
                xAxis: this.xAxisField || '',
                // Phase F2: report-inheritance flags. Persisted so the form
                // re-locks correctly on edit; render path treats either
                // flag as "fall back to auto-detect from columns".
                useChartFromReport: !!this.useChartFromReport,
                useTableFromReport: !!this.useTableFromReport
            };
            // Conditional formatting: only persist valid, non-empty rules so
            // the viewer's "no rules -> identical rendering" guard holds.
            const cleanCf = this.cleanConditionalFormats;
            if (cleanCf.length > 0) {
                viz.conditionalFormats = cleanCf;
            }
            // Table totals footer: only persist for table tiles and only when
            // at least one valid total exists, so the viewer's "no totals ->
            // no footer" guard holds for every other tile.
            if (this.type === 'table') {
                const cleanTt = this.cleanTableTotals;
                if (cleanTt.length > 0) {
                    viz.tableTotals = cleanTt;
                }
            }
            // KPI target + thresholds: only attach for metric/gauge tiles, and
            // only the fields that are actually set, so the viewer's "nothing
            // configured -> render as today" guard holds for every other tile.
            if (this.type === 'metric' || this.type === 'gauge') {
                if (this.kpiTarget !== '' && this.kpiTarget != null
                    && !Number.isNaN(Number(this.kpiTarget))) {
                    viz.kpiTarget = Number(this.kpiTarget);
                    // Direction only matters alongside a target.
                    viz.kpiGoodDirection = this.kpiGoodDirection === 'down' ? 'down' : 'up';
                }
                const cleanKpi = this.cleanKpiThresholds;
                if (cleanKpi.length > 0) {
                    viz.kpiThresholds = cleanKpi;
                }
                // Period-over-period: only persist when enabled AND a date field
                // is chosen, so the viewer's "nothing configured -> no extra
                // queries" guard holds for every other tile.
                if (this.pcEnabled && this.pcDateField) {
                    viz.periodComparison = {
                        enabled: true,
                        dateField: this.pcDateField,
                        period: this.pcPeriod || 'month'
                    };
                }
            }
        }
        this.dispatchEvent(new CustomEvent('apply', {
            detail: { viz, reportId: this.reportId, reportName: this.reportName }
        }));
    }

    handleRichTextChange(e) { this.richText = e.detail.value; }
    handleImageUrlChange(e) { this.imageUrl = e.detail.value; }
    handleImageAltChange(e) { this.imageAlt = e.detail.value; }
    handleImageFitChange(e) { this.imageFit = e.detail.value; }

    get showChartForm() { return this.widgetKind === 'chart'; }
    get showTextForm()  { return this.widgetKind === 'text'; }
    get showImageForm() { return this.widgetKind === 'image'; }
    get showLwcForm()   { return this.widgetKind === 'lwc'; }
    get isLwcKpi()      { return this.widgetKind === 'lwc' && this.lwcName === 'crDashboardKpiTileWidget'; }
    get isLwcClock()    { return this.widgetKind === 'lwc' && this.lwcName === 'crDashboardClockWidget'; }
    // Live preview prop object — falls back to {} when JSON is being typed.
    get previewLwcProps() {
        try {
            return this.lwcPropsJson && this.lwcPropsJson.trim()
                ? JSON.parse(this.lwcPropsJson)
                : {};
        } catch {
            return {};
        }
    }
    get headerLabel() {
        if (this.widgetKind === 'text')  return this.isEditMode ? 'Edit Text' : 'Add Text';
        if (this.widgetKind === 'image') return this.isEditMode ? 'Edit Image' : 'Add Image';
        if (this.widgetKind === 'lwc')   return this.isEditMode ? 'Edit Component' : 'Add Component';
        return this.isEditMode ? 'Edit Widget' : 'Add Widget';
    }
    get applyButtonLabel() {
        return this.isEditMode ? 'Update' : 'Add';
    }
    // Phase D: object-fit style passed to the inline preview <img>. Mirrors
    // what the viewer applies at render time so the preview matches reality.
    get imagePreviewStyle() {
        return `object-fit: ${this.imageFit || 'contain'};`;
    }

    // ---- Live preview ----

    async loadPreview() {
        if (!this.reportId) return;
        if (this._previewTimer) clearTimeout(this._previewTimer);
        this._previewTimer = setTimeout(() => this.runPreview(), PREVIEW_DEBOUNCE_MS);
    }

    async runPreview() {
        this.previewLoading = true;
        this.previewError = null;
        try {
            const result = await runReportById({
                reportDefinitionId: this.reportId,
                pageToken: null,
                pageSize: PREVIEW_ROW_LIMIT,
                dashboardFiltersJson: null
            });
            if (this._disposed) return;
            this.previewResult = result;
            this.availableColumns = (result?.columns || []).map((c) => ({
                key: c.key,
                label: c.label,
                numeric: !!c.numeric
            }));
            // Phase 1 default: on a brand-new widget (no override yet) for a
            // report with no numeric columns, pre-pick "Count of records" so
            // the user sees an immediate working chart instead of an empty
            // axis picker. Doesn't touch edit-mode widgets that already have
            // an explicit override.
            if (!this.isEditMode
                && this.hasNoNumericFields
                && (!Array.isArray(this.yAxisFields) || this.yAxisFields.length === 0)) {
                this.yAxisFields = ['__count__'];
            }
        } catch (error) {
            if (this._disposed) return;
            this.previewError = error?.body?.message || error?.message || 'Could not load preview';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Preview unavailable',
                message: this.previewError,
                variant: 'warning'
            }));
        } finally {
            if (!this._disposed) this.previewLoading = false;
        }
    }
}