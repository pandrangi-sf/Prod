import { LightningElement, track } from 'lwc';
import getActiveTheme from '@salesforce/apex/CR_ThemeService.getActiveTheme';
import saveTheme from '@salesforce/apex/CR_ThemeService.saveTheme';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { applyBrandTheme, refreshBrandTheme } from 'c/crBrandTheme';

// Built-in Orlando Health default (matches CR_ThemeService).
const OH_DEFAULT = {
    palette: ['#e8631c', '#6ba9b8', '#7a4fa3', '#3e8e5a', '#2c6ea8', '#c0392b', '#be7a0a', '#b5507a'],
    primary: '#e8631c',
    accent: '#6ba9b8',
    header: '#2b3a47'
};

export default class CrThemeManager extends LightningElement {
    @track themeId;
    @track name = 'Orlando Health';
    @track primaryColor = OH_DEFAULT.primary;
    @track accentColor = OH_DEFAULT.accent;
    @track headerColor = OH_DEFAULT.header;
    @track palette = [...OH_DEFAULT.palette];
    canManage = false;
    loading = true;
    saving = false;

    connectedCallback() {
        applyBrandTheme(this);
        this.load();
    }

    async load() {
        try {
            const t = await getActiveTheme();
            this.canManage = !!t.canManage;
            this.themeId = t.id;
            this.name = t.name || 'Orlando Health';
            this.primaryColor = t.primaryColor || OH_DEFAULT.primary;
            this.accentColor = t.accentColor || OH_DEFAULT.accent;
            this.headerColor = t.headerColor || OH_DEFAULT.header;
            this.palette = t.chartPalette && t.chartPalette.length ? [...t.chartPalette] : [...OH_DEFAULT.palette];
        } catch (e) {
            // keep OH defaults
        } finally {
            this.loading = false;
        }
    }

    get paletteRows() {
        return this.palette.map((c, i) => ({
            key: `${i}-${c}`,
            index: String(i),
            color: c,
            swatchStyle: `background:${c};`
        }));
    }

    // Simple preview bars — varied heights so the palette reads as a chart.
    get previewBars() {
        const heights = [70, 92, 60, 100, 78, 88, 55, 96];
        return this.palette.map((c, i) => ({
            key: `bar-${i}`,
            style: `background:${c}; height:${heights[i % heights.length]}px;`
        }));
    }

    get headerPreviewStyle() {
        return `background:${this.headerColor}; color:#ffffff;`;
    }

    get accentChipStyle() {
        return `background:${this.accentColor};`;
    }

    get primaryChipStyle() {
        return `background:${this.primaryColor};`;
    }

    get readOnly() {
        return !this.canManage;
    }

    handleName(e) { this.name = e.target.value; }
    handlePrimary(e) { this.primaryColor = e.target.value; }
    handleAccent(e) { this.accentColor = e.target.value; }
    handleHeader(e) { this.headerColor = e.target.value; }

    handlePaletteColor(e) {
        const i = parseInt(e.target.dataset.index, 10);
        const v = e.target.value;
        this.palette = this.palette.map((c, idx) => (idx === i ? v : c));
    }

    addColor() {
        this.palette = [...this.palette, '#888888'];
    }

    removeColor(e) {
        const i = parseInt(e.currentTarget.dataset.index, 10);
        this.palette = this.palette.filter((_, idx) => idx !== i);
    }

    resetDefault() {
        this.palette = [...OH_DEFAULT.palette];
        this.primaryColor = OH_DEFAULT.primary;
        this.accentColor = OH_DEFAULT.accent;
        this.headerColor = OH_DEFAULT.header;
    }

    async save() {
        if (!this.palette.length) {
            this.toast('Add a color', 'The chart palette needs at least one color.', 'warning');
            return;
        }
        this.saving = true;
        try {
            const payload = JSON.stringify({
                id: this.themeId,
                name: this.name,
                chartPalette: this.palette,
                primaryColor: this.primaryColor,
                headerColor: this.headerColor,
                accentColor: this.accentColor
            });
            const id = await saveTheme({ payloadJson: payload });
            this.themeId = id;
            // Re-publish the CSS variables so the app re-skins immediately.
            await refreshBrandTheme(this);
            this.toast('Saved', 'Brand theme updated. The app is re-skinned now; charts pick up the palette on next load.', 'success');
        } catch (e) {
            const msg = (e && e.body && e.body.message) || 'Could not save the theme.';
            this.toast('Error', msg, 'error');
        } finally {
            this.saving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}