import { LightningElement, api, track } from 'lwc';
import listFolders from '@salesforce/apex/CR_DashboardService.listFolders';

// Native-style Properties dialog. Holds form state internally so the
// parent's data isn't mutated until the user clicks Save.
const PALETTE_OPTIONS = [
    { label: 'Aurora',              value: 'Aurora' },
    { label: 'Branding',            value: 'Branding' },
    { label: 'Nightfall',           value: 'Nightfall' },
    { label: 'Wildflowers',         value: 'Wildflowers' },
    { label: 'Sunrise',             value: 'Sunrise' },
    { label: 'Bluegrass',           value: 'Bluegrass' },
    { label: 'Ocean',               value: 'Ocean' },
    { label: 'Heat',                value: 'Heat' },
    { label: 'Duck',                value: 'Duck' },
    { label: 'Pond',                value: 'Pond' },
    { label: 'Watermelon',          value: 'Watermelon' },
    { label: 'Fire',                value: 'Fire' },
    { label: 'Water',               value: 'Water' },
    { label: 'Lake',                value: 'Lake' },
    { label: 'Mineral (Accessible)', value: 'Mineral_Accessible' }
];

// Six-color preview swatch per palette. Mirrors the named palettes in the
// native Lightning Dashboard Builder; deliberately small so the modal
// stays compact. Full palettes (used by crChart) live in PALETTE_COLORS
// in crDashboardBuilder; viewer/builder both pull from there.
const PALETTE_SWATCHES = {
    Aurora:              ['#4F46E5','#7C3AED','#DB2777','#F59E0B','#10B981','#06B6D4'],
    Branding:            ['#E8631C','#6BA9B8','#7A4FA3','#3E8E5A','#2C6EA8','#C0392B'],
    Nightfall:           ['#1A1F71','#2E3192','#4B0082','#0F3057','#00587A','#008891'],
    Wildflowers:         ['#FF6F91','#FF9671','#FFC75F','#F9F871','#D65DB1','#845EC2'],
    Sunrise:             ['#F94144','#F3722C','#F8961E','#F9C74F','#90BE6D','#43AA8B'],
    Bluegrass:           ['#2D6A4F','#52B788','#95D5B2','#74C69D','#40916C','#1B4332'],
    Ocean:               ['#03045E','#0077B6','#00B4D8','#90E0EF','#CAF0F8','#48CAE4'],
    Heat:                ['#FFBA08','#F48C06','#E85D04','#DC2F02','#9D0208','#370617'],
    Duck:                ['#264653','#2A9D8F','#E9C46A','#F4A261','#E76F51','#287271'],
    Pond:                ['#386641','#6A994E','#A7C957','#F2E8CF','#BC4749','#588157'],
    Watermelon:          ['#FF595E','#FF7C7C','#FFCA3A','#8AC926','#1982C4','#6A4C93'],
    Fire:                ['#FFB703','#FB8500','#FF6B35','#E63946','#9D0208','#6A040F'],
    Water:               ['#A8DADC','#457B9D','#1D3557','#E63946','#F1FAEE','#A8DADC'],
    Lake:                ['#03045E','#023E8A','#0077B6','#00B4D8','#90E0EF','#CAF0F8'],
    Mineral_Accessible:  ['#0072B2','#E69F00','#56B4E9','#009E73','#F0E442','#D55E00']
};

const GRID_OPTIONS = [
    { label: '12 columns (recommended)', value: '12' },
    { label: '9 columns',                value: '9' }
];
const THEME_OPTIONS = [
    { label: 'Light',                    value: 'Light' },
    { label: 'Dark',                     value: 'Dark' }
];
// "Another person" (OtherUser) was removed: it recorded the choice but never
// impersonated, so offering it was misleading. Only Me / Viewer are real.
const RUN_AS_OPTIONS = [
    { label: 'Me',                       value: 'Me' },
    { label: 'The dashboard viewer',     value: 'Viewer' }
];

export default class CrDashboardPropertiesModal extends LightningElement {
    // Inputs
    @api initialName;
    @api initialFolder;
    @api initialCategory;
    @api initialIsPublic = false;
    @api initialTheme = 'Light';
    @api initialPalette = 'Aurora';
    @api initialGridSize = '12';
    @api initialRunAsMode = 'Me';
    @api initialRunAsUserId;
    @api initialAllowViewerChoice = false;

    // Working copy (so Cancel doesn't leak edits)
    @track name;
    @track folder;
    @track category;
    @track isPublic;
    @track theme;
    @track palette;
    @track gridSize;
    @track runAsMode;
    @track runAsUserId;
    @track allowViewerChoice;

    paletteOptions = PALETTE_OPTIONS;
    gridOptions = GRID_OPTIONS;
    themeOptions = THEME_OPTIONS;
    runAsOptions = RUN_AS_OPTIONS;

    // Existing folder names for the Folder picker. Fetched on connect so the
    // Properties modal offers the same folder list as the creation wizard
    // (crNewDashboardStepper) instead of a free-text box.
    @track existingFolders = [];

    connectedCallback() {
        this.name = this.initialName;
        this.folder = this.initialFolder;
        this.loadFolders();
        this.category = this.initialCategory;
        this.isPublic = !!this.initialIsPublic;
        this.theme = this.initialTheme || 'Light';
        this.palette = this.initialPalette || 'Aurora';
        this.gridSize = this.initialGridSize || '12';
        this.runAsMode = this.initialRunAsMode || 'Me';
        this.runAsUserId = this.initialRunAsUserId;
        this.allowViewerChoice = !!this.initialAllowViewerChoice;
    }

    async loadFolders() {
        try {
            const folders = await listFolders();
            this.existingFolders = Array.isArray(folders) ? folders : [];
        } catch {
            // Folder list is a convenience — on failure the combobox still
            // shows the current folder so the user can keep it.
            this.existingFolders = [];
        }
    }

    // Combobox options built from existing folders. The dashboard's current
    // folder is injected if it isn't already in the list so the user can
    // always keep the value they have. A blank "(No folder)" entry lets the
    // user clear it.
    get folderOptions() {
        const seen = new Set();
        const opts = [{ label: '(No folder)', value: '' }];
        (this.existingFolders || []).forEach((f) => {
            const val = (f || '').trim();
            if (val && !seen.has(val)) {
                seen.add(val);
                opts.push({ label: val, value: val });
            }
        });
        const current = (this.folder || '').trim();
        if (current && !seen.has(current)) {
            opts.push({ label: current, value: current });
        }
        return opts;
    }

    get paletteSwatches() {
        return PALETTE_OPTIONS.map((opt) => {
            const colors = PALETTE_SWATCHES[opt.value] || PALETTE_SWATCHES.Aurora;
            const isSelected = this.palette === opt.value;
            return {
                value: opt.value,
                label: opt.label,
                isSelected,
                cardClass: isSelected ? 'palette-card palette-card_selected' : 'palette-card',
                swatchStyle: `background:${colors[0]};`,
                colors: colors.map((c, i) => ({
                    key: `${opt.value}-${i}`,
                    style: `background:${c};`
                }))
            };
        });
    }

    // "Another person" run-as was removed (no impersonation existed); the
    // user-lookup field that used to show for it is therefore never shown.
    get showRunAsUser() {
        return false;
    }

    handleNameChange(e) { this.name = e.detail.value; }
    handleFolderChange(e) { this.folder = e.detail.value; }
    handleCategoryChange(e) { this.category = e.detail.value; }
    handlePublicChange(e) { this.isPublic = e.detail.checked; }
    handleThemeChange(e) { this.theme = e.detail.value; }
    handleGridChange(e) { this.gridSize = e.detail.value; }
    handleRunAsModeChange(e) {
        this.runAsMode = e.detail.value;
        // Only Me / Viewer remain — neither carries a run-as user, so always
        // clear any (legacy) stored user id so it can't persist on save.
        this.runAsUserId = null;
    }
    handleRunAsUserChange(e) {
        // lightning-input-field for User lookups gives an array of selected ids;
        // we only want one.
        const ids = e.detail?.value || [];
        this.runAsUserId = ids.length ? ids[0] : null;
    }
    handleAllowViewerChange(e) { this.allowViewerChoice = e.detail.checked; }

    handlePaletteSelect(event) {
        const value = event.currentTarget.dataset.value;
        if (value) this.palette = value;
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleSave() {
        if (!this.name || !this.name.trim()) {
            // Don't close — the parent expects a non-blank name
            this.dispatchEvent(new CustomEvent('validationerror', {
                detail: { message: 'Dashboard name is required.' }
            }));
            return;
        }
        this.dispatchEvent(new CustomEvent('apply', {
            detail: {
                name: this.name.trim(),
                folder: this.folder,
                category: this.category,
                isPublic: !!this.isPublic,
                theme: this.theme,
                palette: this.palette,
                gridSize: this.gridSize,
                runAsMode: this.runAsMode,
                runAsUserId: this.runAsUserId || null,
                allowViewerChoice: !!this.allowViewerChoice
            }
        }));
    }
}