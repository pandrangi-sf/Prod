/**
 * Runtime brand theming for the Vital Reports app (Phase 3b).
 *
 * Fetches the active CR_Brand_Theme__c (cached, one Apex round-trip per session)
 * and publishes it as CSS custom properties. Two layers:
 *
 *   1. cr-* tokens  — consumed by our own component CSS (var(--cr-brand-primary, ...)).
 *   2. SLDS/LWC brand tokens — re-skins STOCK components (brand buttons, links,
 *      spinners, tabs) app-wide without editing each component's stylesheet.
 *
 * Custom properties cascade through shadow DOM, so setting them on the document
 * root themes every nested component. We also set them on the calling component's
 * host as a fallback in case the security model blocks document-level writes.
 */
import getActiveTheme from '@salesforce/apex/CR_ThemeService.getActiveTheme';

let themePromise = null;
let lastTheme = null;

// pct < 0 darkens, > 0 lightens toward white.
function shade(hex, pct) {
    const h = String(hex || '').replace('#', '');
    if (h.length !== 6) return hex;
    const num = parseInt(h, 16);
    if (isNaN(num)) return hex;
    const parts = [(num >> 16) & 0xff, (num >> 8) & 0xff, num & 0xff].map((c) => {
        const v = pct < 0 ? c + c * pct : c + (255 - c) * pct;
        return Math.max(0, Math.min(255, Math.round(v)));
    });
    return '#' + parts.map((c) => c.toString(16).padStart(2, '0')).join('');
}

function tokensFor(theme) {
    const primary = theme.primaryColor || '#e8631c';
    const accent = theme.accentColor || '#6ba9b8';
    const header = theme.headerColor || '#2b3a47';
    const primaryHover = shade(primary, -0.15);
    const primarySoft = shade(primary, 0.86);

    return {
        // Vital Reports tokens (our CSS reads these).
        '--cr-brand-primary': primary,
        '--cr-brand-primary-hover': primaryHover,
        '--cr-brand-primary-soft': primarySoft,
        '--cr-brand-accent': accent,
        '--cr-brand-accent-soft': shade(accent, 0.86),
        '--cr-brand-header': header,
        '--cr-brand-on-header': '#ffffff',

        // Stock SLDS/LWC brand tokens — themes built-in components app-wide.
        '--lwc-brandAccessible': primary,
        '--lwc-brandAccessibleActive': primaryHover,
        '--lwc-brandPrimary': primary,
        '--lwc-colorBrand': primary,
        '--lwc-colorBorderBrand': primary,
        '--lwc-colorTextLink': primary,
        '--lwc-colorTextLinkActive': shade(primary, -0.2),
        '--lwc-colorTextBrand': primary
    };
}

function paint(target, tokens) {
    if (!target || !target.style || typeof target.style.setProperty !== 'function') return;
    Object.keys(tokens).forEach((k) => {
        try {
            target.style.setProperty(k, tokens[k]);
        } catch (e) {
            // Security model may block this target; the other target still applies.
        }
    });
}

/**
 * Apply the active brand theme. Safe to call from every page component's
 * connectedCallback — the Apex call is cached and the paint is idempotent.
 * @param {object} cmp the calling LightningElement (optional host fallback)
 */
export function applyBrandTheme(cmp) {
    if (!themePromise) {
        themePromise = getActiveTheme().catch(() => null);
    }
    return themePromise.then((theme) => {
        if (!theme) return;
        lastTheme = theme;
        const tokens = tokensFor(theme);
        // Document root: cascades to every component in the app.
        try {
            if (typeof document !== 'undefined') paint(document.documentElement, tokens);
        } catch (e) {
            /* blocked — host fallback below still themes this page */
        }
        // Host fallback: cascades into this component's subtree.
        try {
            if (cmp && cmp.template && cmp.template.host) paint(cmp.template.host, tokens);
        } catch (e) {
            /* no host access */
        }
    });
}

/** Force a re-fetch + repaint (used after an admin saves a new theme). */
export function refreshBrandTheme(cmp) {
    themePromise = null;
    return applyBrandTheme(cmp);
}

export function getCachedTheme() {
    return lastTheme;
}