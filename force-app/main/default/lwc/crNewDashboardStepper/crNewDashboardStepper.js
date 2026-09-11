import { LightningElement, wire, track } from 'lwc';
import listFolders from '@salesforce/apex/CR_DashboardService.listFolders';
import dashboardNameExists from '@salesforce/apex/CR_DashboardService.dashboardNameExists';

// Phase I (v2): multi-step new-dashboard pre-flight. Mounts as a full-page
// stepper above the canvas, reusing the generic crReportBuilderStepper. Two
// steps:
//   1. Basics — Name, Folder (picker + new-folder typed input), Description
//   2. Appearance — Theme, Palette, Grid Size
// Emits `create` with the consolidated form payload, or `cancel` to bail.
const NEW_FOLDER_VALUE = '__cr_new_folder__';

const STEPS = [
    { label: 'Basics',     value: 'basics' },
    { label: 'Appearance', value: 'appearance' }
];

// Shortlist of palette swatches (6 colors each) — full palette colors live
// in crDashboardBuilder; this is just for the visual picker.
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
const PALETTE_OPTIONS = [
    'Aurora','Branding','Nightfall','Wildflowers','Sunrise','Bluegrass','Ocean',
    'Heat','Duck','Pond','Watermelon','Fire','Water','Lake','Mineral_Accessible'
];

export default class CrNewDashboardStepper extends LightningElement {
    // Stepper state
    @track currentStep = 'basics';

    // Step 1: Basics
    @track name = '';
    @track folderChoice = '';        // existing folder name or NEW_FOLDER_VALUE
    @track newFolderName = '';
    @track description = '';
    @track nameError = '';
    @track existingFolders = [];
    @track _validating = false;

    // Step 2: Appearance — defaults match the Dashboard__c picklist defaults
    @track theme = 'Light';
    @track palette = 'Aurora';
    @track gridSize = '12';

    steps = STEPS;

    @wire(listFolders)
    wiredFolders({ data }) {
        if (data) this.existingFolders = data;
    }

    // ---- Folder picker derived state ----
    get folderOptions() {
        const opts = (this.existingFolders || []).map((f) => ({ label: f, value: f }));
        opts.push({ label: '+ New folder...', value: NEW_FOLDER_VALUE });
        return opts;
    }
    get showNewFolderInput() {
        return this.folderChoice === NEW_FOLDER_VALUE;
    }
    get effectiveFolder() {
        if (this.folderChoice === NEW_FOLDER_VALUE) {
            return (this.newFolderName || '').trim();
        }
        return (this.folderChoice || '').trim();
    }

    // ---- Palette swatches for the visual picker ----
    get paletteCards() {
        return PALETTE_OPTIONS.map((p) => {
            const colors = PALETTE_SWATCHES[p] || [];
            const isSelected = this.palette === p;
            return {
                value: p,
                label: this.formatPaletteLabel(p),
                isSelected,
                cardClass: isSelected ? 'palette-card palette-card_selected' : 'palette-card',
                colors: colors.map((c, i) => ({ key: `${p}-${i}`, style: `background:${c};` }))
            };
        });
    }
    formatPaletteLabel(value) {
        // Mineral_Accessible -> "Mineral (Accessible)" for display.
        if (value === 'Mineral_Accessible') return 'Mineral (Accessible)';
        return value;
    }

    // ---- Step visibility + nav ----
    get showBasics()     { return this.currentStep === 'basics'; }
    get showAppearance() { return this.currentStep === 'appearance'; }
    get isLastStep()     { return this.currentStep === 'appearance'; }
    get nextLabel()      { return this.isLastStep ? 'Open Builder' : 'Next'; }
    get nextDisabled() {
        if (this.currentStep === 'basics') {
            if (!this.name || !this.name.trim()) return true;
            if (!this.effectiveFolder) return true;
            if (this._validating) return true;
        }
        return false;
    }

    // ---- Picklist options for Step 2 ----
    themeOptions = [
        { label: 'Light', value: 'Light' },
        { label: 'Dark',  value: 'Dark' }
    ];
    gridOptions = [
        { label: '12 columns (recommended)', value: '12' },
        { label: '9 columns',                value: '9' }
    ];

    // ---- Handlers ----
    handleNameChange(event)   { this.name = event.detail.value; this.nameError = ''; }
    handleFolderChange(event) {
        this.folderChoice = event.detail.value;
        if (this.folderChoice !== NEW_FOLDER_VALUE) this.newFolderName = '';
    }
    handleNewFolderChange(event) { this.newFolderName = event.detail.value; }
    handleDescChange(event)      { this.description = event.detail.value; }
    handleThemeChange(event)     { this.theme = event.detail.value; }
    handleGridChange(event)      { this.gridSize = event.detail.value; }
    handlePaletteSelect(event)   {
        const value = event.currentTarget.dataset.value;
        if (value) this.palette = value;
    }

    async handleNext() {
        if (this.currentStep === 'basics') {
            // Cheap server preflight: catch a duplicate name BEFORE the user
            // wades through Step 2 just to find out the name is taken.
            this._validating = true;
            this.nameError = '';
            try {
                const exists = await dashboardNameExists({ name: this.name.trim() });
                if (exists) {
                    this.nameError = `A dashboard named "${this.name.trim()}" already exists. Pick a different name.`;
                    this._validating = false;
                    return;
                }
                this.currentStep = 'appearance';
            } catch (_) {
                // If preflight fails, let the user proceed; the save will surface
                // the real error if there's an actual problem.
                this.currentStep = 'appearance';
            } finally {
                this._validating = false;
            }
            return;
        }

        if (this.currentStep === 'appearance') {
            this.dispatchEvent(new CustomEvent('create', {
                detail: {
                    name: (this.name || '').trim(),
                    folder: this.effectiveFolder,
                    description: this.description || '',
                    theme: this.theme,
                    palette: this.palette,
                    gridSize: this.gridSize
                }
            }));
        }
    }

    handleBack() {
        if (this.currentStep === 'appearance') {
            this.currentStep = 'basics';
        }
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleHelp() {
        this.dispatchEvent(new CustomEvent('help'));
    }

    // crReportBuilderStepper emits stepchange when the user clicks a step
    // dot directly. Honor the click only if all prior steps' validation
    // would still pass (Step 2 is reachable only after Step 1's name +
    // folder are populated).
    handleStepChange(event) {
        const next = event.detail?.value;
        if (!next) return;
        if (next === 'basics') {
            this.currentStep = 'basics';
        } else if (next === 'appearance' && this.name && this.name.trim() && this.effectiveFolder) {
            this.currentStep = 'appearance';
        }
    }
}