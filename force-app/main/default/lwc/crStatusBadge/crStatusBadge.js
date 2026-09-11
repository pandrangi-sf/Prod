import { LightningElement, api } from 'lwc';

// Shared status pill used across the admin tabs (subscriptions, home tiles,
// AI providers, allowlist, health) so status looks consistent everywhere.
// tone drives the color: success | error | warning | info | neutral.
const TONES = new Set(['success', 'error', 'warning', 'info', 'neutral']);

export default class CrStatusBadge extends LightningElement {
    @api label;
    @api tone = 'neutral';
    // When true, render a small leading status dot.
    @api dot = false;

    get computedClass() {
        const t = TONES.has((this.tone || '').toLowerCase()) ? this.tone.toLowerCase() : 'neutral';
        return `cr-badge cr-badge_${t}`;
    }
    get showDot() {
        return this.dot === true || this.dot === 'true';
    }
}