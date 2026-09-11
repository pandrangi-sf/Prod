// Chart-type Advisor
// ------------------
// Pure utility module. Takes a report's columns + loaded rows and returns
// a fit verdict for each known chart type, so the picker can highlight the
// ones that suit the data and warn off the ones that don't.
//
// The advisor never blocks — it only nudges. Callers may pass the verdicts
// through to a lightning-combobox via icon + description on each option.
//
// Verdict shape:
//   { fit: 'recommended' | 'available' | 'notFitting', caption: string }
//
// Public API:
//   computeDataSignature(columns, rows) -> signature object
//   scoreChartTypes(columns, rows)      -> array of { type, fit, caption }

const NUMERIC_TYPES = new Set(['DOUBLE', 'INTEGER', 'CURRENCY', 'PERCENT', 'AGGREGATE']);
const DATE_TYPES = new Set(['DATE', 'DATETIME']);
// Max rows we'll scan for cardinality. Reports can be huge; sampling is
// fine for picker decisions. If the first 500 rows have >25 distinct
// values, additional rows won't change the verdict.
const CARDINALITY_SAMPLE = 500;

function typeOf(col) {
    return String((col && col.dataType) || '').toUpperCase();
}

function isNumericCol(col) {
    return NUMERIC_TYPES.has(typeOf(col)) || col.numeric === true;
}

function isDateCol(col) {
    return DATE_TYPES.has(typeOf(col));
}

function isDimensionCol(col) {
    // Anything that's not numeric — date columns count as dimensions too
    // because charts group/bucket by them.
    return !isNumericCol(col);
}

export function computeDataSignature(columns, rows) {
    const cols = Array.isArray(columns) ? columns : [];
    const sample = Array.isArray(rows) ? rows.slice(0, CARDINALITY_SAMPLE) : [];

    const measures = cols.filter(isNumericCol);
    const dimensions = cols.filter(isDimensionCol);
    const dateColumns = cols.filter(isDateCol);

    // Cardinality of each dimension (number of distinct non-empty values).
    let maxCardinality = 0;
    let primaryDimensionLabel = dimensions[0] ? (dimensions[0].label || dimensions[0].key) : null;
    let primaryDimensionCardinality = 0;
    for (const dim of dimensions) {
        const set = new Set();
        for (const r of sample) {
            const v = r[dim.key];
            if (v === null || v === undefined || v === '') continue;
            const sv = typeof v === 'object' ? JSON.stringify(v) : String(v);
            set.add(sv);
        }
        if (set.size > maxCardinality) maxCardinality = set.size;
        if (dim === dimensions[0]) primaryDimensionCardinality = set.size;
    }

    return {
        columnCount: cols.length,
        rowCount: sample.length,
        sampledRowCount: sample.length,
        truncated: rows && rows.length > sample.length,
        dimensionCount: dimensions.length,
        measureCount: measures.length,
        dateColumnCount: dateColumns.length,
        hasDate: dateColumns.length > 0,
        maxCardinality,
        primaryDimensionLabel,
        primaryDimensionCardinality
    };
}

// Each rule returns a { fit, caption } verdict for the chart type given the
// signature. Lower-bar checks return notFitting early. Available is the
// permissive default; recommended is reserved for shapes that genuinely
// suit the chart type.
const RULES = [
    {
        type: 'bar',
        label: 'Bar',
        evaluate: (s) => {
            if (s.dimensionCount === 0) return verdict('notFitting', 'Needs at least one dimension column.');
            if (s.measureCount === 0 && s.maxCardinality === 0) return verdict('notFitting', 'No data to plot.');
            if (s.maxCardinality > 25) {
                return verdict('available', `${s.maxCardinality} categories — try Horizontal Bar for readability.`);
            }
            return verdict('recommended', 'Dimension on the x-axis, measure on the y-axis.');
        }
    },
    {
        type: 'horizontal',
        label: 'Horizontal Bar',
        evaluate: (s) => {
            if (s.dimensionCount === 0) return verdict('notFitting', 'Needs at least one dimension column.');
            if (s.measureCount === 0 && s.maxCardinality === 0) return verdict('notFitting', 'No data to plot.');
            if (s.maxCardinality > 10) {
                return verdict('recommended', `${s.maxCardinality} categories fit well on horizontal bars.`);
            }
            return verdict('available', 'Works for any category count.');
        }
    },
    {
        type: 'line',
        label: 'Line',
        evaluate: (s) => {
            if (!s.hasDate) {
                return verdict('available', 'Line charts work best with a date or time axis.');
            }
            if (s.measureCount === 0) {
                return verdict('available', 'Counts rows over time — fine, but a measure would be richer.');
            }
            return verdict('recommended', 'Date axis + measure — ideal for trends.');
        }
    },
    {
        type: 'area',
        label: 'Area',
        evaluate: (s) => {
            if (!s.hasDate) {
                return verdict('available', 'Area charts read best with a date or time axis.');
            }
            if (s.measureCount === 0) {
                return verdict('available', 'Counts rows over time — a measure makes the filled area meaningful.');
            }
            return verdict('recommended', 'Date axis + measure — good for showing volume/cumulative trends.');
        }
    },
    {
        type: 'donut',
        label: 'Donut',
        evaluate: (s) => {
            if (s.dimensionCount === 0) return verdict('notFitting', 'Needs a dimension to slice.');
            if (s.maxCardinality > 25) {
                return verdict('notFitting',
                    `Too many categories (${s.maxCardinality}). Donut works best with ≤ 10 slices — try Horizontal Bar.`);
            }
            if (s.maxCardinality > 10) {
                return verdict('available', `Hard to read with ${s.maxCardinality} slices — works for ≤ 10.`);
            }
            return verdict('recommended', 'Single dimension, low cardinality — clean donut.');
        }
    },
    {
        type: 'pie',
        label: 'Pie',
        evaluate: (s) => {
            if (s.dimensionCount === 0) return verdict('notFitting', 'Needs a dimension to slice.');
            if (s.maxCardinality > 25) {
                return verdict('notFitting',
                    `Too many categories (${s.maxCardinality}). Pie is hard to read with > 10 slices — try Horizontal Bar.`);
            }
            if (s.maxCardinality > 10) {
                return verdict('available', `Hard to read with ${s.maxCardinality} slices — works for ≤ 10.`);
            }
            return verdict('recommended', 'Single dimension, low cardinality — clean pie.');
        }
    },
    {
        type: 'heatmap',
        label: 'Heatmap',
        evaluate: (s) => {
            if (s.dimensionCount < 2) {
                return verdict('notFitting', `Needs at least 2 dimensions (you have ${s.dimensionCount}).`);
            }
            if (s.measureCount === 0) {
                return verdict('available', 'Counts rows in each cell — fine, but a measure would be richer.');
            }
            return verdict('recommended', 'Two dimensions + a measure — heatmap is a strong fit.');
        }
    },
    {
        type: 'treemap',
        label: 'Treemap',
        evaluate: (s) => {
            if (s.dimensionCount === 0) return verdict('notFitting', 'Needs a dimension to nest.');
            if (s.measureCount === 0 && s.maxCardinality === 0) return verdict('notFitting', 'No data to plot.');
            if (s.maxCardinality > 200) {
                return verdict('available', `${s.maxCardinality} categories — works, but Horizontal Bar may scan better.`);
            }
            return verdict('recommended', 'Good for many categories with proportional sizing.');
        }
    },
    {
        type: 'gauge',
        label: 'Gauge',
        evaluate: (s) => {
            if (s.measureCount === 0) return verdict('notFitting', 'Gauge needs a numeric measure to display.');
            if (s.rowCount > 1 && s.dimensionCount > 0) {
                return verdict('available', 'Gauge shows a single value — will display only the first row.');
            }
            return verdict('recommended', 'Single measure value — ideal for a KPI.');
        }
    },
    {
        type: 'metric',
        label: 'Metric',
        evaluate: (s) => {
            if (s.measureCount === 0) {
                return verdict('available', 'Shows a row count when there is no numeric measure.');
            }
            // A single measure with no/one dimension and very few rows is the
            // canonical KPI shape — one headline number.
            if (s.measureCount === 1 && s.dimensionCount <= 1 && s.rowCount <= 1) {
                return verdict('recommended', 'A single number — ideal for a headline KPI.');
            }
            return verdict('available', 'Displays the first row’s measure as a single number.');
        }
    },
    {
        type: 'table',
        label: 'Table',
        evaluate: (s) => {
            // Tables can render anything, so they're never notFitting. They win
            // when the data is too wide or too granular for a chart to read well.
            if (s.columnCount > 4) {
                return verdict('recommended', `${s.columnCount} columns — a table shows them all without crowding a chart.`);
            }
            if (s.maxCardinality > 25) {
                return verdict('recommended', `${s.maxCardinality} distinct values — a table scans better than a chart at this detail.`);
            }
            return verdict('available', 'Always works — shows the raw rows and columns.');
        }
    }
];

function verdict(fit, caption) {
    return { fit, caption };
}

export function scoreChartTypes(columns, rows) {
    const sig = computeDataSignature(columns, rows);
    return RULES.map((rule) => {
        const v = rule.evaluate(sig);
        return {
            type: rule.type,
            label: rule.label,
            fit: v.fit,
            caption: v.caption
        };
    });
}

// Maps a fit verdict to a SLDS icon name. Used by the picker to badge each
// option without needing a separate legend.
export function fitIcon(fit) {
    if (fit === 'recommended') return 'utility:success';
    if (fit === 'available') return 'utility:info_alt';
    return 'utility:warning';
}

// True for verdicts the user should be discouraged from picking. Useful for
// sorting the option list (recommended first, notFitting last).
export function fitRank(fit) {
    if (fit === 'recommended') return 0;
    if (fit === 'available') return 1;
    return 2;
}