import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import CHART_JS from '@salesforce/resourceUrl/ChartJS';

// Default palette tuned for SLDS — first colors hit the most common bars/lines.
// Hex values are mid-saturation so dark text overlays remain readable.
// Orlando Health brand palette — kept in sync with crEChart. Orange + teal lead
// (brand series colors); slots 3-8 are accessible, colorblind-distinct extensions
// validated via the dataviz skill. Brand teal is low-chroma by brand mandate,
// mitigated by the value labels/legend the charts render.
const PALETTE = [
    '#e8631c', '#6ba9b8', '#7a4fa3', '#3e8e5a', '#2c6ea8',
    '#c0392b', '#be7a0a', '#b5507a'
];

const NUMERIC_DATA_TYPES = new Set(['CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT', 'NUMBER']);

let _chartJsLoadPromise = null;

/**
 * Reusable chart component. Wraps Chart.js v4 so the rest of the framework can
 * stay declarative — pass in a chartType and a `result` (the same shape the query
 * engine returns) and let this component figure out which numeric column to chart,
 * which label column to use, and which Chart.js dataset shape to build.
 *
 * Why a single wrapper:
 *   - Single point of upgrade: bumping Chart.js or swapping libraries touches one file.
 *   - Lifecycle done right: chart.destroy() on disconnect/data-change so dashboards with
 *     many tiles don't leak Chart.js instances on every render.
 *   - LWC reactivity safety: Chart.js mutates the data internally, so we deep-clone
 *     before passing in to avoid LWC's proxy throwing on non-extensible objects.
 *   - Defensive empty-state: returns a friendly message instead of an empty canvas
 *     when the data has no chartable column.
 */
export default class CrChart extends LightningElement {
    // chartType + engine are getter/setter pairs so a parent toggling the
    // chart type (e.g., clicking a Display-As icon in the widget config
    // dialog) re-renders the chart. Plain @api fields don't trip
    // _needsRender, which is why the live preview previously stuck on the
    // last-rendered chart type until something else (data) changed.
    @api
    get chartType() {
        return this._chartType;
    }
    set chartType(value) {
        if (value === this._chartType) return;
        this._chartType = value;
        this._needsRender = true;
        // Belt-and-suspenders: the LWC re-render that *should* fire because
        // @track _chartType changed doesn't reliably trigger renderedCallback
        // for parent-prop changes when the canvas is hidden inside a modal
        // (the case for the widget config dialog preview). Force a draw on
        // the next microtask so the canvas updates immediately when the user
        // clicks a different Display-As icon. Idempotent with renderedCallback.
        this.scheduleRedraw();
    }
    @api title = '';
    @api height = 280;
    // Phase 3 v6: opt-in routing to the ECharts-backed renderer for BI-style
    // chart types (heatmap / treemap / sunburst / sankey / gauge) that Chart.js
    // can't do cleanly. Default is the existing Chart.js path so no consumer
    // breaks. Pass engine="echarts" to route through c-cr-e-chart instead.
    @api
    get engine() {
        return this._engine;
    }
    set engine(value) {
        if (value === this._engine) return;
        this._engine = value;
        this._needsRender = true;
        // If we've switched onto the Chart.js path and the lib isn't loaded yet
        // (e.g. this chart started on the ECharts path and skipped the load),
        // load it now before drawing. ensureChartJs is cached so this is a
        // no-op when Chart.js is already present.
        if (!this.useECharts && !window.Chart) {
            this.loadChartJsThenRender();
        } else {
            this.scheduleRedraw();
        }
    }

    // Force a redraw on the next microtask. Called from setters that update
    // chart configuration; ensures the canvas reflects the new state even if
    // the surrounding LWC lifecycle doesn't fire renderedCallback (e.g.,
    // modal-hosted previews). Safe to call multiple times — _needsRender
    // gates the actual draw so we don't double-render.
    scheduleRedraw() {
        Promise.resolve().then(() => {
            if (!this._needsRender) return;
            if (this.loading || this.errorMessage) return;
            if (!this._isVisible) return;
            const canvas = this.template.querySelector('canvas');
            if (!canvas) return;
            this._needsRender = false;
            this.draw(canvas);
        });
    }
    // @track is required so that updating _chartType / _engine from inside
    // the @api setters actually schedules a re-render. Without it, LWC's
    // setter fires but renderedCallback never runs, leaving the canvas
    // stuck on the previously-drawn chart type. (This was the live-preview
    // bug — chartType prop updated, _needsRender flipped, but nothing
    // ever picked up the dirty flag because the component didn't re-render.)
    @track _chartType = 'bar';
    @track _engine = 'chartjs';

    get useECharts() {
        return (this._engine || '').toLowerCase() === 'echarts';
    }

    // Imperative PNG export passthrough so consumers (e.g. the report viewer's
    // "Download PNG" button) don't need to know which engine is active. ECharts
    // path delegates to the child c-cr-e-chart's getDataURL; Chart.js path reads
    // the <canvas> directly. Returns a data: URL or null if not rendered yet.
    @api
    getPngDataUrl() {
        if (this.useECharts) {
            const ech = this.template.querySelector('c-cr-e-chart');
            return ech ? ech.getPngDataUrl() : null;
        }
        const canvas = this.template.querySelector('canvas');
        return canvas ? canvas.toDataURL('image/png') : null;
    }
    // Phase E1: explicit axis overrides. When set, these win over the
    // auto-detect logic in findValueColumn / findLabelColumn. Pass column
    // keys (not labels). yAxisFields is an array (multi-series); xAxisField
    // is a single key. Both are optional — leave blank for auto-detect.
    @api
    get yAxisFields() {
        return this._yAxisFields;
    }
    set yAxisFields(value) {
        this._yAxisFields = value;
        this._needsRender = true;
    }
    @api
    get xAxisField() {
        return this._xAxisField;
    }
    set xAxisField(value) {
        this._xAxisField = value;
        this._needsRender = true;
    }
    _yAxisFields;
    _xAxisField;
    // BI display options. A single bag so consumers can forward the widget
    // viz config (displayUnits / decimalPlaces / showValues / targetValue)
    // without crChart needing a separate @api per knob. All keys are optional
    // — absent keys fall back to the sensible defaults applied below, so the
    // legacy callers that never set `options` are unaffected.
    //   displayUnits   : 'auto' | 'full' | 'shortened' | 'thousands' | 'millions'
    //   decimalPlaces  : number | null   (null/absent = auto)
    //   showValues     : boolean         (data labels on bar/line; default off)
    //   targetValue    : number          (draws a horizontal reference line)
    @api
    get options() {
        return this._options;
    }
    set options(value) {
        this._options = value && typeof value === 'object' ? value : {};
        this._needsRender = true;
        this.scheduleRedraw();
    }
    _options = {};
    // The query engine result: { columns: [{key,label,dataType,numeric}], rows: [{...}] }
    @api
    get result() {
        return this._result;
    }
    set result(value) {
        this._result = value;
        // Defer to renderedCallback so we draw after Chart.js is loaded AND the
        // <canvas> exists in the DOM.
        this._needsRender = true;
    }

    @track loading = true;
    @track errorMessage = null;

    _result;
    _chart = null;
    _needsRender = false;
    _resolvedType = null;
    _observer = null;
    _observerSetup = false;
    _isVisible = false;

    connectedCallback() {
        // Lazy-load discipline: only pull in Chart.js when this chart actually
        // renders via the Chart.js path. When the engine is ECharts (the default
        // once Default_Chart_Engine is on), the child c-cr-e-chart lazy-loads
        // ECharts itself, so loading Chart.js here would be ~206KB of dead
        // weight on every chart. Skip it entirely on the ECharts path.
        if (this.useECharts) {
            this.loading = false;
            this._needsRender = true;
            return;
        }
        this.loadChartJsThenRender();
    }

    // Loads Chart.js (idempotent — promise is cached globally) and clears the
    // loading gate so renderedCallback/scheduleRedraw can draw. Called from
    // connectedCallback and from the engine setter when switching to Chart.js.
    loadChartJsThenRender() {
        return this.ensureChartJs()
            .then(() => {
                this.loading = false;
                this._needsRender = true;
                this.scheduleRedraw();
            })
            .catch((err) => {
                this.loading = false;
                this.errorMessage = `Could not load chart library: ${err?.message || err}`;
            });
    }

    disconnectedCallback() {
        this.destroyChart();
        this.removeResizeListener();
        if (this._observer) {
            this._observer.disconnect();
            this._observer = null;
        }
    }

    renderedCallback() {
        // Defer Chart.js instantiation until the tile is actually visible. On a
        // dashboard with tiles below the fold this avoids constructing charts
        // the user may never scroll to.
        if (!this._observerSetup) {
            this._observerSetup = true;
            this.observeVisibility();
        }
        if (this.loading || this.errorMessage || !this._needsRender || !this._isVisible) return;
        const canvas = this.template.querySelector('canvas');
        if (!canvas) return;
        this._needsRender = false;
        this.draw(canvas);
    }

    observeVisibility() {
        // No IntersectionObserver in this runtime — render immediately so we
        // don't block charts entirely on older Lightning sandboxes.
        if (typeof IntersectionObserver === 'undefined') {
            this._isVisible = true;
            return;
        }
        const target = this.template.querySelector('.cr-chart');
        if (!target) {
            this._isVisible = true;
            return;
        }
        this._observer = new IntersectionObserver((entries) => {
            if (entries.some((entry) => entry.isIntersecting)) {
                this._isVisible = true;
                if (this._observer) {
                    this._observer.disconnect();
                    this._observer = null;
                }
                // _isVisible isn't template-bound, so renderedCallback won't
                // auto-fire on its change. Trigger the draw directly.
                if (this._needsRender && !this.loading && !this.errorMessage) {
                    const canvas = this.template.querySelector('canvas');
                    if (canvas) {
                        this._needsRender = false;
                        this.draw(canvas);
                    }
                }
            }
        }, { rootMargin: '100px' });
        this._observer.observe(target);
    }

    ensureChartJs() {
        // Cache the promise so multiple chart instances on the same page don't fight
        // over loading the same script. loadScript is itself idempotent but caching
        // here makes the success path a single sync resolve.
        // On rejection, clear the cached promise so the next caller retries —
        // otherwise a transient load failure poisons every chart on the page.
        if (!_chartJsLoadPromise) {
            _chartJsLoadPromise = loadScript(this, CHART_JS).then(() => {
                // Chart.js v4 uses ResizeObserver internally to react to container
                // size changes. Some Lightning runtimes (older Locker, certain
                // Experience Cloud configurations) don't expose ResizeObserver to
                // the LWC sandbox, which surfaces as
                //   "Chart render failed: ResizeObserver is not a constructor"
                // the moment a chart is constructed. Install a no-op shim so chart
                // construction succeeds. We then drive responsive resizes manually
                // via a window-resize listener (see addResizeListener below).
                if (typeof window.ResizeObserver !== 'function') {
                    window.ResizeObserver = class ResizeObserverShim {
                        observe() {}
                        unobserve() {}
                        disconnect() {}
                    };
                }
                return window.Chart;
            }).catch((err) => {
                _chartJsLoadPromise = null;
                throw err;
            });
        }
        return _chartJsLoadPromise;
    }

    addResizeListener() {
        if (this._resizeBound) return;
        this._resizeBound = () => {
            if (this._chart && typeof this._chart.resize === 'function') {
                try { this._chart.resize(); } catch (e) { /* chart already destroyed */ }
            }
        };
        window.addEventListener('resize', this._resizeBound);
    }

    removeResizeListener() {
        if (this._resizeBound) {
            window.removeEventListener('resize', this._resizeBound);
            this._resizeBound = null;
        }
    }

    destroyChart() {
        if (this._chart) {
            try { this._chart.destroy(); } catch (e) { /* already destroyed */ }
            this._chart = null;
        }
    }

    get hasResult() {
        return !!this._result && Array.isArray(this._result.rows) && this._result.rows.length > 0;
    }

    get showEmpty() {
        return !this.loading && !this.errorMessage && !this.hasResult;
    }

    // QA-C1: gate the canvas DIV on the absence of an errorMessage too.
    // Otherwise a "Not enough data" error renders alongside an empty 280px
    // tall canvas — looks like both an error AND a broken chart.
    get showChart() {
        return this.hasResult && !this.errorMessage;
    }

    get chartContainerStyle() {
        return `height: ${Number(this.height) || 280}px; position: relative;`;
    }

    /**
     * Pick the best numeric column to chart. Phase E1: honor the explicit
     * yAxisFields override first (single-series compat). Phase F1 introduces
     * findValueColumns() for true multi-series; this method stays for the
     * findLabelColumn callers that just need the primary value column.
     */
    findValueColumn(columns, rows) {
        if (!columns?.length) return null;
        // Phase E1: explicit yAxisFields override.
        const explicitYKey = Array.isArray(this.yAxisFields) && this.yAxisFields.length > 0
            ? this.yAxisFields[0]
            : null;
        if (explicitYKey) {
            const explicitCol = columns.find((c) => c.key === explicitYKey);
            if (explicitCol) return explicitCol;
            // Fall through to auto-detect if the override key is no longer in
            // the result (e.g. report definition changed and the field went away).
        }
        // Explicit numeric flag from the engine.
        let col = columns.find((c) => c.numeric === true);
        if (col) return col;
        // DataType match.
        col = columns.find((c) => NUMERIC_DATA_TYPES.has(String(c.dataType || '').toUpperCase()));
        if (col) return col;
        // Last resort — sample row to find a numeric value.
        if (rows && rows.length) {
            const sample = rows[0];
            col = columns.find((c) => Number.isFinite(Number(sample?.[c.key])));
        }
        return col || null;
    }

    /**
     * Phase F1: resolve every yAxisFields key to a column for true multi-series
     * rendering. Falls back to the single-column auto-detect when no override
     * is set, so legacy callers stay on the single-series path.
     */
    findValueColumns(columns, rows) {
        if (!columns?.length) return [];
        // Phase 1 (BI parity): '__count__' is a synthetic sentinel meaning
        // "count of records per X-axis group". Returning empty here drops us
        // into draw()'s count-fallback path, which already handles grouping
        // + Top-N + "Other" bucketing. The xAxisField override is honored
        // there via pickGroupColumn's awareness of it.
        if (Array.isArray(this.yAxisFields) && this.yAxisFields[0] === '__count__') {
            return [];
        }
        if (Array.isArray(this.yAxisFields) && this.yAxisFields.length > 0) {
            const matched = this.yAxisFields
                .map((key) => columns.find((c) => c.key === key))
                .filter(Boolean);
            if (matched.length > 0) return matched;
            // If none of the override keys resolved (report schema drift),
            // fall through to the auto-detect single column so the tile
            // still renders something sensible.
        }
        const single = this.findValueColumn(columns, rows);
        return single ? [single] : [];
    }

    findLabelColumn(columns, valueColumn) {
        if (!columns?.length) return null;
        // Phase E1: explicit xAxisField override.
        if (this.xAxisField) {
            const explicitCol = columns.find((c) => c.key === this.xAxisField);
            if (explicitCol) return explicitCol;
        }
        const candidate = columns.find((c) => c !== valueColumn && c.key !== valueColumn?.key);
        return candidate || columns[0];
    }

    /** Resolve 'auto' / engine alias values to a Chart.js type. */
    resolveType(rowCount) {
        const t = String(this.chartType || '').toLowerCase();
        if (t === 'metric' || t === 'gauge') return t; // handled outside Chart.js
        if (t === 'pivot' || t === 'table') return null;
        if (t === 'donut') return 'doughnut';
        if (t === 'pie') return 'pie';
        if (t === 'line') return 'line';
        // Chart.js has no native 'area' type — it's a line with fill. Map to 'line';
        // the single-series line path already fills (see drawAs). ECharts (the default
        // engine) renders a true area via buildAreaOption.
        if (t === 'area') return 'line';
        if (t === 'bar' || t === 'column') return 'bar';
        // Chart.js 3+ doesn't have a separate 'horizontalBar' type — it's a regular
        // bar chart with indexAxis: 'y'. drawAs detects this token and flips the axis.
        if (t === 'horizontal' || t === 'horizontalbar' || t === 'hbar') return 'horizontalbar';
        if (t === 'auto') {
            if (rowCount <= 1) return 'metric';
            if (rowCount <= 6) return 'doughnut';
            return 'bar';
        }
        return 'bar';
    }

    draw(canvas) {
        this.destroyChart();
        // QA-C1: clear any prior errorMessage at the start of every draw so
        // a stale "Not enough data" doesn't survive into a new render that
        // actually has rows. If the new render also fails, the early-return
        // paths below set errorMessage afresh.
        this.errorMessage = null;
        if (!this.hasResult) return;
        const Chart = window.Chart;
        if (!Chart) return;

        const { columns = [], rows = [] } = this._result;
        // QA-C1: catch the no-rows / empty-result case BEFORE constructing
        // labels and series. Previously, a filter that narrowed to 0 rows
        // (or 0 rows after time-grain aggregation) produced a 0×0 canvas
        // with no message — the user saw a silent blank chart. Now we set
        // the errorMessage path so the template renders a friendly "Not
        // enough data" message instead.
        if (!rows || rows.length === 0) {
            this.errorMessage = 'Not enough data to chart. Clear a filter or pick a different time grain.';
            return;
        }
        const valueColumns = this.findValueColumns(columns, rows);
        let chartLabels;
        // Phase F1: series is an array of { label, data }. Length 1 for the
        // legacy single-series path, length N when the user picked multiple
        // Y fields in the widget config dialog.
        let series;

        if (valueColumns.length > 0) {
            // The query produced an aggregate (SUM/COUNT/AVG, or a Number column).
            // Use it directly with the first categorical column as the x-axis labels.
            const labelColumn = this.findLabelColumn(columns, valueColumns[0]);
            chartLabels = rows.map((row) => this.formatLabel(row?.[labelColumn?.key]));
            series = valueColumns.map((col) => ({
                label: col.label || col.key,
                data: rows.map((row) => Number(row?.[col.key]) || 0)
            }));
        } else {
            // No numeric column — synthesize one by counting rows per first categorical
            // column. This is the right default for flat row-level reports (Activities &
            // Visits etc.) so the chart isn't an error message; it's a useful summary.
            const groupColumn = this.pickGroupColumn(columns);
            if (!groupColumn) {
                this.errorMessage = 'No chartable columns. Add at least one column to the report.';
                return;
            }
            const counts = new Map();
            for (const row of rows) {
                const raw = row?.[groupColumn.key];
                const key = raw === null || raw === undefined || raw === '' ? '(blank)' : String(raw);
                counts.set(key, (counts.get(key) || 0) + 1);
            }
            // Sort descending and cap at 25 slices so a wide categorical column doesn't
            // turn the donut into a pie of crumbs. The "Other" bucket lumps the rest.
            const entries = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);
            const TOP = 24;
            if (entries.length > TOP) {
                const overflow = entries.slice(TOP).reduce((sum, [, n]) => sum + n, 0);
                entries.splice(TOP);
                entries.push(['Other', overflow]);
            }
            chartLabels = entries.map(([label]) => this.formatLabel(label));
            series = [{
                label: `Count by ${groupColumn.label || groupColumn.key}`,
                data: entries.map(([, value]) => value)
            }];
        }

        // QA-C1: also catch the case where after aggregation we ended up
        // with 0 labels (e.g., a count-fallback path that found no group
        // values). Without this guard Chart.js renders a 0×0 canvas with
        // no axis or message.
        if (!chartLabels || chartLabels.length === 0) {
            this.errorMessage = 'Not enough data to chart. Clear a filter or pick a different time grain.';
            return;
        }
        // QA-C1 (round 2): line charts need at least 2 data points to draw
        // a meaningful line — a single-point line renders an empty plot
        // area with axes but no visible line. Catch that case specifically
        // and surface a message so the user knows to clear filters or
        // switch chart type. Other chart types (bar, pie, donut, gauge)
        // render a single data point sensibly.
        const requestedType = String(this.chartType || '').toLowerCase();
        if (chartLabels.length === 1 && (requestedType === 'line' || requestedType === 'area')) {
            this.errorMessage = 'Sparse data — a line chart needs at least 2 points. Try a bar chart or clear a filter.';
            return;
        }
        const type = this.resolveType(chartLabels.length);
        this._resolvedType = type;
        this.drawAs(canvas, type === 'metric' || type === 'gauge' || !type ? 'bar' : type, chartLabels, series);
    }

    pickGroupColumn(columns) {
        if (!columns?.length) return null;
        // Phase 1 (BI parity): respect the user's explicit X-axis pick from
        // the widget config before auto-detecting. Lets a "Count of records"
        // chart group by whichever dimension the user chose (Region, Status,
        // Owner, …) rather than the framework's first-non-Id-column guess.
        if (this.xAxisField) {
            const explicit = columns.find((c) => c.key === this.xAxisField);
            if (explicit) return explicit;
        }
        // Prefer a column that's NOT an Id-looking 18-char field — those make terrible
        // categorical axes. Fallback to the first column if nothing else works.
        const isIdLike = (c) => /Id$/.test(String(c.key || '')) || c.dataType === 'ID' || c.dataType === 'REFERENCE';
        return columns.find((c) => !isIdLike(c)) || columns[0];
    }

    drawAs(canvas, type, labels, series) {
        const isPieLike = type === 'doughnut' || type === 'pie';
        const isHorizontal = type === 'horizontalbar';
        // Horizontal bars are a regular bar chart with indexAxis flipped; the
        // Chart.js type stays 'bar'. Keep the line/pie behaviors unchanged.
        const chartJsType = isHorizontal ? 'bar' : type;

        // Phase F1: multi-series. For pie/doughnut Chart.js can only render
        // one dataset cleanly (a single ring of slices); collapse to the
        // first series. For bar / line / horizontal-bar render all series,
        // each in its own palette color so they're distinguishable.
        // Single-series legacy callers get the original colors (PALETTE[0])
        // so the visual stays unchanged when nobody picked extra Y fields.
        const seriesToRender = isPieLike ? [series[0]] : series;
        const isMultiSeries = seriesToRender.length > 1;
        const datasets = seriesToRender.map((s, idx) => {
            // Per-series color from PALETTE, falling back to brand for
            // single-series so the look matches what users had before
            // multi-Y existed.
            const seriesColor = !isMultiSeries
                ? PALETTE[0]
                : PALETTE[idx % PALETTE.length];
            return {
                label: s.label,
                data: s.data,
                backgroundColor: isPieLike
                    ? labels.map((_, i) => PALETTE[i % PALETTE.length])
                    : type === 'line'
                        ? this.toLineFillColor(seriesColor)
                        : seriesColor,
                borderColor: isPieLike ? '#ffffff' : seriesColor,
                borderWidth: isPieLike ? 1 : 2,
                tension: type === 'line' ? 0.3 : 0,
                fill: type === 'line' && !isMultiSeries
            };
        });

        // Reduced-motion users get an instant render. Everyone else gets the
        // longer easeOutQuart entry plus a per-bar/slice stagger so a fresh
        // chart "lands" instead of popping in.
        const reducedMotion = typeof window !== 'undefined'
            && typeof window.matchMedia === 'function'
            && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        const animationConfig = reducedMotion
            ? { duration: 0 }
            : {
                duration: 700,
                easing: 'easeOutQuart',
                // Stagger only on the initial render. ctx.mode is 'default' for
                // the first build; updates use 'none'/'active' which we leave
                // un-staggered to avoid annoying repeat animations on resize.
                delay: (ctx) => {
                    if (ctx?.type === 'data' && ctx?.mode === 'default') {
                        const idx = Number.isFinite(ctx.dataIndex) ? ctx.dataIndex : 0;
                        return Math.min(idx * 45, 600);
                    }
                    return 0;
                }
            };

        // FIX 3: a tick callback that runs the measure-axis values through the
        // display-option-aware formatter. Category-axis ticks pass strings,
        // which formatNumber returns untouched, so this is safe to attach to
        // either axis. We only wire it to the measure axis below.
        const formatTick = (value) => this.formatNumber(value);

        const config = {
            type: chartJsType,
            data: { labels, datasets },
            options: {
                indexAxis: isHorizontal ? 'y' : 'x',
                responsive: true,
                maintainAspectRatio: false,
                animation: animationConfig,
                // For horizontal bars, the category index runs along Y, so the
                // tooltip's "nearest index" lookup must follow cursor-Y. Without
                // this, Chart.js defaults to axis 'x' and the tooltip resolves
                // the wrong row when the cursor is between bars vertically.
                interaction: { mode: 'index', intersect: false, axis: isHorizontal ? 'y' : 'x' },
                plugins: {
                    // Phase F1: show legend for pie/donut (slice colors) AND
                    // multi-series bar/line (series colors); hide it for
                    // single-series bar/line where the single brand color
                    // adds nothing.
                    legend: { display: isPieLike || isMultiSeries, position: 'bottom' },
                    title: this.title ? { display: true, text: this.title } : { display: false },
                    tooltip: {
                        intersect: false,
                        mode: 'index',
                        axis: isHorizontal ? 'y' : 'x',
                        // FIX 3: tooltips read the same formatter so the units in
                        // the hover card match the axis ticks and data labels.
                        callbacks: {
                            label: (item) => {
                                const v = item?.parsed?.[isHorizontal ? 'x' : 'y'];
                                const lbl = item?.dataset?.label ? `${item.dataset.label}: ` : '';
                                return v === null || v === undefined ? item.formattedValue : lbl + this.formatNumber(v);
                            }
                        }
                    }
                },
                scales: isPieLike ? {} : (isHorizontal
                    ? {
                        x: { beginAtZero: true, ticks: { precision: 0, callback: formatTick } },
                        y: { ticks: { autoSkip: false } }
                    }
                    : {
                        x: { ticks: { autoSkip: true, maxRotation: 45, minRotation: 0 } },
                        y: { beginAtZero: true, ticks: { precision: 0, callback: formatTick } }
                    })
            }
        };

        // FIX 2: attach the value-labels + target-line plugin only when the
        // consumer opted in (showValues) or supplied a targetValue. No-op for
        // pie/doughnut (the helper guards the target line for those).
        const annotationPlugin = this.buildAnnotationPlugin(type, isHorizontal);
        if (annotationPlugin) {
            config.plugins = [annotationPlugin];
        }

        try {
            this._chart = new window.Chart(canvas, config);
            this.errorMessage = null;
            this.addResizeListener();
        } catch (err) {
            this.errorMessage = `Chart render failed: ${err?.message || err}`;
        }
    }

    formatLabel(value) {
        if (value === null || value === undefined) return '—';
        const s = String(value);
        return s.length > 28 ? s.slice(0, 25) + '…' : s;
    }

    // FIX 3: honor the captured display options when formatting numeric ticks
    // and data labels. displayUnits shortens magnitudes (K/M); decimalPlaces
    // fixes the precision. Both are optional — when absent we fall back to a
    // compact default (locale grouping, trimmed decimals) so legacy callers
    // see no change.
    get displayUnits() {
        const u = String(this._options?.displayUnits || '').toLowerCase();
        return u || 'auto';
    }

    get decimalPlaces() {
        // null / undefined / '' all mean "auto". Clamp to Chart.js's sane range.
        const d = this._options?.decimalPlaces;
        if (d === null || d === undefined || d === '') return null;
        const n = Number(d);
        if (!Number.isFinite(n) || n < 0) return null;
        return Math.min(Math.round(n), 6);
    }

    // Format a numeric value for an axis tick or data label, honoring
    // displayUnits + decimalPlaces. Non-finite input is returned as-is so
    // category labels passed through (e.g. on the X axis) are untouched.
    formatNumber(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) return value;
        const units = this.displayUnits;
        const dp = this.decimalPlaces;

        // Magnitude shortening. 'shortened' and 'auto' pick the unit from the
        // value's size; 'thousands' / 'millions' force a fixed divisor.
        const shorten = (divisor, suffix) => {
            const scaled = n / divisor;
            const places = dp === null ? (Math.abs(scaled) >= 100 ? 0 : 1) : dp;
            return this.trimZeros(scaled.toFixed(places)) + suffix;
        };
        if (units === 'thousands') return shorten(1e3, 'K');
        if (units === 'millions') return shorten(1e6, 'M');
        if (units === 'shortened' || units === 'auto') {
            const abs = Math.abs(n);
            if (abs >= 1e9) return shorten(1e9, 'B');
            if (abs >= 1e6) return shorten(1e6, 'M');
            if (abs >= 1e3) return shorten(1e3, 'K');
            // Small magnitudes fall through to plain formatting below.
        }

        // 'full' (and small 'auto'/'shortened' values): plain number with
        // locale grouping. Fixed precision when decimalPlaces is set; otherwise
        // trim trailing zeros so integers stay clean.
        if (dp !== null) {
            return n.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
        }
        return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
    }

    // Drop trailing zeros / dangling decimal point from a toFixed() string so
    // "12.0K" reads as "12K" but "12.5K" is preserved.
    trimZeros(str) {
        return String(str).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
    }

    // FIX 2: resolve whether value data labels should be drawn. Gated by the
    // showValues option when the consumer provides one; defaults to OFF so we
    // don't clutter dense charts for callers that never opted in.
    get showValues() {
        return this._options?.showValues === true;
    }

    // FIX 2: the optional numeric target / reference line. Returns null when
    // absent or non-numeric so the annotation is skipped.
    get targetValue() {
        const t = this._options?.targetValue;
        if (t === null || t === undefined || t === '') return null;
        const n = Number(t);
        return Number.isFinite(n) ? n : null;
    }

    // FIX 2: build a dependency-free Chart.js plugin that draws value labels on
    // bar/line datasets and a horizontal target line. Both are pure canvas
    // draws (no npm plugin needed). Returns null when neither is requested so
    // the config stays lean for the common case.
    buildAnnotationPlugin(type, isHorizontal) {
        const wantLabels = this.showValues && (type === 'bar' || type === 'line' || type === 'horizontalbar');
        const target = this.targetValue;
        const wantTarget = target !== null && type !== 'doughnut' && type !== 'pie';
        if (!wantLabels && !wantTarget) return null;

        const self = this;
        return {
            id: 'crAnnotations',
            afterDatasetsDraw(chart) {
                const ctx = chart.ctx;
                if (wantLabels) {
                    ctx.save();
                    ctx.fillStyle = '#444';
                    ctx.font = '11px sans-serif';
                    ctx.textAlign = 'center';
                    ctx.textBaseline = 'bottom';
                    chart.data.datasets.forEach((ds, di) => {
                        const meta = chart.getDatasetMeta(di);
                        if (meta.hidden) return;
                        meta.data.forEach((el, i) => {
                            const raw = ds.data[i];
                            if (!Number.isFinite(Number(raw))) return;
                            const label = self.formatNumber(raw);
                            // Nudge the label just outside the bar/point.
                            const offset = isHorizontal ? 0 : 4;
                            if (isHorizontal) {
                                ctx.textAlign = 'left';
                                ctx.textBaseline = 'middle';
                                ctx.fillText(label, el.x + 4, el.y);
                            } else {
                                ctx.fillText(label, el.x, el.y - offset);
                            }
                        });
                    });
                    ctx.restore();
                }

                if (wantTarget) {
                    // Map the target value onto the measure axis (Y for vertical
                    // charts, X for horizontal bars) and draw a dashed line plus
                    // a small caption.
                    const measureAxis = isHorizontal ? chart.scales.x : chart.scales.y;
                    if (!measureAxis) return;
                    const area = chart.chartArea;
                    ctx.save();
                    ctx.strokeStyle = '#ba0517';
                    ctx.lineWidth = 1.5;
                    ctx.setLineDash([6, 4]);
                    ctx.beginPath();
                    if (isHorizontal) {
                        const x = measureAxis.getPixelForValue(target);
                        ctx.moveTo(x, area.top);
                        ctx.lineTo(x, area.bottom);
                    } else {
                        const y = measureAxis.getPixelForValue(target);
                        ctx.moveTo(area.left, y);
                        ctx.lineTo(area.right, y);
                    }
                    ctx.stroke();
                    ctx.setLineDash([]);
                    ctx.fillStyle = '#ba0517';
                    ctx.font = '11px sans-serif';
                    const caption = `Target: ${self.formatNumber(target)}`;
                    if (isHorizontal) {
                        const x = measureAxis.getPixelForValue(target);
                        ctx.textAlign = 'left';
                        ctx.textBaseline = 'top';
                        ctx.fillText(caption, x + 4, area.top + 2);
                    } else {
                        const y = measureAxis.getPixelForValue(target);
                        ctx.textAlign = 'right';
                        ctx.textBaseline = 'bottom';
                        ctx.fillText(caption, area.right - 4, y - 2);
                    }
                    ctx.restore();
                }
            }
        };
    }

    // Phase F1: turn a #RRGGBB into rgba(...,0.15). Used so each line series
    // gets a translucent fill matching its stroke color (legacy single-series
    // charts used a hardcoded blue tint; multi-series needs per-line tints).
    toLineFillColor(hex) {
        const m = /^#([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i.exec(hex || '');
        if (!m) return 'rgba(0, 112, 210, 0.15)';
        const r = parseInt(m[1], 16);
        const g = parseInt(m[2], 16);
        const b = parseInt(m[3], 16);
        return `rgba(${r}, ${g}, ${b}, 0.15)`;
    }
}