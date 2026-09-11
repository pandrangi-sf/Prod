import { LightningElement, api } from 'lwc';

const DEFAULT_STEPS = [
    { label: 'Data', value: 'data' },
    { label: 'Columns', value: 'columns' },
    { label: 'Filters', value: 'filters' },
    { label: 'Group & Summarize', value: 'group' },
    { label: 'Visualize', value: 'visualize' },
    { label: 'Save', value: 'save' }
];

export default class CrReportBuilderStepper extends LightningElement {
    @api steps = DEFAULT_STEPS;
    @api currentStep = 'data';
    // When true, hide the Back / status / slot-actions / Next row entirely. Used by
    // the report builder to keep the Step 1 launcher uncluttered until the user picks
    // a starting point.
    @api hideNavigation = false;

    get showNavigation() {
        return !this.hideNavigation;
    }

    get currentIndex() {
        const i = this.steps.findIndex((s) => s.value === this.currentStep);
        return i < 0 ? 0 : i;
    }

    get currentIndexDisplay() {
        return this.currentIndex + 1;
    }

    get totalSteps() {
        return this.steps.length;
    }

    get currentLabel() {
        return this.steps[this.currentIndex]?.label || '';
    }

    // Each step decorated with display number + a state-driven CSS class.
    // Rendered as numbered pills (replaces lightning-progress-indicator).
    get decoratedSteps() {
        const curIdx = this.currentIndex;
        return this.steps.map((s, i) => {
            let state = 'upcoming';
            if (i < curIdx) state = 'done';
            else if (i === curIdx) state = 'current';
            const isCurrent = i === curIdx;
            return {
                value: s.value,
                label: s.label,
                displayNum: i + 1,
                itemClass: `step-pill step-pill--${state}`,
                connectorClass: i < curIdx ? 'step-connector step-connector--done' : 'step-connector',
                showConnector: i < this.steps.length - 1,
                isCurrent,
                // ARIA only accepts page|step|location|date|time|true|false.
                // The previous implementation set aria-current to the step's
                // custom value ("data", "columns", ...) which screen readers
                // resolved to "true" and announced EVERY pill as current.
                // Only the active pill should carry aria-current="step";
                // others render with no aria-current at all.
                ariaCurrent: isCurrent ? 'step' : null
            };
        });
    }

    /**
     * Width style for the accent progress bar below the lightning stepper.
     * 0% on the first step, 100% on the last, evenly distributed between.
     * CSS transitions interpolate the width on each step change.
     */
    get progressFillStyle() {
        const total = this.steps.length;
        if (total <= 1) return 'width: 100%;';
        const ratio = this.currentIndex / (total - 1);
        const pct = Math.max(0, Math.min(100, Math.round(ratio * 100)));
        return `width: ${pct}%;`;
    }

    get isFirstStep() {
        return this.currentIndex === 0;
    }

    get isLastStep() {
        return this.currentIndex >= this.steps.length - 1;
    }

    handleBack() {
        if (this.isFirstStep) return;
        this.fireStepChange(this.steps[this.currentIndex - 1].value);
    }

    handleNext() {
        if (this.isLastStep) return;
        this.fireStepChange(this.steps[this.currentIndex + 1].value);
    }

    handleStepClick(event) {
        const value = event.currentTarget.dataset.value;
        if (value && value !== this.currentStep) {
            this.fireStepChange(value);
        }
    }

    fireStepChange(value) {
        this.dispatchEvent(new CustomEvent('stepchange', { detail: { value } }));
    }
}