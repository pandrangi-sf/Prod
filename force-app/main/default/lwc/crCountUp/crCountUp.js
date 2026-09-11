import { LightningElement, api, track } from 'lwc';

const DEFAULT_DURATION_MS = 700;

// easeOutQuart: fast start, gentle finish. Reads as "value rushes in then settles"
// on KPI tiles, which is the effect the dashboard wants for refresh moments.
function easeOutQuart(t) {
    const u = 1 - t;
    return 1 - u * u * u * u;
}

function prefersReducedMotion() {
    return typeof window !== 'undefined'
        && typeof window.matchMedia === 'function'
        && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/**
 * Tween a numeric value from 0 (or its previous value) up to `value`. Used by
 * crDashboardViewer for KPI metric tiles. Falls back to the formatted final
 * value (no animation) when:
 *   - prefers-reduced-motion is set,
 *   - value is non-numeric or null,
 *   - the runtime has no requestAnimationFrame.
 */
export default class CrCountUp extends LightningElement {
    @api format = 'number';   // 'number' | 'currency' | 'percent'
    @api currency = 'USD';
    @api locale;              // e.g., 'en-US' — falls back to platform default if omitted
    @api maximumFractionDigits = 2;
    @api prefix = '';
    @api suffix = '';
    @api duration = DEFAULT_DURATION_MS;

    @track displayValue = '';

    _targetValue = null;
    _animHandle = null;

    @api
    get value() {
        return this._targetValue;
    }
    set value(v) {
        const next = (v === null || v === undefined || v === '') ? null : Number(v);
        const numeric = Number.isFinite(next) ? next : null;
        if (numeric === this._targetValue) return;
        const previous = Number.isFinite(this._targetValue) ? this._targetValue : 0;
        this._targetValue = numeric;
        if (numeric === null) {
            this.cancelAnim();
            this.displayValue = '';
            return;
        }
        if (prefersReducedMotion() || typeof requestAnimationFrame !== 'function') {
            this.cancelAnim();
            this.displayValue = this.formatNumber(numeric);
            return;
        }
        this.startAnim(previous, numeric);
    }

    disconnectedCallback() {
        this.cancelAnim();
    }

    cancelAnim() {
        if (this._animHandle && typeof cancelAnimationFrame === 'function') {
            cancelAnimationFrame(this._animHandle);
        }
        this._animHandle = null;
    }

    startAnim(from, to) {
        this.cancelAnim();
        const start = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        const dur = Math.max(1, Number(this.duration) || DEFAULT_DURATION_MS);
        const tick = () => {
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            const t = Math.min(1, (now - start) / dur);
            const current = from + (to - from) * easeOutQuart(t);
            this.displayValue = this.formatNumber(current);
            if (t < 1) {
                this._animHandle = requestAnimationFrame(tick);
            } else {
                this._animHandle = null;
                // Settle on the exact target so eased rounding doesn't drift.
                this.displayValue = this.formatNumber(to);
            }
        };
        this._animHandle = requestAnimationFrame(tick);
    }

    formatNumber(n) {
        if (!Number.isFinite(n)) return '';
        const opts = { maximumFractionDigits: this.maximumFractionDigits };
        const fmt = String(this.format || 'number').toLowerCase();
        if (fmt === 'currency') {
            opts.style = 'currency';
            opts.currency = this.currency || 'USD';
        } else if (fmt === 'percent') {
            opts.style = 'percent';
        }
        try {
            const formatter = new Intl.NumberFormat(this.locale || 'en-US', opts);
            return `${this.prefix || ''}${formatter.format(n)}${this.suffix || ''}`;
        } catch (e) {
            return `${this.prefix || ''}${n}${this.suffix || ''}`;
        }
    }
}