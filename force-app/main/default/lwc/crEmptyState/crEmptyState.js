import { LightningElement, api } from 'lwc';

/**
 * Friendly empty-state panel — small sleepy-cloud mascot, headline, body copy,
 * and an optional slot for action buttons. Visually rhymes with crWelcomeBanner
 * so the framework feels coherent rather than mascot-on-some-pages-only.
 *
 * Usage:
 *   <c-cr-empty-state
 *       headline="No data yet"
 *       body="Click Refresh at the top to load this component's data.">
 *       <lightning-button slot="actions" label="Refresh"></lightning-button>
 *   </c-cr-empty-state>
 */
export default class CrEmptyState extends LightningElement {
    @api headline = '';
    @api body = '';
}