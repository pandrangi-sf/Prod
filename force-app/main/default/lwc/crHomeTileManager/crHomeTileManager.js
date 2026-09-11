import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import canManageTiles from '@salesforce/apex/CR_HomeTileService.canManageTiles';
import listAllTiles from '@salesforce/apex/CR_HomeTileService.listAllTiles';
import listAvailableTabs from '@salesforce/apex/CR_HomeTileService.listAvailableTabs';
import saveTile from '@salesforce/apex/CR_HomeTileService.saveTile';
import deleteTile from '@salesforce/apex/CR_HomeTileService.deleteTile';

const AUDIENCE_OPTIONS = [
    { label: 'Both (everyone)', value: 'Both' },
    { label: 'User (non-admins)', value: 'User' },
    { label: 'Admin only', value: 'Admin' }
];
const COLOR_OPTIONS = ['blue', 'green', 'purple', 'teal', 'amber', 'red', 'slate'].map((c) => ({
    label: c,
    value: c
}));

// Swatch palette mirrors the live launchpad tiles: soft background ring + a
// stronger accent dot so the colors are distinguishable at swatch size.
const COLOR_PALETTE = [
    { value: 'blue', soft: '#e8f0fc', strong: '#1b5cab' },
    { value: 'green', soft: '#eaf6ee', strong: '#2e844a' },
    { value: 'purple', soft: '#efe9fb', strong: '#7a5fc9' },
    { value: 'teal', soft: '#def4f3', strong: '#0b827c' },
    { value: 'amber', soft: '#fdf1d8', strong: '#cb8b00' },
    { value: 'red', soft: '#fde4e2', strong: '#ba2f2f' },
    { value: 'slate', soft: '#e8ecf1', strong: '#5c7591' }
];

// Curated icon grid for the common launchpad cases. The free-text field below
// still accepts any valid SLDS icon name for advanced use.
const ICON_CHOICES = [
    'standard:report', 'standard:dashboard', 'standard:metrics', 'standard:folder',
    'standard:custom', 'standard:account', 'standard:contact', 'standard:task',
    'standard:announcement', 'standard:calibration', 'standard:einstein_analytics',
    'standard:flow', 'standard:layout', 'standard:settings', 'standard:people',
    'utility:chart', 'utility:graph', 'utility:filterList', 'utility:reminder',
    'utility:setup', 'utility:knowledge_base', 'utility:date_input'
];

const EMPTY_FORM = {
    id: null,
    label: '',
    description: '',
    iconName: 'standard:custom',
    target: '',
    audience: 'Both',
    colorScheme: 'slate',
    displayOrder: null,
    isActive: true
};

export default class CrHomeTileManager extends LightningElement {
    @track tiles = [];
    @track tabOptions = [];
    @track form = { ...EMPTY_FORM };
    @track showForm = false;
    @track busy = false;
    canManage = false;
    loadError = null;

    audienceOptions = AUDIENCE_OPTIONS;
    colorOptions = COLOR_OPTIONS;

    connectedCallback() {
        this.init();
    }

    async init() {
        this.busy = true;
        try {
            this.canManage = await canManageTiles();
            if (!this.canManage) {
                this.busy = false;
                return;
            }
            const [tiles, tabs] = await Promise.all([listAllTiles(), listAvailableTabs()]);
            this.tiles = tiles.map((t) => ({
                ...t,
                activeLabel: t.isActive ? 'Active' : 'Hidden',
                activeTone: t.isActive ? 'success' : 'neutral'
            }));
            this.tabOptions = tabs;
            this.loadError = null;
        } catch (e) {
            this.loadError = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    get hasTiles() {
        return this.tiles.length > 0;
    }
    get formTitle() {
        return this.form.id ? 'Edit Tile' : 'New Tile';
    }

    get colorSwatches() {
        return COLOR_PALETTE.map((c) => ({
            value: c.value,
            ringStyle: `background:${c.soft};`,
            dotStyle: `background:${c.strong};`,
            cssClass: this.form.colorScheme === c.value ? 'htm-swatch htm-swatch_on' : 'htm-swatch',
            title: c.value
        }));
    }

    get iconChoices() {
        return ICON_CHOICES.map((name) => ({
            name,
            cssClass: this.form.iconName === name ? 'htm-icon-choice htm-icon-choice_on' : 'htm-icon-choice'
        }));
    }

    handleColorPick(event) {
        const value = event.currentTarget.dataset.value;
        this.form = { ...this.form, colorScheme: value };
    }

    handleIconPick(event) {
        const name = event.currentTarget.dataset.value;
        this.form = { ...this.form, iconName: name };
    }

    handleNew() {
        this.form = { ...EMPTY_FORM };
        this.showForm = true;
    }

    handleEdit(event) {
        const id = event.currentTarget.dataset.id;
        const found = this.tiles.find((t) => t.id === id);
        if (found) {
            this.form = {
                id: found.id,
                label: found.label,
                description: found.description,
                iconName: found.iconName,
                target: found.target,
                audience: found.audience || 'Both',
                colorScheme: found.colorScheme || 'slate',
                displayOrder: found.displayOrder,
                isActive: found.isActive
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
            this.toast('Validation', 'Tile label is required.', 'warning');
            return;
        }
        this.busy = true;
        try {
            await saveTile({ payloadJson: JSON.stringify(this.form) });
            this.toast('Saved', 'Tile saved. The Home page reflects it after a refresh.', 'success');
            this.showForm = false;
            this.form = { ...EMPTY_FORM };
            await this.init();
        } catch (e) {
            this.toast('Error', this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleToggleActive(event) {
        const id = event.currentTarget.dataset.id;
        const found = this.tiles.find((t) => t.id === id);
        if (!found) return;
        this.busy = true;
        try {
            await saveTile({
                payloadJson: JSON.stringify({
                    id: found.id,
                    label: found.label,
                    description: found.description,
                    iconName: found.iconName,
                    target: found.target,
                    audience: found.audience,
                    colorScheme: found.colorScheme,
                    displayOrder: found.displayOrder,
                    isActive: !found.isActive
                })
            });
            await this.init();
        } catch (e) {
            this.toast('Error', this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        const confirmed = await LightningConfirm.open({
            message: 'Delete this tile? This cannot be undone.',
            label: 'Delete home tile',
            theme: 'warning',
            variant: 'header'
        });
        if (!confirmed) {
            return;
        }
        this.busy = true;
        try {
            await deleteTile({ tileId: id });
            this.toast('Deleted', 'Tile removed.', 'success');
            await this.init();
        } catch (e) {
            this.toast('Error', this.msg(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}