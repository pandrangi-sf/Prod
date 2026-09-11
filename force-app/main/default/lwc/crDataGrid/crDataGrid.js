import { LightningElement, api, track } from 'lwc';

// Virtualized results grid built on the native lightning-datatable. We tried
// AG Grid Community first, but it does direct DOM manipulation (focus
// tab-guards via insertAdjacentElement) that LWC's synthetic Shadow DOM does
// not support — it throws during grid bean init regardless of report. The
// native datatable is synthetic-shadow-safe, adds zero bytes, and gives us
// sort + column resize + sticky header + scroll. Consumers pass the same
// {columns, rows} payload the query engine / charts use.
//
// Field-name remap: lightning-datatable resolves columns by `fieldName` keys
// on each row. Report column keys can contain dots (relationship fields like
// Account.Name) or other characters the datatable mishandles, so we remap to
// safe synthetic field names (c0, c1, …) and key the row objects by those.
export default class CrDataGrid extends LightningElement {
    @api height = 420;

    @track columns = [];
    @track data = [];
    @track sortedBy;
    @track sortedDirection = 'asc';

    @track _result = null;
    @api
    get result() { return this._result; }
    set result(value) {
        this._result = value;
        this.buildModel();
    }

    buildModel() {
        const cols = (this._result && this._result.columns) || [];
        const rows = (this._result && this._result.rows) || [];
        this.columns = cols.map((c, i) => ({
            label: c.label || c.key,
            fieldName: `c${i}`,
            type: c.numeric ? 'number' : 'text',
            sortable: true,
            // Right-align measures, like the chart axis formatting convention.
            cellAttributes: c.numeric ? { alignment: 'right' } : {}
        }));
        this.data = rows.map((r, idx) => {
            const o = { __id: String(idx) };
            cols.forEach((c, i) => { o[`c${i}`] = r[c.key]; });
            return o;
        });
        // A new dataset invalidates any prior sort.
        this.sortedBy = undefined;
        this.sortedDirection = 'asc';
    }

    handleSort(event) {
        const { fieldName, sortDirection } = event.detail;
        const dir = sortDirection === 'asc' ? 1 : -1;
        const sorted = [...this.data].sort((a, b) => {
            const x = a[fieldName];
            const y = b[fieldName];
            // Blanks sort last regardless of direction.
            const xb = x === null || x === undefined || x === '';
            const yb = y === null || y === undefined || y === '';
            if (xb && yb) return 0;
            if (xb) return 1;
            if (yb) return -1;
            const nx = Number(x);
            const ny = Number(y);
            if (Number.isFinite(nx) && Number.isFinite(ny)) return (nx - ny) * dir;
            return String(x).localeCompare(String(y)) * dir;
        });
        this.data = sorted;
        this.sortedBy = fieldName;
        this.sortedDirection = sortDirection;
    }

    get hasData() {
        return this.data.length > 0;
    }

    get wrapperStyle() {
        const h = Number.parseInt(this.height, 10);
        const px = Number.isFinite(h) && h > 0 ? h : 420;
        return `height:${px}px;`;
    }
}