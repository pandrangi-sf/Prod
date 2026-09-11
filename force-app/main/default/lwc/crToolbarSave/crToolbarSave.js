import { LightningElement, api } from 'lwc';

// Toolbar split-save: wraps crSaveButton (untouched) and adds a kebab menu
// with Save As / Delete to match the native Lightning Dashboard Save split.
// Emits three events: save, saveas, delete. Parent owns all logic.
export default class CrToolbarSave extends LightningElement {
    @api label = 'Save';
    @api variant = 'brand';
    @api disabled = false;
    @api canSaveAs = false;
    @api canDelete = false;

    get disabledSaveAs() {
        return !this.canSaveAs;
    }

    get disabledDelete() {
        return !this.canDelete;
    }

    handleSave() {
        this.dispatchEvent(new CustomEvent('save'));
    }

    handleMenuSelect(event) {
        const value = event.detail?.value;
        if (value === 'saveas') {
            this.dispatchEvent(new CustomEvent('saveas'));
        } else if (value === 'delete') {
            this.dispatchEvent(new CustomEvent('delete'));
        }
    }

    @api
    triggerSuccess() {
        const inner = this.template.querySelector('c-cr-save-button');
        if (inner && typeof inner.triggerSuccess === 'function') {
            inner.triggerSuccess();
        }
    }
}