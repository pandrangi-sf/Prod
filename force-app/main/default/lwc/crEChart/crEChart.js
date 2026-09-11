import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ECHARTS from '@salesforce/resourceUrl/ECharts';
import { buildEChartOption, setChartPalette } from './chartTypeOptionBuilders';
import getActiveTheme from '@salesforce/apex/CR_ThemeService.getActiveTheme';

// Phase 3.1: BI-style chart component backed by Apache ECharts. Coexists with
// crChart (Chart.js); not a replacement. A future Phase 4 can deprecate
// crChart once ECharts coverage is broad enough.
//
// Lifecycle:
//   connectedCallback  → schedule lazy ECharts load (idle callback)
//   renderedCallback   → on first render after script loads, init the chart
//   property setters   → set _needsUpdate; renderedCallback re-applies option
//   disconnectedCallback → dispose chart instance, drop resize observer

// Single shared promise so multiple instances on one page don't fight over
// loading the same ~1MB bundle. Cleared on rejection so a transient failure
// doesn't poison every subsequent chart.
let _echartsLoadPromise = null;
function ensureECharts(cmp) {
    if (!_echartsLoadPromise) {
        _echartsLoadPromise = loadScript(cmp, ECHARTS)
            .then(() => window.echarts)
            .catch((err) => { _echartsLoadPromise = null; throw err; });
    }
    return _echartsLoadPromise;
}

export default class CrEChart extends LightningElement {
    @api height = 320;

    // @track on _chartType / _result / _overrides — these need to schedule
    // a re-render when an @api setter writes to them. Without @track the
    // setter fires but the LWC framework doesn't enqueue a render, so
    // renderedCallback never runs and applyUpdate never disposes/recreates
    // the ECharts instance. Same fix pattern as crChart had earlier.
    @track _chartType = 'bar';
    @api
    get chartType() { return this._chartType; }
    set chartType(value) {
        const next = value || 'bar';
        if (next === this._chartType) return;
        this._chartType = next;
        this._needsUpdate = true;
        // Microtask redraw — belt-and-suspenders for cases where
        // renderedCallback doesn't fire reliably (e.g., nested in a
        // modal). Mirrors crChart's scheduleRedraw pattern.
        this.scheduleApply();
    }

    @track _result = null;
    @api
    get result() { return this._result; }
    set result(value) {
        this._result = value;
        this._needsUpdate = true;
        this.scheduleApply();
    }

    // Optional raw ECharts option overrides for power users. Deep-merged on
    // top of the builder output; e.g. consumers can override `tooltip.formatter`
    // or `series[0].label.show` without re-implementing the whole option.
    @track _overrides = null;
    @api
    get options() { return this._overrides; }
    set options(value) {
        this._overrides = value;
        this._needsUpdate = true;
        this.scheduleApply();
    }

    // Visualization options bag — the SAME shape crChart accepted on Chart.js:
    //   { displayUnits, decimalPlaces, showValues, targetValue }
    // Kept separate from `options` (raw ECharts overrides) because these are
    // semantic knobs the builders interpret, not literal ECharts config.
    @track _vizOptions = null;
    @api
    get vizOptions() { return this._vizOptions; }
    set vizOptions(value) {
        this._vizOptions = value && typeof value === 'object' ? value : null;
        this._needsUpdate = true;
        this.scheduleApply();
    }

    // Explicit axis overrides forwarded from the widget config (column keys).
    // yAxisFields is an array (multi-series; '__count__' forces count-fallback);
    // xAxisField is a single key. Both optional — blank = auto-detect.
    @track _yAxisFields = null;
    @api
    get yAxisFields() { return this._yAxisFields; }
    set yAxisFields(value) {
        this._yAxisFields = value;
        this._needsUpdate = true;
        this.scheduleApply();
    }

    @track _xAxisField = null;
    @api
    get xAxisField() { return this._xAxisField; }
    set xAxisField(value) {
        this._xAxisField = value;
        this._needsUpdate = true;
        this.scheduleApply();
    }

    // Force an applyUpdate on the next microtask. Mirrors crChart's
    // scheduleRedraw — covers the case where the surrounding LWC lifecycle
    // doesn't trigger renderedCallback reliably (modal hosts, etc.).
    scheduleApply() {
        Promise.resolve().then(() => {
            if (this._echarts && this._needsUpdate) {
                this.applyUpdate();
            }
        });
    }

    _chart = null;
    _echarts = null;
    _resizeObserver = null;
    _needsUpdate = false;
    _loadKicked = false;

    connectedCallback() {
        // Defer the load until the page is idle so the ~1MB bundle doesn't
        // contend with initial-render work. requestIdleCallback isn't
        // universally available (Lightning Locker on older runtimes); fall
        // back to a 0ms setTimeout.
        if (this._loadKicked) return;
        this._loadKicked = true;
        const kick = () => this.bootstrap();
        if (typeof window !== 'undefined' && typeof window.requestIdleCallback === 'function') {
            window.requestIdleCallback(kick, { timeout: 2000 });
        } else {
            setTimeout(kick, 0);
        }
    }

    async bootstrap() {
        try {
            // Load the runtime brand palette (cached Apex) alongside ECharts so the
            // first build already uses the active theme's colors. Palette failure
            // is non-fatal — the built-in Orlando Health default stays in effect.
            const [echarts] = await Promise.all([ensureECharts(this), this.loadThemePalette()]);
            this._echarts = echarts;
            this._needsUpdate = true;
            // Force a render now that ECharts is loaded.
            this.applyUpdate();
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[crEChart] failed to load ECharts:', err);
        }
    }

    async loadThemePalette() {
        try {
            const theme = await getActiveTheme();
            if (theme && theme.chartPalette && theme.chartPalette.length) {
                setChartPalette(theme.chartPalette);
            }
        } catch (e) {
            // Non-fatal: keep the built-in default palette.
        }
    }

    renderedCallback() {
        if (!this._echarts) return;
        this.applyUpdate();
    }

    applyUpdate() {
        if (!this._echarts || !this._needsUpdate) return;
        const container = this.template.querySelector('.echart-container');
        if (!container) return;

        // Attach the observer up front (independent of chart creation) so a
        // hidden→shown tab or a late-resolving flex width triggers a (re)render.
        this.attachResizeObserver(container);

        // ECharts reads the container width at init time. If we init while the
        // host tab is hidden or mid-layout (clientWidth 0), it falls back to a
        // 100px chart and doesn't reliably recover. Defer creation until the
        // container actually has width — the ResizeObserver below calls back
        // into applyUpdate once it does, with _needsUpdate still true.
        if (!this._chart) {
            if (container.clientWidth === 0) return;
            try {
                this._chart = this._echarts.init(container);
            } catch (err) {
                // eslint-disable-next-line no-console
                console.error('[crEChart] echarts.init failed:', err);
                return;
            }
        }

        const columns = this._result?.columns || [];
        const rows = this._result?.rows || [];
        // Fold the axis overrides into the viz-options bag so the builders see
        // a single options object (same knobs crChart resolved on Chart.js).
        const builderOptions = {
            ...(this._vizOptions || {}),
            yAxisFields: this._yAxisFields,
            xAxisField: this._xAxisField
        };
        const baseOption = buildEChartOption(this._chartType, columns, rows, builderOptions);
        const merged = this._overrides
            ? this.deepMerge(baseOption, this._overrides)
            : baseOption;
        // notMerge=true clears previous options so a chartType switch
        // (e.g., bar → treemap) doesn't keep stale config keys around.
        // try/catch surfaces the real ECharts error instead of a cross-origin
        // "Script error. null" if a malformed option slips through.
        try {
            this._chart.setOption(merged, true);
            this._needsUpdate = false;
            // If the width resolved on this very tick (tab just activated),
            // refit on the next frame so the chart fills its container.
            this.scheduleResize();
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[crEChart] setOption failed:', err);
        }
    }

    // Imperative PNG export. ECharts' getDataURL reads from the canvas backing
    // store, so it works straight through the shadow boundary (unlike DOM-capture
    // libraries). Returns a data: URL or null if the chart isn't ready.
    @api
    getPngDataUrl() {
        if (!this._chart) return null;
        try {
            return this._chart.getDataURL({ type: 'png', pixelRatio: 2, backgroundColor: '#ffffff' });
        } catch (e) {
            // eslint-disable-next-line no-console
            console.error('[crEChart] getDataURL failed:', e);
            return null;
        }
    }

    scheduleResize() {
        if (typeof window === 'undefined') return;
        const raf = window.requestAnimationFrame
            ? window.requestAnimationFrame.bind(window)
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            : (cb) => setTimeout(cb, 16);
        raf(() => {
            if (this._chart) {
                try { this._chart.resize(); } catch (e) { /* disposed mid-flight */ }
            }
        });
    }

    attachResizeObserver(container) {
        if (typeof ResizeObserver !== 'function' || this._resizeObserver) return;
        this._resizeObserver = new ResizeObserver(() => {
            if (this._chart) {
                this._chart.resize();
            } else if (container.clientWidth > 0 && this._needsUpdate) {
                // Container just became visible/sized — create + render now.
                this.applyUpdate();
            }
        });
        this._resizeObserver.observe(container);
    }

    disconnectedCallback() {
        if (this._resizeObserver) {
            this._resizeObserver.disconnect();
            this._resizeObserver = null;
        }
        if (this._chart) {
            this._chart.dispose();
            this._chart = null;
        }
    }

    get containerStyle() {
        const h = Number.parseInt(this.height, 10);
        const px = Number.isFinite(h) && h > 0 ? h : 320;
        return `height:${px}px; width:100%;`;
    }

    // Shallow-deep merge: arrays and primitives in `overrides` win; plain
    // objects recurse. Sufficient for ECharts option shape (no class
    // instances, no Maps).
    deepMerge(base, overrides) {
        if (!overrides || typeof overrides !== 'object' || Array.isArray(overrides)) {
            return overrides ?? base;
        }
        const out = Array.isArray(base) ? [...(base || [])] : { ...(base || {}) };
        for (const k of Object.keys(overrides)) {
            const ov = overrides[k];
            const bv = out[k];
            if (ov && typeof ov === 'object' && !Array.isArray(ov) && bv && typeof bv === 'object' && !Array.isArray(bv)) {
                out[k] = this.deepMerge(bv, ov);
            } else {
                out[k] = ov;
            }
        }
        return out;
    }
}