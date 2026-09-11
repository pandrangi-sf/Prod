import { LightningElement } from 'lwc';

// Step 1 of the native-style Add Widget flow. Picks a widget category;
// "Chart or Table" advances to the report picker (Step 2), the other three
// types are reserved for Phase D.
const TYPES = [
    {
        value: 'chart',
        label: 'Chart or Table',
        description: 'Visualize a saved report as a chart, gauge, or table.',
        icon: 'utility:chart',
        enabled: true
    },
    {
        value: 'text',
        label: 'Text',
        description: 'Add a rich-text annotation tile.',
        icon: 'utility:text',
        enabled: true
    },
    {
        value: 'image',
        label: 'Image',
        description: 'Embed a static image (logo, KPI badge, banner) by URL.',
        icon: 'utility:image',
        enabled: true
    },
    {
        value: 'clock',
        label: 'Clock',
        description: 'Add a live date/time tile (handy on wall-board dashboards).',
        icon: 'utility:clock',
        enabled: true
    },
    {
        value: 'lwc',
        label: 'Lightning Web Component',
        description: 'Embed an allowlisted LWC at the chosen tile size.',
        icon: 'utility:salesforce1',
        enabled: true
    }
];

export default class CrDashboardWidgetTypeModal extends LightningElement {
    typeOptions = TYPES.map((t) => ({
        ...t,
        disabled: !t.enabled,
        cardClass: t.enabled ? 'type-card' : 'type-card type-card_disabled',
        statusLabel: t.enabled ? '' : 'Coming soon',
        showStatus: !t.enabled
    }));

    handleSelect(event) {
        const value = event.currentTarget.dataset.value;
        const opt = TYPES.find((t) => t.value === value);
        if (!opt || !opt.enabled) return;
        this.dispatchEvent(new CustomEvent('select', { detail: { type: value } }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }
}