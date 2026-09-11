import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import runReport from '@salesforce/apex/CR_QueryEngine.runReport';
import ALASQL_LIB from '@salesforce/resourceUrl/AlaSQL';

// Server-formula path keeps the old 25-row sample. The cached-reshape path widens
// the fetch because grouping/aggregation now happens locally — too narrow a sample
// would make aggregate previews unrepresentative.
const PREVIEW_PAGE_SIZE = 25;
const RAW_FETCH_PAGE_SIZE = 1000;
const TRANSIENT_PATTERN = /TIMEOUT|UNABLE_TO_LOCK_ROW|503|504|UNAVAILABLE/i;
const RETRY_DELAY_MS = 1000;

let _alasqlLoadPromise = null;
function ensureAlasql(cmp) {
    if (!_alasqlLoadPromise) {
        _alasqlLoadPromise = loadScript(cmp, ALASQL_LIB)
            .then(() => window.alasql)
            .catch((err) => {
                // Clear so the next preview retries; otherwise a transient load
                // failure poisons every subsequent reshape attempt.
                _alasqlLoadPromise = null;
                throw err;
            });
    }
    return _alasqlLoadPromise;
}

export default class CrReportLivePreview extends LightningElement {
    @track loading = false;
    @track errorMessage;
    @track tableColumns = [];
    @track tableRows = [];
    @track displayRows = [];
    @track executedSoql = '';
    @track previewRunnable = false;
    @track viewMode = 'chart'; // 'chart' | 'table' — pill toggle above the result.
    @track chartType = 'bar';
    @track chartResult = null;

    viewModeOptions = [
        { label: 'Chart', value: 'chart' },
        { label: 'Table', value: 'table' }
    ];

    chartTypeOptions = [
        { label: 'Bar', value: 'bar' },
        { label: 'Horizontal Bar', value: 'horizontal' },
        { label: 'Line', value: 'line' },
        { label: 'Area', value: 'area' },
        { label: 'Donut', value: 'donut' },
        { label: 'Pie', value: 'pie' },
        // Phase 3 v7: BI-style chart types backed by Apache ECharts. crChart's
        // engine prop auto-routes these to c-cr-e-chart so the picker stays
        // a single dropdown from the user's POV.
        { label: 'Heatmap', value: 'heatmap' },
        { label: 'Treemap', value: 'treemap' },
        { label: 'Gauge', value: 'gauge' }
    ];

    // ECharts-only chart types — when picked, crChart routes through c-cr-e-chart
    // instead of the Chart.js canvas path.
    _ECHARTS_TYPES = new Set(['heatmap', 'treemap', 'gauge']);

    get chartEngine() {
        return this._ECHARTS_TYPES.has(this.chartType) ? 'echarts' : 'chartjs';
    }

    handleChartTypePick(event) {
        this.chartType = event.detail.value;
    }

    // Raw-row cache for the client reshape path. Keyed by JSON.stringify({dataset, filters}).
    // Anything that changes those forces a server round-trip; everything else
    // (groupings, aggregations, sort, column reorder) re-shapes from cache.
    _rawCacheKey = null;
    _rawRows = null;
    _rawColumns = null;
    _rawExecutedSoql = '';
    _alasqlPrewarmed = false;

    _definitionJson;

    connectedCallback() {
        // Pre-warm the AlaSQL bundle (~460KB UMD) during browser idle time so
        // the first aggregate-reshape doesn't pay the cold parse cost. By the
        // time the user clicks Refresh on a grouped report, the script is
        // already loaded. Falls back to a 0ms setTimeout on runtimes without
        // requestIdleCallback (Lightning Locker Service, older Safari).
        if (this._alasqlPrewarmed) return;
        this._alasqlPrewarmed = true;
        const prewarm = () => { ensureAlasql(this).catch(() => { /* surface on first real use */ }); };
        if (typeof window !== 'undefined' && typeof window.requestIdleCallback === 'function') {
            window.requestIdleCallback(prewarm, { timeout: 3000 });
        } else {
            setTimeout(prewarm, 0);
        }
    }

    @api
    get definitionJson() {
        return this._definitionJson;
    }

    set definitionJson(value) {
        if (this._definitionJson === value) {
            return;
        }
        this._definitionJson = value;
        this.previewRunnable = this.canRunPreview(value);
        this.chartType = this.extractChartType(value);
    }

    get hasRows() {
        return this.tableRows.length > 0;
    }

    get isChartView() { return this.viewMode === 'chart'; }
    get isTableView() { return this.viewMode === 'table'; }

    handleViewModeChange(event) {
        this.viewMode = event.detail.value;
    }

    extractChartType(json) {
        if (!json) return 'bar';
        try {
            const def = JSON.parse(json);
            return def?.chart?.type || 'bar';
        } catch {
            return 'bar';
        }
    }

    get rowCount() {
        return this.tableRows.length;
    }

    get runDisabled() {
        return this.loading || !this.previewRunnable;
    }

    // Force-refresh: invalidate the raw-row cache so the next runPreview hits
    // Apex regardless of whether {dataset, filters} changed. Useful when the
    // user knows SF data has changed since their last fetch — without this,
    // the Refresh button just re-shapes cached rows (the Phase 1 v3 behavior).
    async forceRefresh() {
        this._rawCacheKey = null;
        this._rawRows = null;
        this._rawColumns = null;
        this._rawExecutedSoql = '';
        await this.runPreview();
    }

    async runPreview() {
        this.loading = true;
        this.errorMessage = null;
        let succeeded = false;
        try {
            const def = JSON.parse(this._definitionJson);
            // Formulas/buckets still need server-side evaluation (CR_FormulaEngine
            // runs in Apex). Until a JS port ships, round-trip whenever they're
            // present so the preview matches what the saved report will produce.
            const hasFormulas = Array.isArray(def.formulas) && def.formulas.length > 0;
            const hasBuckets  = Array.isArray(def.buckets)  && def.buckets.length  > 0;
            const result = (hasFormulas || hasBuckets)
                ? await this.runServerPath(this._definitionJson, PREVIEW_PAGE_SIZE)
                : await this.runCachedPath(def);
            this.renderResult(result);
            succeeded = true;
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Preview failed.';
            this.tableRows = [];
            this.tableColumns = [];
            this.displayRows = [];
            this.executedSoql = '';
            this.chartResult = null;
        } finally {
            this.loading = false;
            if (succeeded) {
                // Defer until after the DOM has reacted to the new tableRows/chartResult
                // so the pulse rings the up-to-date shell, not the empty pre-render one.
                Promise.resolve().then(() => this.pulsePreviewShell());
            }
        }
    }

    async runServerPath(definitionJson, pageSize) {
        return this.runWithRetry(definitionJson, pageSize);
    }

    // Fetch raw tabular rows once per {dataset, filters}; do groupings, aggregations,
    // sort, and column projection in the browser. Cuts the Apex round-trip out of
    // every non-structural definition change.
    async runCachedPath(def) {
        const cacheKey = JSON.stringify({ dataset: def.dataset, filters: def.filters });
        if (cacheKey !== this._rawCacheKey || !this._rawRows) {
            const fetchDef = {
                ...def,
                groupings: [],
                aggregations: [],
                sort: [],
                formulas: [],
                buckets: [],
                fields: this.expandFieldsForFetch(def)
            };
            const fetched = await this.runWithRetry(JSON.stringify(fetchDef), RAW_FETCH_PAGE_SIZE);
            this._rawRows = fetched.rows || [];
            this._rawColumns = fetched.columns || [];
            this._rawExecutedSoql = fetched.executedSoql || '';
            this._rawCacheKey = cacheKey;
        }
        return this.applyClientReshape(def);
    }

    renderResult(result) {
        const columns = (result.columns || []).map((col) => ({
            label: col.label || col.key,
            fieldName: col.key,
            type: this.dataTypeToColumnType(col.dataType, col.numeric),
            // Phase 3 v8: keep the raw dataType so detectRecordLink can flag
            // ID / REFERENCE columns as record-page links.
            dataType: col.dataType
        }));
        const rows = (result.rows || []).map((row, i) => ({ ...row, _rowId: `r_${i}` }));
        this.tableColumns = columns;
        this.tableRows = rows;
        this.displayRows = this.buildDisplayRows(rows, columns);
        this.executedSoql = result.executedSoql || '';
        // Pass the raw engine columns/rows to the chart wrapper. Cloning here so
        // Chart.js can mutate without tripping LWC's reactive proxy.
        this.chartResult = JSON.parse(JSON.stringify({
            columns: result.columns || [],
            rows: result.rows || []
        }));
    }

    /**
     * Brief blue ring + tint flash on the preview body to confirm "I refreshed."
     * Uses the Web Animations API so each call cleanly retriggers the animation
     * (CSS class toggling has reflow gymnastics; .animate() doesn't).
     */
    pulsePreviewShell() {
        const shell = this.template.querySelector('.preview-shell');
        if (!shell || typeof shell.animate !== 'function') return;
        const reducedMotion = typeof window !== 'undefined'
            && typeof window.matchMedia === 'function'
            && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        if (reducedMotion) return;
        try {
            shell.animate([
                {
                    boxShadow: '0 0 0 0 rgba(21, 137, 238, 0)',
                    backgroundColor: 'rgba(232, 245, 255, 0)'
                },
                {
                    boxShadow: '0 0 0 6px rgba(21, 137, 238, 0.22)',
                    backgroundColor: 'rgba(232, 245, 255, 0.55)',
                    offset: 0.25
                },
                {
                    boxShadow: '0 0 0 0 rgba(21, 137, 238, 0)',
                    backgroundColor: 'rgba(232, 245, 255, 0)'
                }
            ], { duration: 850, easing: 'cubic-bezier(0.16, 1, 0.3, 1)' });
        } catch (e) {
            // Web Animations API absent in some old runtimes — silent no-op.
        }
    }

    async runWithRetry(definitionJson, pageSize) {
        const args = {
            definitionJson,
            pageToken: null,
            pageSize,
            dashboardFiltersJson: null
        };
        try {
            return await runReport(args);
        } catch (error) {
            const message = error?.body?.message || error?.message || '';
            if (!TRANSIENT_PATTERN.test(message)) throw error;
            await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
            return await runReport(args);
        }
    }

    dataTypeToColumnType(dataType, numeric) {
        if (numeric) return 'number';
        const t = (dataType || '').toUpperCase();
        if (t === 'DATE') return 'date-local';
        if (t === 'DATETIME') return 'date';
        if (t === 'BOOLEAN') return 'boolean';
        if (t === 'EMAIL') return 'email';
        if (t === 'PHONE') return 'phone';
        if (t === 'URL') return 'url';
        if (t === 'CURRENCY') return 'currency';
        if (t === 'PERCENT') return 'percent';
        return 'text';
    }

    buildDisplayRows(rows, columns) {
        // Phase 3 v9: compute pairing once, resolve per-row at cell time.
        const linkedColumnMap = this.buildLinkedColumnMap(columns);
        return (rows || []).map((row, rowIndex) => ({
            key: row._rowId || `row_${rowIndex}`,
            cells: (columns || []).map((column) => {
                const rawValue = this.formatCellValue(row[column.fieldName]);
                let linkUrl = this.detectRecordLink(rawValue, column);
                if (!linkUrl && linkedColumnMap.has(column.fieldName)) {
                    const idColumnKey = linkedColumnMap.get(column.fieldName);
                    const idValue = row[idColumnKey];
                    if (typeof idValue === 'string' && this.looksLikeSfId(idValue)) {
                        linkUrl = `/lightning/r/${encodeURIComponent(idValue)}/view`;
                    }
                }
                return {
                    key: `${rowIndex}_${column.fieldName}`,
                    value: rawValue,
                    linkUrl,
                    isLink: !!linkUrl
                };
            })
        }));
    }

    looksLikeSfId(s) {
        return /^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(s);
    }

    // Mirror of crReportViewer.buildLinkedColumnMap — note this LWC's columns
    // use `fieldName` (transformed for lightning-datatable) instead of `key`.
    buildLinkedColumnMap(columns) {
        const keys = new Set((columns || []).map((c) => c.fieldName).filter(Boolean));
        const map = new Map();
        for (const col of (columns || [])) {
            const key = col.fieldName;
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

    // Mirror of crReportViewer.detectRecordLink — kept in sync. Renders any
    // Salesforce 15/18-char ID-shaped cell as a /lightning/r/<id>/view link
    // opened in a new tab.
    detectRecordLink(value, column) {
        if (typeof value !== 'string' || !value) return null;
        const strongType = column && column.dataType
            ? String(column.dataType).toUpperCase()
            : '';
        if (strongType === 'ID' || strongType === 'REFERENCE') {
            return `/lightning/r/${encodeURIComponent(value)}/view`;
        }
        if (/^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(value)) {
            return `/lightning/r/${encodeURIComponent(value)}/view`;
        }
        return null;
    }

    // Mirror of crReportViewer.formatCellValue — collapses Salesforce compound
    // fields (Address, Location, Name) into a single string so the template
    // doesn't render "[object Object]". Kept in sync with the viewer's copy.
    formatCellValue(value) {
        if (value === null || value === undefined) return '';
        if (typeof value !== 'object') return value;
        if ('street' in value || 'postalCode' in value || 'city' in value) {
            const parts = [];
            if (value.street) parts.push(value.street);
            const cityStateZip = [value.city, value.state, value.postalCode].filter(Boolean).join(' ').trim();
            if (cityStateZip) parts.push(cityStateZip);
            if (value.country) parts.push(value.country);
            return parts.join(', ');
        }
        if ('latitude' in value && 'longitude' in value && Object.keys(value).length <= 3) {
            const lat = value.latitude;
            const lng = value.longitude;
            return lat != null && lng != null ? `${lat}, ${lng}` : '';
        }
        if ('firstName' in value || 'lastName' in value) {
            return [value.salutation, value.firstName, value.middleName, value.lastName, value.suffix]
                .filter(Boolean).join(' ').trim();
        }
        try { return JSON.stringify(value); } catch (e) { return ''; }
    }

    // Union of every field path the reshape will read off a row: declared fields,
    // grouping fields, aggregation source fields, and sort fields. Anything missing
    // here will be `undefined` after the reshape (the raw fetch wouldn't have included it).
    // Aggregate sort keys like "a0"/"g1" are skipped — they're computed during reshape.
    expandFieldsForFetch(def) {
        const paths = new Set();
        const addPath = (p) => { if (p && !/^[ga]\d+$/.test(p)) paths.add(p); };
        for (const f of def.fields || []) {
            addPath(typeof f === 'string' ? f : (f && (f.path || f.field)));
        }
        for (const g of def.groupings || []) {
            addPath(typeof g === 'string' ? g : (g && (g.field || g.path)));
        }
        for (const a of def.aggregations || []) {
            if (a && a.field) addPath(a.field);
        }
        for (const s of def.sort || []) {
            if (s && s.field) addPath(s.field);
        }
        return [...paths].map((path) => ({ path }));
    }

    async applyClientReshape(def) {
        const groupings = def.groupings || [];
        const aggregations = def.aggregations || [];
        if (groupings.length === 0 && aggregations.length === 0) {
            return this.reshapeTabular(def);
        }
        return this.reshapeAggregate(def);
    }

    reshapeTabular(def) {
        const fieldDefs = (def.fields || [])
            .map((f) => ({
                path: typeof f === 'string' ? f : (f && (f.path || f.field)),
                label: typeof f === 'string' ? null : (f && f.label)
            }))
            .filter((f) => !!f.path);

        let rows = this._rawRows.map((row) => {
            const out = {};
            for (const f of fieldDefs) out[f.path] = row[f.path];
            return out;
        });

        const sort = (def.sort || []).filter((s) => s && s.field);
        if (sort.length) {
            rows = [...rows].sort((a, b) => {
                for (const s of sort) {
                    const dir = (s.direction || 'ASC').toUpperCase() === 'DESC' ? -1 : 1;
                    const av = a[s.field];
                    const bv = b[s.field];
                    if (av == null && bv == null) continue;
                    if (av == null) return 1 * dir;
                    if (bv == null) return -1 * dir;
                    if (av < bv) return -1 * dir;
                    if (av > bv) return 1 * dir;
                }
                return 0;
            });
        }

        // Hydrate column metadata from the cached raw columns by key match so the
        // chart/table renderers get the same dataType + numeric hints they got from Apex.
        const rawByKey = new Map((this._rawColumns || []).map((c) => [c.key, c]));
        const columns = fieldDefs.map((f) => {
            const raw = rawByKey.get(f.path);
            return {
                key: f.path,
                label: f.label || (raw && raw.label) || f.path,
                dataType: raw && raw.dataType,
                numeric: !!(raw && raw.numeric)
            };
        });

        return {
            columns,
            rows,
            executedSoql: (this._rawExecutedSoql || '') + '\n-- reshape: tabular (client)'
        };
    }

    async reshapeAggregate(def) {
        const alasql = await ensureAlasql(this);

        // Normalize to objects: groupings can be ["Account.Name"] or [{field:"...", label:"..."}].
        const groupings = (def.groupings || []).map((g) =>
            typeof g === 'string' ? { field: g } : (g || {})
        ).filter((g) => g.field);
        const aggregations = (def.aggregations || []).map((a) => ({ ...a }));

        // Sanitized alias map so AlaSQL doesn't have to parse dotted relationship paths
        // like Opportunity.Account.Name or Dim_Account__r.Account_Name__c. Every distinct
        // source path gets a flat alias (f0, f1, ...). Cleaner than fighting backtick quoting.
        const aliasByPath = new Map();
        const aliasFor = (path) => {
            if (!aliasByPath.has(path)) aliasByPath.set(path, `f${aliasByPath.size}`);
            return aliasByPath.get(path);
        };
        for (const g of groupings) aliasFor(g.field);
        for (const a of aggregations) if (a.field) aliasFor(a.field);

        const aliasedRows = this._rawRows.map((row) => {
            const out = {};
            for (const [path, alias] of aliasByPath) out[alias] = row[path];
            return out;
        });

        const selectParts = [];
        groupings.forEach((g, i) => selectParts.push(`${aliasFor(g.field)} AS g${i}`));
        if (aggregations.length === 0) {
            selectParts.push('COUNT(*) AS a0');
        } else {
            aggregations.forEach((a, i) => {
                const fn = (a.function || 'COUNT').toUpperCase();
                const operand = a.field ? aliasFor(a.field) : '*';
                selectParts.push(`${fn}(${operand}) AS a${i}`);
            });
        }
        const groupBy = groupings.map((g) => aliasFor(g.field)).join(', ');
        const sql = `SELECT ${selectParts.join(', ')} FROM ?` +
            (groupings.length ? ` GROUP BY ${groupBy}` : '');
        const rows = alasql(sql, [aliasedRows]);

        // Mirror CR_QueryEngine.executeAggregate's output shape exactly: g0..gN are
        // GROUP keys, a0..aM are AGGREGATE keys. Downstream consumers (crChart, the
        // table renderer) don't know the reshape moved off the server.
        const columns = [];
        groupings.forEach((g, i) => columns.push({
            key: `g${i}`,
            label: g.label || g.field,
            dataType: 'GROUP',
            numeric: false
        }));
        if (aggregations.length === 0) {
            columns.push({ key: 'a0', label: 'COUNT(Id)', dataType: 'AGGREGATE', numeric: true });
        } else {
            aggregations.forEach((a, i) => columns.push({
                key: `a${i}`,
                label: `${a.function}(${a.field || ''})`,
                dataType: 'AGGREGATE',
                numeric: true
            }));
        }

        return {
            columns,
            rows,
            executedSoql: (this._rawExecutedSoql || '') + '\n-- reshape: ' + sql + ' (client, AlaSQL)'
        };
    }

    canRunPreview(definitionJson) {
        if (!definitionJson) {
            return false;
        }
        try {
            const def = JSON.parse(definitionJson);
            return !!def?.dataset && !!(def.fields && def.fields.length);
        } catch {
            return false;
        }
    }
}