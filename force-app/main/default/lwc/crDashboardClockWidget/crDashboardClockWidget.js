import { LightningElement, api, track } from 'lwc';

// Demo LWC widget for the Phase E2 dashboard LWC type. Renders a live clock
// in the configured timezone (or the browser's locale by default). Re-renders
// every second; the interval is cleared on disconnect.
export default class CrDashboardClockWidget extends LightningElement {
    @api widgetProps; // { timezone?: string, format?: '12h' | '24h' }
    @track now = new Date();
    _intervalId = null;

    connectedCallback() {
        this._intervalId = setInterval(() => {
            this.now = new Date();
        }, 1000);
    }

    disconnectedCallback() {
        if (this._intervalId) {
            clearInterval(this._intervalId);
            this._intervalId = null;
        }
    }

    get timeLabel() {
        const props = this.widgetProps || {};
        const opts = {
            hour: 'numeric',
            minute: '2-digit',
            second: '2-digit',
            hour12: props.format !== '24h'
        };
        if (props.timezone) opts.timeZone = props.timezone;
        try {
            return new Intl.DateTimeFormat(undefined, opts).format(this.now);
        } catch {
            // Bad timezone — fall back to local time so the tile still renders.
            return this.now.toLocaleTimeString();
        }
    }

    get dateLabel() {
        const props = this.widgetProps || {};
        const opts = { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' };
        if (props.timezone) opts.timeZone = props.timezone;
        try {
            return new Intl.DateTimeFormat(undefined, opts).format(this.now);
        } catch {
            return this.now.toLocaleDateString();
        }
    }

    get tzLabel() {
        return this.widgetProps?.timezone || 'Local time';
    }
}