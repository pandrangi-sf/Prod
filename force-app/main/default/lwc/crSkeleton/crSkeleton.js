import { LightningElement, api } from 'lwc';

// Reusable shimmer placeholder for loading states. Replaces bare spinners /
// "Loading…" text so the layout doesn't jump and load feels faster.
//   rows  : how many placeholder lines/rows to render (default 3)
//   variant: 'row' (full-width bars, e.g. table rows) | 'line' (text lines)
export default class CrSkeleton extends LightningElement {
    @api rows = 3;
    @api variant = 'row';

    get items() {
        const n = Math.max(1, Math.min(Number(this.rows) || 3, 20));
        return Array.from({ length: n }, (_, i) => ({ key: i }));
    }
    get barClass() {
        return this.variant === 'line' ? 'cr-skel__bar cr-skel__bar_line' : 'cr-skel__bar';
    }
}