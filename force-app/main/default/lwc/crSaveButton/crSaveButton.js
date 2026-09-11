import { LightningElement, api, track } from 'lwc';

const SUCCESS_HOLD_MS = 1400;

/**
 * Save button that morphs into a green check + "Saved!" on success, then
 * settles back to its default state. Wraps a plain SLDS-styled button (not
 * lightning-button) so the morph can target the inner content layers
 * directly — lightning-button keeps its internals in shadow DOM and would
 * fight the animation.
 *
 * Usage:
 *   <c-cr-save-button label="Save Report" disabled={saveDisabled}
 *                     onclick={save}></c-cr-save-button>
 *   // ...after the save promise resolves:
 *   this.template.querySelector('c-cr-save-button').triggerSuccess();
 */
export default class CrSaveButton extends LightningElement {
    @api label = 'Save';
    @api successLabel = 'Saved!';
    @api iconName = 'utility:save';
    @api variant = 'brand'; // 'brand' | 'neutral'
    @api disabled = false;
    @api tooltip = '';

    @track _showSuccess = false;
    _resetTimer = null;

    get buttonClass() {
        const base = ['cr-save-btn'];
        if (this.variant === 'neutral') base.push('cr-save-btn--neutral');
        if (this._showSuccess) base.push('cr-save-btn--success');
        return base.join(' ');
    }

    handleClick() {
        // Re-emit as a click event so the parent can keep its `onclick={save}`
        // binding without touching event detail.
        this.dispatchEvent(new CustomEvent('click', { bubbles: true, composed: true }));
    }

    @api
    triggerSuccess() {
        this._showSuccess = true;
        if (this._resetTimer) clearTimeout(this._resetTimer);
        this._resetTimer = setTimeout(() => {
            this._showSuccess = false;
            this._resetTimer = null;
        }, SUCCESS_HOLD_MS);
    }

    disconnectedCallback() {
        if (this._resetTimer) clearTimeout(this._resetTimer);
    }
}