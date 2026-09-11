// Client-side export helpers. Operate purely on the {columns, rows} payload
// (no DOM capture), so they're free of the synthetic-Shadow-DOM hazards that
// sank AG Grid. Libraries are lazy-loaded ON CALL (first export click), never
// at page load — so the ~0.9MB SheetJS / ~0.4MB jsPDF bundles don't touch
// initial render.
//
// These are functions (not a component) so any consumer can call them; they
// take the calling component `cmp` because loadScript needs a component
// context. Load promises are cached at module scope (libs attach to window).
import { loadScript } from 'lightning/platformResourceLoader';
import SHEETJS from '@salesforce/resourceUrl/SheetJS';
import JSPDF from '@salesforce/resourceUrl/JsPdf';
import JSPDF_AUTOTABLE from '@salesforce/resourceUrl/JsPdfAutotable';

let _xlsxPromise = null;
let _pdfPromise = null;

function ensureXlsx(cmp) {
    if (!_xlsxPromise) {
        _xlsxPromise = loadScript(cmp, SHEETJS)
            .then(() => window.XLSX)
            .catch((e) => { _xlsxPromise = null; throw e; });
    }
    return _xlsxPromise;
}

function ensurePdf(cmp) {
    if (!_pdfPromise) {
        // autotable must load AFTER jsPDF (it augments the jsPDF prototype).
        _pdfPromise = loadScript(cmp, JSPDF)
            .then(() => loadScript(cmp, JSPDF_AUTOTABLE))
            .then(() => window.jspdf)
            .catch((e) => { _pdfPromise = null; throw e; });
    }
    return _pdfPromise;
}

// Build header labels + a body matrix from {columns, rows}. Raw values are
// preserved (numbers stay numeric for Excel); null/undefined become ''.
function headersAndBody(result) {
    const columns = (result && result.columns) || [];
    const rows = (result && result.rows) || [];
    const headers = columns.map((c) => c.label || c.key);
    const body = rows.map((r) => columns.map((c) => {
        const v = r[c.key];
        return v === null || v === undefined ? '' : v;
    }));
    return { headers, body };
}

export async function exportToExcel(cmp, result, filename) {
    const XLSX = await ensureXlsx(cmp);
    const { headers, body } = headersAndBody(result);
    const ws = XLSX.utils.aoa_to_sheet([headers, ...body]);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Report');
    // writeFile triggers the browser download.
    XLSX.writeFile(wb, filename || 'report.xlsx');
}

export async function exportToPdf(cmp, result, filename, title) {
    const jspdf = await ensurePdf(cmp);
    const { headers, body } = headersAndBody(result);
    const landscape = headers.length > 6;
    const doc = new jspdf.jsPDF({ orientation: landscape ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' });
    let startY = 40;
    if (title) {
        doc.setFontSize ? doc.setFontSize(13) : null;
        doc.text(String(title), 40, 30);
        startY = 48;
    }
    doc.autoTable({
        head: [headers],
        body,
        startY,
        styles: { fontSize: 8, cellPadding: 3, overflow: 'linebreak' },
        headStyles: { fillColor: [1, 118, 211] },
        margin: { top: 40, left: 40, right: 40, bottom: 40 }
    });
    doc.save(filename || 'report.pdf');
}