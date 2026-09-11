// Pure functions: take the QueryResult-shaped {columns, rows} payload our
// Apex engine returns and produce an Apache ECharts `option` object. One
// builder per chart type so each is independently testable and a future
// builder can be added without touching the others.
//
// Parity note: the cartesian (bar / horizontal-bar / line / area) and pie /
// donut builders mirror the behavior crChart implemented on Chart.js — axis
// auto-detect, explicit x/y overrides, multi-series, count-fallback with
// Top-N + "Other" bucketing, number formatting (displayUnits / decimalPlaces),
// optional data labels (showValues) and a target reference line. This is what
// lets ECharts be the single engine without regressing the Chart.js look.
//
// All builders accept an optional trailing `options` arg:
//   { yAxisFields, xAxisField, displayUnits, decimalPlaces, showValues,
//     targetValue }
// Older callers that pass only (columns, rows) are unaffected.

// Orlando Health brand palette. Orange + teal lead (the brand series colors,
// matching the OH leadership decks); slots 3-8 are accessible, colorblind-distinct
// extensions validated via the dataviz skill (light mode, adjacent CVD ΔE ~20).
// The brand teal (#6ba9b8) is intentionally low-chroma — kept with the value
// labels/legend the charts already render as secondary encoding.
// Mutable so the runtime brand theme (CR_ThemeService) can override it; defaults
// to the built-in Orlando Health palette. crEChart calls setChartPalette() with the
// active theme's colors before the first chart build.
let ACTIVE_PALETTE = [
    '#e8631c', '#6ba9b8', '#7a4fa3', '#3e8e5a', '#2c6ea8',
    '#c0392b', '#be7a0a', '#b5507a'
];

export function setChartPalette(colors) {
    if (Array.isArray(colors) && colors.length) {
        ACTIVE_PALETTE = colors.slice();
    }
}

const NUMERIC_DATA_TYPES = new Set(['CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT', 'NUMBER']);
const TOP_N = 24;        // cap categories before lumping the rest into "Other"
const LABEL_MAX = 28;    // truncate long category labels (matches crChart)

// ---------------------------------------------------------------------------
// Column resolution — ported from crChart so the engine swap is behavior-safe.
// ---------------------------------------------------------------------------

function pickNumericColumn(columns) {
    if (!columns || !columns.length) return null;
    return columns.find((c) => c.numeric) || columns[1] || null;
}

function pickCategoryColumn(columns) {
    if (!columns || !columns.length) return null;
    return columns.find((c) => !c.numeric) || columns[0] || null;
}

// Single best numeric column. Honors an explicit yAxisFields[0] override, then
// the engine's numeric flag, then dataType, then a sampled row value.
function findValueColumn(columns, rows, options) {
    if (!columns || !columns.length) return null;
    const yFields = options && Array.isArray(options.yAxisFields) ? options.yAxisFields : null;
    const explicitYKey = yFields && yFields.length > 0 && yFields[0] !== '__count__' ? yFields[0] : null;
    if (explicitYKey) {
        const explicitCol = columns.find((c) => c.key === explicitYKey);
        if (explicitCol) return explicitCol;
    }
    let col = columns.find((c) => c.numeric === true);
    if (col) return col;
    col = columns.find((c) => NUMERIC_DATA_TYPES.has(String(c.dataType || '').toUpperCase()));
    if (col) return col;
    if (rows && rows.length) {
        const sample = rows[0];
        col = columns.find((c) => Number.isFinite(Number(sample && sample[c.key])));
    }
    return col || null;
}

// All value columns for multi-series. Multiple only when the yAxisFields
// override resolves more than one key; otherwise single (auto-detect). The
// '__count__' sentinel forces the count-fallback path (returns []).
function findValueColumns(columns, rows, options) {
    if (!columns || !columns.length) return [];
    const yFields = options && Array.isArray(options.yAxisFields) ? options.yAxisFields : null;
    if (yFields && yFields[0] === '__count__') return [];
    if (yFields && yFields.length > 0) {
        const matched = yFields.map((key) => columns.find((c) => c.key === key)).filter(Boolean);
        if (matched.length > 0) return matched;
    }
    const single = findValueColumn(columns, rows, options);
    return single ? [single] : [];
}

function findLabelColumn(columns, valueColumn, options) {
    if (!columns || !columns.length) return null;
    const xKey = options && options.xAxisField;
    if (xKey) {
        const explicitCol = columns.find((c) => c.key === xKey);
        if (explicitCol) return explicitCol;
    }
    const candidate = columns.find((c) => c !== valueColumn && (!valueColumn || c.key !== valueColumn.key));
    return candidate || columns[0];
}

function pickGroupColumn(columns, options) {
    if (!columns || !columns.length) return null;
    const xKey = options && options.xAxisField;
    if (xKey) {
        const explicit = columns.find((c) => c.key === xKey);
        if (explicit) return explicit;
    }
    const isIdLike = (c) => /Id$/.test(String(c.key || '')) || c.dataType === 'ID' || c.dataType === 'REFERENCE';
    return columns.find((c) => !isIdLike(c)) || columns[0];
}

function truncateLabel(value) {
    if (value === null || value === undefined) return '—';
    const s = String(value);
    return s.length > LABEL_MAX ? s.slice(0, LABEL_MAX - 3) + '…' : s;
}

// Resolve {columns, rows, options} into { labels, series:[{name,data}] } or
// { error }. Mirrors crChart.draw(): aggregate path when a numeric column
// exists, else count rows per category with Top-N + "Other" bucketing.
function resolveModel(columns, rows, options) {
    const opts = options || {};
    if (!rows || rows.length === 0) {
        return { error: 'Not enough data to chart. Clear a filter or pick a different time grain.' };
    }
    const valueColumns = findValueColumns(columns, rows, opts);
    let labels;
    let series;

    if (valueColumns.length > 0) {
        const labelColumn = findLabelColumn(columns, valueColumns[0], opts);
        labels = rows.map((row) => truncateLabel(labelColumn ? row[labelColumn.key] : ''));
        series = valueColumns.map((col) => ({
            name: col.label || col.key,
            data: rows.map((row) => Number(row && row[col.key]) || 0)
        }));
    } else {
        const groupColumn = pickGroupColumn(columns, opts);
        if (!groupColumn) {
            return { error: 'No chartable columns. Add at least one column to the report.' };
        }
        const counts = new Map();
        for (const row of rows) {
            const raw = row && row[groupColumn.key];
            const key = raw === null || raw === undefined || raw === '' ? '(blank)' : String(raw);
            counts.set(key, (counts.get(key) || 0) + 1);
        }
        const entries = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);
        if (entries.length > TOP_N) {
            const overflow = entries.slice(TOP_N).reduce((sum, e) => sum + e[1], 0);
            entries.splice(TOP_N);
            entries.push(['Other', overflow]);
        }
        labels = entries.map((e) => truncateLabel(e[0]));
        series = [{
            name: `Count by ${groupColumn.label || groupColumn.key}`,
            data: entries.map((e) => e[1])
        }];
    }

    if (!labels || labels.length === 0) {
        return { error: 'Not enough data to chart. Clear a filter or pick a different time grain.' };
    }
    return { labels, series };
}

// ---------------------------------------------------------------------------
// Number formatting — ported from crChart.formatNumber.
// ---------------------------------------------------------------------------

function resolveDecimalPlaces(options) {
    const d = options && options.decimalPlaces;
    if (d === null || d === undefined || d === '') return null;
    const n = Number(d);
    if (!Number.isFinite(n) || n < 0) return null;
    return Math.min(Math.round(n), 6);
}

function trimZeros(str) {
    return String(str).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
}

function makeNumberFormatter(options) {
    const units = String((options && options.displayUnits) || 'auto').toLowerCase();
    const dp = resolveDecimalPlaces(options);
    return function formatNumber(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) return value;
        const shorten = (divisor, suffix) => {
            const scaled = n / divisor;
            const places = dp === null ? (Math.abs(scaled) >= 100 ? 0 : 1) : dp;
            return trimZeros(scaled.toFixed(places)) + suffix;
        };
        if (units === 'thousands') return shorten(1e3, 'K');
        if (units === 'millions') return shorten(1e6, 'M');
        if (units === 'shortened' || units === 'auto') {
            const abs = Math.abs(n);
            if (abs >= 1e9) return shorten(1e9, 'B');
            if (abs >= 1e6) return shorten(1e6, 'M');
            if (abs >= 1e3) return shorten(1e3, 'K');
        }
        if (dp !== null) {
            return n.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
        }
        return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
    };
}

function targetMarkLine(options, fmt, isHorizontal) {
    const t = options && options.targetValue;
    if (t === null || t === undefined || t === '') return undefined;
    const n = Number(t);
    if (!Number.isFinite(n)) return undefined;
    // The reference line sits on the VALUE axis — that's xAxis for horizontal
    // bars, yAxis otherwise.
    const datum = isHorizontal ? { xAxis: n } : { yAxis: n };
    return {
        silent: true,
        symbol: 'none',
        lineStyle: { color: '#ba0517', type: 'dashed', width: 1.5 },
        label: { formatter: () => `Target: ${fmt(n)}`, color: '#ba0517', position: 'insideEndTop' },
        data: [datum]
    };
}

// ---------------------------------------------------------------------------
// Cartesian builders: bar / horizontal-bar / line / area.
// ---------------------------------------------------------------------------

function buildCartesian(columns, rows, options, kind) {
    const model = resolveModel(columns, rows, options);
    if (model.error) return emptyOption(model.error);
    const opts = options || {};
    const fmt = makeNumberFormatter(opts);
    const { labels, series } = model;
    const isHorizontal = kind === 'horizontalbar';
    const isLine = kind === 'line' || kind === 'area';
    const isArea = kind === 'area';
    const isMulti = series.length > 1;
    const showValues = opts.showValues === true;

    // Single-point line is meaningless — surface the same guidance crChart did.
    if (isLine && labels.length === 1) {
        return emptyOption('Sparse data — a line chart needs at least 2 points. Try a bar chart or clear a filter.');
    }

    const valueAxis = {
        type: 'value',
        axisLabel: { formatter: (v) => fmt(v) }
    };
    const categoryAxis = {
        type: 'category',
        data: labels,
        axisLabel: {
            rotate: !isHorizontal && labels.length > 6 ? (labels.length > 20 ? 45 : 30) : 0,
            // interval:0 forces EVERY tick label to draw. With many categories they
            // collide into an unreadable smear (the "100 daily bars" failure), so let
            // ECharts skip labels once the axis gets dense, and drop any that overlap.
            interval: labels.length > 12 ? 'auto' : 0,
            hideOverlap: true
        }
    };

    const mark = targetMarkLine(opts, fmt, isHorizontal);

    const echSeries = series.map((s, idx) => {
        const color = isMulti ? ACTIVE_PALETTE[idx % ACTIVE_PALETTE.length] : ACTIVE_PALETTE[0];
        const base = {
            name: s.name,
            data: s.data,
            type: isLine ? 'line' : 'bar',
            itemStyle: { color },
            label: showValues
                ? { show: true, position: isHorizontal ? 'right' : 'top', formatter: (p) => fmt(p.value) }
                : { show: false }
        };
        if (!isLine) base.barMaxWidth = 60;
        if (isLine) {
            base.smooth = true;
            base.lineStyle = { color };
            if (isArea) base.areaStyle = { opacity: 0.15 };
        }
        if (idx === 0 && mark) base.markLine = mark;
        return base;
    });

    return {
        color: ACTIVE_PALETTE,
        tooltip: {
            trigger: 'axis',
            axisPointer: { type: isLine ? 'line' : 'shadow' },
            valueFormatter: (v) => fmt(v)
        },
        legend: { show: series.length > 1, bottom: 0, type: 'scroll' },
        grid: { left: '3%', right: '4%', bottom: series.length > 1 ? '12%' : '8%', top: '8%', containLabel: true },
        xAxis: isHorizontal ? valueAxis : categoryAxis,
        yAxis: isHorizontal ? categoryAxis : valueAxis,
        series: echSeries
    };
}

export function buildBarOption(columns, rows, options) {
    return buildCartesian(columns, rows, options, 'bar');
}

export function buildHorizontalBarOption(columns, rows, options) {
    return buildCartesian(columns, rows, options, 'horizontalbar');
}

export function buildLineOption(columns, rows, options) {
    return buildCartesian(columns, rows, options, 'line');
}

export function buildAreaOption(columns, rows, options) {
    return buildCartesian(columns, rows, options, 'area');
}

// ---------------------------------------------------------------------------
// Pie / donut. Single-series only (collapses to the first series); slices are
// the resolved labels. Donut is a pie with an inner radius.
// ---------------------------------------------------------------------------

function buildPieLike(columns, rows, options, isDonut) {
    const model = resolveModel(columns, rows, options);
    if (model.error) return emptyOption(model.error);
    const opts = options || {};
    const fmt = makeNumberFormatter(opts);
    const { labels, series } = model;
    const first = series[0];
    const data = labels.map((name, i) => ({ name, value: first.data[i] }));
    return {
        color: ACTIVE_PALETTE,
        tooltip: {
            trigger: 'item',
            formatter: (p) => `${p.name}: ${fmt(p.value)} (${p.percent}%)`
        },
        legend: { show: true, bottom: 0, type: 'scroll' },
        series: [{
            type: 'pie',
            radius: isDonut ? ['40%', '70%'] : '70%',
            center: ['50%', '45%'],
            data,
            label: opts.showValues === true
                ? { show: true, formatter: (p) => `${p.name}: ${fmt(p.value)}` }
                : { show: true, formatter: '{b}' },
            emphasis: { itemStyle: { shadowBlur: 10, shadowOffsetX: 0, shadowColor: 'rgba(0,0,0,0.3)' } }
        }]
    };
}

export function buildPieOption(columns, rows, options) {
    return buildPieLike(columns, rows, options, false);
}

export function buildDonutOption(columns, rows, options) {
    return buildPieLike(columns, rows, options, true);
}

// ---------------------------------------------------------------------------
// Heatmap / treemap / gauge — unchanged BI-style builders.
// ---------------------------------------------------------------------------

// Heatmap requires THREE columns: two categorical (x and y axes) + one numeric
// (cell intensity). Picks the first two non-numeric columns as axes and the
// first numeric column as the value. Falls back to a single-axis view if only
// two columns are available.
export function buildHeatmapOption(columns, rows) {
    if (!columns || columns.length < 2 || !rows || !rows.length) {
        return emptyOption('Heatmap needs at least 2 categorical + 1 numeric column');
    }
    const nonNumeric = columns.filter((c) => !c.numeric);
    const xCol = nonNumeric[0] || columns[0];
    const yCol = nonNumeric[1] || columns[1];
    const valCol = pickNumericColumn(columns) || columns[columns.length - 1];
    if (!xCol || !yCol || !valCol || xCol.key === yCol.key) {
        return emptyOption('Heatmap needs distinct x, y, and value columns');
    }
    const xValues = [...new Set(rows.map((r) => String(r[xCol.key] ?? '')))];
    const yValues = [...new Set(rows.map((r) => String(r[yCol.key] ?? '')))];
    const xIndex = new Map(xValues.map((v, i) => [v, i]));
    const yIndex = new Map(yValues.map((v, i) => [v, i]));
    const data = rows.map((r) => [
        xIndex.get(String(r[xCol.key] ?? '')),
        yIndex.get(String(r[yCol.key] ?? '')),
        Number(r[valCol.key]) || 0
    ]);
    const values = data.map((d) => d[2]);
    const min = Math.min(...values);
    const max = Math.max(...values);
    return {
        tooltip: {
            position: 'top',
            formatter: (p) => `${xValues[p.data[0]]} / ${yValues[p.data[1]]}: ${p.data[2]}`
        },
        grid: { left: '10%', right: '5%', bottom: '15%', top: '10%' },
        xAxis: { type: 'category', data: xValues, splitArea: { show: true }, axisLabel: { rotate: xValues.length > 6 ? 30 : 0 } },
        yAxis: { type: 'category', data: yValues, splitArea: { show: true } },
        visualMap: {
            min, max,
            calculable: true,
            orient: 'horizontal',
            left: 'center',
            bottom: '0%',
            inRange: { color: ['#e8f4f8', '#0070d2', '#04256b'] }
        },
        series: [{
            type: 'heatmap',
            data,
            label: { show: max - min < 100 },
            emphasis: { itemStyle: { shadowBlur: 10, shadowColor: 'rgba(0,0,0,0.5)' } }
        }]
    };
}

// Treemap: one categorical column (the leaf name) + one numeric column (the
// size). Two-level hierarchies are supported when a second categorical column
// is present — used as the parent grouping.
export function buildTreemapOption(columns, rows) {
    if (!columns || !columns.length || !rows || !rows.length) {
        return emptyOption('Treemap needs at least 1 category + 1 numeric column');
    }
    const cat1 = pickCategoryColumn(columns);
    const numericCols = columns.filter((c) => c.numeric);
    const val = numericCols[0] || columns[columns.length - 1];
    if (!cat1 || !val || cat1.key === val.key) {
        return emptyOption('Treemap needs distinct category and value columns');
    }
    const cat2 = columns.find((c) => !c.numeric && c.key !== cat1.key);

    let data;
    if (cat2) {
        const groups = new Map();
        for (const r of rows) {
            const parent = String(r[cat1.key] ?? '');
            const leaf = String(r[cat2.key] ?? '');
            const value = Number(r[val.key]) || 0;
            if (!groups.has(parent)) groups.set(parent, []);
            groups.get(parent).push({ name: leaf, value });
        }
        data = [...groups.entries()].map(([name, children]) => ({
            name,
            value: children.reduce((sum, c) => sum + c.value, 0),
            children
        }));
    } else {
        data = rows.map((r) => ({
            name: String(r[cat1.key] ?? ''),
            value: Number(r[val.key]) || 0
        }));
    }

    return {
        color: ACTIVE_PALETTE,
        tooltip: {
            formatter: (info) => {
                const treePathInfo = info.treePathInfo || [];
                const path = treePathInfo.slice(1).map((p) => p.name).join(' / ') || info.name;
                return `${path}: ${info.value}`;
            }
        },
        series: [{
            type: 'treemap',
            data,
            roam: false,
            nodeClick: false,
            label: { show: true, formatter: '{b}' },
            upperLabel: { show: !!cat2, height: 24 },
            levels: cat2 ? [
                { itemStyle: { borderColor: '#fff', borderWidth: 2, gapWidth: 2 } },
                { itemStyle: { borderColor: '#fff', borderWidth: 1, gapWidth: 1 } }
            ] : undefined
        }]
    };
}

// Gauge: single numeric value, optional second numeric for max/target.
export function buildGaugeOption(columns, rows) {
    if (!columns || !columns.length || !rows || !rows.length) {
        return emptyOption('Gauge needs at least 1 numeric column');
    }
    const valCol = pickNumericColumn(columns);
    if (!valCol) {
        return emptyOption('Gauge needs a numeric column');
    }
    const value = Number(rows[0][valCol.key]) || 0;
    const numericCols = columns.filter((c) => c.numeric);
    const maxCol = numericCols.find((c) => c.key !== valCol.key);
    const max = maxCol
        ? (Number(rows[0][maxCol.key]) || Math.max(100, value * 1.5))
        : (value <= 100 ? 100 : Math.pow(10, Math.ceil(Math.log10(value || 1))));

    return {
        series: [{
            type: 'gauge',
            min: 0,
            max,
            progress: { show: true, width: 18 },
            axisLine: { lineStyle: { width: 18 } },
            axisTick: { show: false },
            splitLine: { length: 12, lineStyle: { width: 2, color: '#fff' } },
            axisLabel: { distance: 22, color: '#999', fontSize: 12 },
            anchor: { show: true, showAbove: true, size: 18, itemStyle: { borderWidth: 2 } },
            title: { show: true, offsetCenter: [0, '70%'], fontSize: 14 },
            detail: {
                valueAnimation: true,
                offsetCenter: [0, '-10%'],
                formatter: '{value}',
                color: 'inherit',
                fontSize: 30
            },
            data: [{ value, name: valCol.label || valCol.key }]
        }]
    };
}

function emptyOption(message) {
    return {
        title: {
            text: message,
            left: 'center',
            top: 'middle',
            textStyle: { color: '#999', fontWeight: 'normal', fontSize: 14 }
        }
    };
}

// Dispatcher: routes (chartType, columns, rows, options) to the correct
// builder. Falls back to bar for unknown types so a new chartType picklist
// value doesn't crash old code. `options` is optional and only consumed by the
// cartesian + pie/donut builders.
export function buildEChartOption(chartType, columns, rows, options) {
    switch ((chartType || 'bar').toLowerCase()) {
        case 'heatmap':
            return buildHeatmapOption(columns, rows);
        case 'treemap':
            return buildTreemapOption(columns, rows);
        case 'gauge':
            return buildGaugeOption(columns, rows);
        case 'line':
            return buildLineOption(columns, rows, options);
        case 'area':
            return buildAreaOption(columns, rows, options);
        case 'pie':
            return buildPieOption(columns, rows, options);
        case 'donut':
        case 'doughnut':
            return buildDonutOption(columns, rows, options);
        case 'horizontal':
        case 'horizontalbar':
        case 'hbar':
            return buildHorizontalBarOption(columns, rows, options);
        case 'bar':
        case 'column':
        default:
            return buildBarOption(columns, rows, options);
    }
}