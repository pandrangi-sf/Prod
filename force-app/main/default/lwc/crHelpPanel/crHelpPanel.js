import { LightningElement, api, wire, track } from 'lwc';
import getHelpForTool from '@salesforce/apex/CR_HelpService.getHelpForTool';

const SEEN_FLAG_PREFIX = 'cr_help_seen_';

// Per-tool help drawer. Parent renders <c-cr-help-panel tool-key="...">; the
// panel reads CR_Help_Topic__mdt records via the cacheable Apex method,
// auto-opens once per user-per-tool (gated by localStorage), and exposes
// imperative open()/close() for the toolbar ? button.
export default class CrHelpPanel extends LightningElement {
    @api toolKey;
    @api toolLabel = 'this page';
    // Initially-open behavior: 'first-time' (default) opens once per user
    // per tool then stays closed; 'always' opens on every render; 'never'
    // never auto-opens (parent controls via open()).
    @api autoOpen = 'first-time';

    @track sections = [];
    @track loadError = null;
    @track _open = false;

    @wire(getHelpForTool, { toolKey: '$toolKey' })
    wiredHelp({ data, error }) {
        if (data) {
            this.sections = data.map((s, i) => ({
                key: `${this.toolKey}-${i}`,
                heading: s.heading,
                body: s.body,
                iconName: s.iconName || 'utility:info'
            }));
            this.loadError = null;
            this.maybeAutoOpen();
        } else if (error) {
            this.loadError = error?.body?.message || error?.message || 'Could not load help.';
            this.sections = [];
        }
    }

    maybeAutoOpen() {
        if (this._autoOpenChecked) return;
        this._autoOpenChecked = true;
        if (this.autoOpen === 'always') {
            this._open = true;
            this.attachEscapeListener();
            return;
        }
        if (this.autoOpen === 'first-time' && this.sections.length > 0) {
            try {
                const seen = window.localStorage.getItem(SEEN_FLAG_PREFIX + this.toolKey);
                if (!seen) {
                    this._open = true;
                    this.attachEscapeListener();
                    window.localStorage.setItem(SEEN_FLAG_PREFIX + this.toolKey, '1');
                }
            } catch {
                // localStorage may be blocked (private mode, embedded contexts);
                // fall back to opening once per page load.
                this._open = true;
                this.attachEscapeListener();
            }
        }
    }

    @api
    open() {
        this._open = true;
        this.attachEscapeListener();
    }

    @api
    close() {
        this._open = false;
        this.detachEscapeListener();
    }

    @api
    toggle() {
        if (this._open) {
            this.close();
        } else {
            this.open();
        }
    }

    handleClose() {
        this.close();
    }

    disconnectedCallback() {
        this.detachEscapeListener();
    }

    // QA round 2: prior version attached onkeydown to the <aside>, which
    // only fired when focus was already inside the drawer. The toggle
    // button is OUTSIDE the drawer, so opening it via the toggle left
    // focus on the toggle — Escape never reached the drawer. Now we
    // attach a document-level keydown listener while the drawer is open
    // and tear it down when it closes, so Escape works regardless of
    // where focus currently sits.
    _escapeHandler = null;
    attachEscapeListener() {
        if (this._escapeHandler) return;
        this._escapeHandler = (event) => {
            if (event.key === 'Escape' && this._open) {
                event.stopPropagation();
                this._open = false;
                this.detachEscapeListener();
            }
        };
        document.addEventListener('keydown', this._escapeHandler);
    }
    detachEscapeListener() {
        if (this._escapeHandler) {
            document.removeEventListener('keydown', this._escapeHandler);
            this._escapeHandler = null;
        }
    }

    get isOpen() {
        return this._open;
    }
    get hasSections() {
        return this.sections.length > 0;
    }
    get hasError() {
        return !!this.loadError;
    }
}