import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import canManageProviders from '@salesforce/apex/CR_AIProviderService.canManageProviders';
import listProviders from '@salesforce/apex/CR_AIProviderService.listProviders';
import saveProvider from '@salesforce/apex/CR_AIProviderService.saveProvider';
import deleteProvider from '@salesforce/apex/CR_AIProviderService.deleteProvider';
import testConnection from '@salesforce/apex/CR_AIProviderService.testConnection';

const PROVIDER_OPTIONS = [
    { label: 'Anthropic', value: 'Anthropic' },
    { label: 'Disabled', value: 'Disabled' }
];

const EMPTY_FORM = {
    id: null,
    label: '',
    provider: 'Anthropic',
    model: 'claude-sonnet-4-6',
    namedCredential: '',
    maxTokens: 1024,
    isActive: true,
    isDefault: false
};

export default class CrAiProviderManager extends LightningElement {
    @track providers = [];
    @track form = { ...EMPTY_FORM };
    @track showForm = false;
    @track busy = false;
    canManage = false;
    loadError = null;

    providerOptions = PROVIDER_OPTIONS;

    connectedCallback() {
        this.init();
    }

    async init() {
        this.busy = true;
        try {
            this.canManage = await canManageProviders();
            if (!this.canManage) {
                this.busy = false;
                return;
            }
            const rows = await listProviders();
            this.providers = rows.map((p) => ({
                ...p,
                statusLabel: p.isActive ? (p.isDefault ? 'Active · Default' : 'Active') : 'Inactive',
                statusTone: p.isActive ? 'success' : 'neutral',
                lastTestLabel: this._tests[p.id] ? this._tests[p.id].label : '—',
                lastTestClass: this._tests[p.id] ? this._tests[p.id].cls : 'slds-text-color_weak'
            }));
            this.loadError = null;
        } catch (e) {
            this.loadError = this._msg(e);
        } finally {
            this.busy = false;
        }
    }

    _tests = {};

    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') panel.toggle();
    }

    get hasProviders() {
        return this.providers.length > 0;
    }
    get formTitle() {
        return this.form.id ? 'Edit Provider' : 'New Provider';
    }

    handleNew() {
        this.form = { ...EMPTY_FORM };
        this.showForm = true;
    }

    handleEdit(event) {
        const id = event.currentTarget.dataset.id;
        const found = this.providers.find((p) => p.id === id);
        if (found) {
            this.form = {
                id: found.id,
                label: found.label,
                provider: found.provider || 'Anthropic',
                model: found.model || '',
                namedCredential: found.namedCredential || '',
                maxTokens: found.maxTokens,
                isActive: found.isActive,
                isDefault: found.isDefault
            };
            this.showForm = true;
        }
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.form = { ...this.form, [field]: value };
    }

    handleCancel() {
        this.showForm = false;
        this.form = { ...EMPTY_FORM };
    }

    async handleSave() {
        if (!this.form.label) {
            this._toast('Validation', 'Provider name is required.', 'warning');
            return;
        }
        this.busy = true;
        try {
            await saveProvider({ payloadJson: JSON.stringify(this.form) });
            this._toast('Saved', 'Provider saved.', 'success');
            this.showForm = false;
            this.form = { ...EMPTY_FORM };
            await this.init();
        } catch (e) {
            this._toast('Error', this._msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        const confirmed = await LightningConfirm.open({
            message: 'Delete this provider? AI features will fall back to other active providers (or stop working if this was the only one).',
            label: 'Delete AI provider',
            theme: 'warning',
            variant: 'header'
        });
        if (!confirmed) {
            return;
        }
        this.busy = true;
        try {
            await deleteProvider({ providerId: id });
            this._toast('Deleted', 'Provider removed.', 'success');
            await this.init();
        } catch (e) {
            this._toast('Error', this._msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleTest(event) {
        const id = event.currentTarget.dataset.id;
        this.busy = true;
        try {
            const r = await testConnection({ providerId: id });
            this._tests[id] = r.success
                ? { label: 'OK · ' + (r.message || ''), cls: 'slds-text-color_success' }
                : { label: 'Failed · ' + (r.message || ''), cls: 'slds-text-color_error' };
            this._toast(
                r.success ? 'Connected' : 'Connection failed',
                r.message || '',
                r.success ? 'success' : 'error'
            );
            await this.init();
        } catch (e) {
            this._toast('Error', this._msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}