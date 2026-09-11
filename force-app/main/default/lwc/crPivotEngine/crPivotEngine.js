// Pure pivot/cross-tab transform. Takes the QueryResult-shaped {columns, rows}
// our engine returns plus a pivot config, and produces a new {columns, rows}
// in the SAME shape — so it renders directly through c-cr-data-grid (or any
// table). Implemented in plain JS (not AlaSQL PIVOT) for deterministic,
// dependency-free, dynamic-column behavior and zero added latency.
//
// config: {
//   rowField:    column key to group down the rows (required)
//   colField:    column key whose distinct values become pivot columns
//                (optional — omit for a simple grouped aggregate)
//   measureField:column key to aggregate (required unless agg === 'count')
//   agg:         'sum' | 'count' | 'avg' | 'min' | 'max'  (default 'sum')
// }

const AGGS = new Set(['sum', 'count', 'avg', 'min', 'max']);
const BLANK = '(blank)';

function labelFor(columns, key) {
    const col = (columns || []).find((c) => c.key === key);
    return col ? (col.label || col.key) : key;
}

function norm(value) {
    return value === null || value === undefined || value === '' ? BLANK : String(value);
}

// Fold a list of numeric values into a single aggregate.
function aggregate(values, agg) {
    if (agg === 'count') return values.length;
    const nums = values.map((v) => Number(v)).filter((n) => Number.isFinite(n));
    if (nums.length === 0) return null;
    switch (agg) {
        case 'avg': return nums.reduce((a, b) => a + b, 0) / nums.length;
        case 'min': return Math.min(...nums);
        case 'max': return Math.max(...nums);
        case 'sum':
        default: return nums.reduce((a, b) => a + b, 0);
    }
}

/**
 * Compute a pivot table. Returns { columns, rows, error }.
 * On invalid config returns { error } and empty columns/rows.
 */
export function computePivot(result, config) {
    const columns = (result && result.columns) || [];
    const rows = (result && result.rows) || [];
    const cfg = config || {};
    const agg = AGGS.has(cfg.agg) ? cfg.agg : 'sum';
    const { rowField, colField, measureField } = cfg;

    if (!rowField) {
        return { error: 'Pick a Rows field to pivot.', columns: [], rows: [] };
    }
    if (agg !== 'count' && !measureField) {
        return { error: 'Pick a Measure field (or use Count).', columns: [], rows: [] };
    }
    if (!rows.length) {
        return { error: 'No rows to pivot.', columns: [], rows: [] };
    }

    const measureLabel = agg === 'count'
        ? 'Count'
        : `${agg.charAt(0).toUpperCase() + agg.slice(1)} of ${labelFor(columns, measureField)}`;

    // --- Simple grouped aggregate (no column dimension) ---
    if (!colField) {
        const groups = new Map();
        for (const r of rows) {
            const rk = norm(r[rowField]);
            if (!groups.has(rk)) groups.set(rk, []);
            groups.get(rk).push(agg === 'count' ? 1 : r[measureField]);
        }
        const outCols = [
            { key: '__row', label: labelFor(columns, rowField), numeric: false },
            { key: '__measure', label: measureLabel, numeric: true }
        ];
        const outRows = Array.from(groups.entries()).map(([rk, vals]) => ({
            __row: rk,
            __measure: aggregate(vals, agg)
        }));
        return { columns: outCols, rows: outRows };
    }

    // --- Full cross-tab (row dimension × column dimension) ---
    // distinct column values (sorted), and a nested map rowKey -> colKey -> [values]
    const colValues = [];
    const colSeen = new Set();
    const matrix = new Map();
    for (const r of rows) {
        const rk = norm(r[rowField]);
        const ck = norm(r[colField]);
        if (!colSeen.has(ck)) { colSeen.add(ck); colValues.push(ck); }
        if (!matrix.has(rk)) matrix.set(rk, new Map());
        const rowMap = matrix.get(rk);
        if (!rowMap.has(ck)) rowMap.set(ck, []);
        rowMap.get(ck).push(agg === 'count' ? 1 : r[measureField]);
    }
    colValues.sort((a, b) => a.localeCompare(b));

    // Column keys are remapped to safe synthetic keys (p0, p1, …) so downstream
    // grids never choke on dotted/odd distinct values; labels keep the real value.
    const outCols = [{ key: '__row', label: labelFor(columns, rowField), numeric: false }];
    const colKeyByValue = new Map();
    colValues.forEach((cv, i) => {
        const k = `p${i}`;
        colKeyByValue.set(cv, k);
        outCols.push({ key: k, label: cv, numeric: true });
    });
    outCols.push({ key: '__total', label: 'Total', numeric: true });

    const outRows = Array.from(matrix.entries()).map(([rk, rowMap]) => {
        const out = { __row: rk };
        const rowTotalVals = [];
        for (const cv of colValues) {
            const vals = rowMap.get(cv) || [];
            out[colKeyByValue.get(cv)] = vals.length ? aggregate(vals, agg) : null;
            rowTotalVals.push(...vals);
        }
        out.__total = rowTotalVals.length ? aggregate(rowTotalVals, agg) : null;
        return out;
    });

    return { columns: outCols, rows: outRows };
}