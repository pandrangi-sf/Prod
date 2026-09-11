import { LightningElement, api } from 'lwc';

// Demo LWC widget for the Phase E2 dashboard LWC type. Renders a static KPI
// card driven entirely by widget config (no Apex). Accepts:
//   { headline: string, value: string|number, subtitle?: string,
//     iconName?: string ('utility:'-prefixed), tone?: 'positive' | 'negative' | 'neutral' }
export default class CrDashboardKpiTileWidget extends LightningElement {
    @api widgetProps;

    get headline() {
        return this.widgetProps?.headline || 'KPI';
    }
    get value() {
        const v = this.widgetProps?.value;
        return v === null || v === undefined || v === '' ? '—' : String(v);
    }
    get subtitle() {
        return this.widgetProps?.subtitle || '';
    }
    get iconName() {
        return this.widgetProps?.iconName || 'utility:dashboard_ext';
    }
    get cardClass() {
        const tone = this.widgetProps?.tone || 'neutral';
        return `kpi-tile kpi-tile_${tone}`;
    }
}