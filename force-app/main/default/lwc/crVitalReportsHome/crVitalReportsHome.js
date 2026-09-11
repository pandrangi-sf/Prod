import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import HAS_ADMIN_VIEW from '@salesforce/customPermission/Vital_Reports_Admin_View';
import getHelpForTool from '@salesforce/apex/CR_HelpService.getHelpForTool';
import getTilesForCurrentUser from '@salesforce/apex/CR_HomeTileService.getTilesForCurrentUser';
import { applyBrandTheme } from 'c/crBrandTheme';

const TOOL_KEY = 'crVitalReportsHome';
// CR_Help_Topic records with Section_Order__c < ADMIN_SECTION_THRESHOLD are
// shown to everyone; records at or above are admin-only.
const ADMIN_SECTION_THRESHOLD = 100;

export default class CrVitalReportsHome extends NavigationMixin(LightningElement) {
    isAdmin = HAS_ADMIN_VIEW === true;
    helpOpen = false;
    userSections = [];
    adminSections = [];
    rawTiles = [];

    @wire(getTilesForCurrentUser)
    wiredTiles({ data }) {
        if (data) this.rawTiles = data;
    }

    @wire(getHelpForTool, { toolKey: TOOL_KEY })
    wiredHelp({ data }) {
        if (!data) return;
        const decorated = data.map((s, i) => ({
            key: `${TOOL_KEY}-${i}`,
            heading: s.heading,
            body: s.body,
            iconName: s.iconName || 'utility:info',
            sectionOrder: Number(s.sectionOrder) || 0
        }));
        this.userSections = decorated.filter((s) => s.sectionOrder < ADMIN_SECTION_THRESHOLD);
        this.adminSections = decorated.filter((s) => s.sectionOrder >= ADMIN_SECTION_THRESHOLD);
    }

    get tiles() {
        return this.rawTiles.map((t) => ({
            key: t.key,
            label: t.label,
            desc: t.description,
            iconName: t.iconName,
            iconBg: `tile__icon-wrap--${t.colorScheme}`,
            target: t.target
        }));
    }

    get audienceLabel() {
        return this.isAdmin ? 'Admin view' : 'User view';
    }

    get audienceBadgeClass() {
        return this.isAdmin ? 'audience-badge audience-badge--admin' : 'audience-badge audience-badge--user';
    }

    get hasUserHelp() {
        return this.userSections.length > 0;
    }

    get hasAdminHelp() {
        return this.isAdmin && this.adminSections.length > 0;
    }

    handleTileClick(event) {
        const target = event.currentTarget.dataset.target;
        if (!target) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: target }
        });
    }

    handleTileKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleTileClick(event);
        }
    }

    handleOpenHelp() {
        this.helpOpen = true;
        this.attachEscapeListener();
    }

    handleCloseHelp() {
        this.helpOpen = false;
        this.detachEscapeListener();
    }

    connectedCallback() {
        // Publish the active brand theme as CSS variables so the app follows the
        // admin-set colors (Home is typically the first Vital Reports page loaded).
        applyBrandTheme(this);
    }

    disconnectedCallback() {
        this.detachEscapeListener();
    }

    // The help toggle button lives outside the drawer, so a keydown handler
    // on the <aside> would never fire (focus stays on the toggle). Listen at
    // the document level while open so Escape closes regardless of focus.
    _escapeHandler = null;
    attachEscapeListener() {
        if (this._escapeHandler) return;
        this._escapeHandler = (event) => {
            if (event.key === 'Escape' && this.helpOpen) {
                event.stopPropagation();
                this.helpOpen = false;
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
}