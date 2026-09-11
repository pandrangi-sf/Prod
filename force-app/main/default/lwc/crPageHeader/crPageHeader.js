import { LightningElement, api } from 'lwc';

// Shared page header for the reporting tabs so every tab opens with the same
// colored icon chip + title + subtitle + right-aligned action slot. Replaces
// the per-tab mix of custom headers and lightning-card title slots.
//
// Usage:
//   <c-cr-page-header icon-name="standard:report" tone="blue"
//       eyebrow="Vital Reports" title="Report Migration"
//       subtitle="Import a standard report definition.">
//       <lightning-button slot="actions" label="Help"></lightning-button>
//   </c-cr-page-header>
const TONES = new Set(['blue', 'green', 'slate', 'red', 'amber', 'teal', 'purple']);

export default class CrPageHeader extends LightningElement {
    @api eyebrow = '';
    @api title = '';
    @api subtitle = '';
    @api iconName = 'standard:report';
    @api tone = 'blue';

    get iconWrapClass() {
        const t = TONES.has((this.tone || '').toLowerCase()) ? this.tone.toLowerCase() : 'blue';
        return `cr-page-header__icon cr-page-header__icon_${t}`;
    }
}