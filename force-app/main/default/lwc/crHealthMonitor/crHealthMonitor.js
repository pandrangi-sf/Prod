import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import getFrameworkApexJobs from '@salesforce/apex/CR_HealthService.getFrameworkApexJobs';
import getScheduledCrons from '@salesforce/apex/CR_HealthService.getScheduledCrons';
import getRecentErrors from '@salesforce/apex/CR_HealthService.getRecentErrors';
import getHealthKpis from '@salesforce/apex/CR_HealthService.getHealthKpis';
import getEtlSnapshot from '@salesforce/apex/CR_HealthService.getEtlSnapshot';
import scheduleNightlyETLIfMissing from '@salesforce/apex/CR_HealthService.scheduleNightlyETLIfMissing';
import getSlowReports from '@salesforce/apex/CR_RunHistoryService.getSlowReports';

// Manual-refresh-only by design. Auto-poll was scoped out during Phase H risk
// review — admins can click Refresh whenever they want fresh data. The wires
// also re-fire whenever the page becomes visible after a tab switch.
export default class CrHealthMonitor extends NavigationMixin(LightningElement) {
    @track expandedRows = {}; // keyed by job/error id

    wiredJobsResult;
    wiredCronsResult;
    wiredErrorsResult;
    wiredKpisResult;
    wiredSnapshotResult;
    wiredSlowReportsResult;

    @track _scheduling = false;

    @wire(getFrameworkApexJobs, { hoursBack: 24 })
    wiredJobs(result) {
        this.wiredJobsResult = result;
    }
    @wire(getScheduledCrons)
    wiredCrons(result) {
        this.wiredCronsResult = result;
    }
    @wire(getRecentErrors, { daysBack: 7 })
    wiredErrors(result) {
        this.wiredErrorsResult = result;
    }
    @wire(getHealthKpis)
    wiredKpis(result) {
        this.wiredKpisResult = result;
    }
    @wire(getEtlSnapshot)
    wiredSnapshot(result) {
        this.wiredSnapshotResult = result;
    }
    // Phase 1 v7: top-N slowest saved reports by avg execution duration over
    // the last 7 days. Empty until Report_Run__c rows accumulate post-deploy.
    @wire(getSlowReports, { lookbackDays: 7, maxResults: 10 })
    wiredSlowReports(result) {
        this.wiredSlowReportsResult = result;
    }

    // ---- KPIs ----
    get kpis() {
        return this.wiredKpisResult?.data || {
            jobsFailedToday: 0,
            missingFrameworkCrons: 0,
            errorsLast24h: 0,
            nightlyCronScheduled: true // optimistic so the tile shows green during initial load
        };
    }
    get jobsFailedClass() {
        return this.kpis.jobsFailedToday > 0 ? 'kpi-tile kpi-tile_red' : 'kpi-tile kpi-tile_green';
    }
    get cronMissingClass() {
        return this.kpis.missingFrameworkCrons > 0 ? 'kpi-tile kpi-tile_red' : 'kpi-tile kpi-tile_green';
    }
    get errorsClass() {
        return this.kpis.errorsLast24h > 0 ? 'kpi-tile kpi-tile_red' : 'kpi-tile kpi-tile_green';
    }
    get cronMissingLabel() {
        // Reads better than just a count when the value is the binary nightly-cron state.
        return this.kpis.nightlyCronScheduled ? 'Nightly ETL scheduled' : 'Nightly ETL MISSING';
    }

    // ---- ETL snapshot + storage ----
    get snapshot() {
        return this.wiredSnapshotResult?.data || {
            factCounts: [],
            totalToday: 0,
            storageUsedMB: null,
            storageMaxMB: null,
            storagePercent: null
        };
    }
    get factCountRows() {
        return (this.snapshot.factCounts || []).map((f) => ({
            ...f,
            countDisplay: (f.todayCount || 0).toLocaleString(),
            rowClass: (f.todayCount || 0) > 0 ? 'fact-row' : 'fact-row fact-row_empty'
        }));
    }
    get hasFactCounts() {
        return this.factCountRows.length > 0;
    }
    get totalTodayDisplay() {
        return (this.snapshot.totalToday || 0).toLocaleString();
    }
    get totalTodayClass() {
        return (this.snapshot.totalToday || 0) > 0
            ? 'kpi-tile kpi-tile_green'
            : 'kpi-tile';
    }
    get hasStorage() {
        return this.snapshot.storageMaxMB !== null && this.snapshot.storageMaxMB !== undefined;
    }
    get storageLabel() {
        const used = (this.snapshot.storageUsedMB || 0).toLocaleString();
        const max = (this.snapshot.storageMaxMB || 0).toLocaleString();
        return `${used} / ${max} MB`;
    }
    get storagePercentDisplay() {
        const pct = this.snapshot.storagePercent;
        return pct === null || pct === undefined ? '—' : `${pct}%`;
    }
    get storageTileClass() {
        const pct = this.snapshot.storagePercent;
        if (pct === null || pct === undefined) return 'kpi-tile';
        if (pct >= 90) return 'kpi-tile kpi-tile_red';
        if (pct >= 70) return 'kpi-tile kpi-tile_amber';
        return 'kpi-tile kpi-tile_green';
    }
    get storageBarStyle() {
        const pct = this.snapshot.storagePercent;
        const clamped = pct === null || pct === undefined ? 0 : Math.min(100, Math.max(0, pct));
        return `width: ${clamped}%;`;
    }
    get storageBarClass() {
        const pct = this.snapshot.storagePercent;
        if (pct === null || pct === undefined) return 'storage-bar__fill';
        if (pct >= 90) return 'storage-bar__fill storage-bar__fill_red';
        if (pct >= 70) return 'storage-bar__fill storage-bar__fill_amber';
        return 'storage-bar__fill storage-bar__fill_green';
    }

    // ---- Apex Jobs panel ----
    get jobs() {
        return (this.wiredJobsResult?.data || []).map((j) => ({
            ...j,
            statusClass: j.isFailed ? 'job-row job-row_failed' : 'job-row',
            itemsLabel: j.totalJobItems
                ? `${j.jobItemsProcessed ?? 0} / ${j.totalJobItems}`
                : `${j.jobItemsProcessed ?? 0}`,
            isExpanded: !!this.expandedRows[j.id],
            hasExtended: !!j.extendedStatus
        }));
    }
    get hasJobs() { return this.jobs.length > 0; }
    get jobsEmptyMessage() {
        return this.wiredJobsResult?.data
            ? 'No framework Apex jobs in the last 24 hours.'
            : 'Loading jobs…';
    }

    // ---- Scheduled Jobs panel ----
    get crons() {
        return (this.wiredCronsResult?.data || []).map((c) => ({
            ...c,
            stateClass: c.state === 'WAITING' ? 'cron-row' : 'cron-row cron-row_warn'
        }));
    }
    get hasCrons() { return this.crons.length > 0; }
    get nightlyMissing() {
        // Show the Schedule helper when our wired data confirms the cron isn't
        // registered. We deliberately don't fall back to optimistic during
        // load — only act on confirmed empty results, so the button doesn't
        // flash in and disappear.
        return this.wiredKpisResult?.data
            && this.wiredKpisResult.data.nightlyCronScheduled === false;
    }
    get scheduleButtonLabel() {
        return this._scheduling ? 'Scheduling…' : 'Schedule Nightly ETL';
    }
    get scheduleButtonDisabled() {
        return this._scheduling;
    }

    // ---- Slow Reports panel (Phase 1 v7) ----
    get slowReports() {
        return (this.wiredSlowReportsResult?.data || []).map((r) => ({
            id: r.reportDefinitionId,
            reportName: r.reportName || '(deleted report)',
            avgMs: Math.round(r.avgDurationMs || 0),
            maxMs: Math.round(r.maxDurationMs || 0),
            runCount: r.runCount || 0,
            lastRunAt: r.lastRunAt
        }));
    }
    get hasSlowReports() { return this.slowReports.length > 0; }
    get slowReportsEmptyMessage() {
        return this.wiredSlowReportsResult?.data
            ? 'No saved-report executions logged in the last 7 days.'
            : 'Loading run history…';
    }

    // ---- Recent Errors panel ----
    get errors() {
        return (this.wiredErrorsResult?.data || []).map((e) => ({
            ...e,
            isExpanded: !!this.expandedRows[e.id],
            displayLabel: e.componentName
                ? `${e.dashboardName} · ${e.componentName}`
                : e.dashboardName
        }));
    }
    get hasErrors() { return this.errors.length > 0; }

    // ---- Actions ----
    handleRefresh() {
        if (this.wiredJobsResult) refreshApex(this.wiredJobsResult);
        if (this.wiredCronsResult) refreshApex(this.wiredCronsResult);
        if (this.wiredErrorsResult) refreshApex(this.wiredErrorsResult);
        if (this.wiredKpisResult) refreshApex(this.wiredKpisResult);
        if (this.wiredSnapshotResult) refreshApex(this.wiredSnapshotResult);
        if (this.wiredSlowReportsResult) refreshApex(this.wiredSlowReportsResult);
    }

    handleToggleRow(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.expandedRows = {
            ...this.expandedRows,
            [id]: !this.expandedRows[id]
        };
    }

    async handleScheduleNightly() {
        if (this._scheduling) return;
        const proceed = await LightningConfirm.open({
            label: 'Schedule Nightly ETL?',
            theme: 'info',
            message:
                'This adds the "Vital Reports Nightly ETL" cron at 2 AM daily. ' +
                'It does NOT run any batch immediately. The cron registers under your user; ' +
                'you can unschedule it later via Setup → Scheduled Jobs.'
        });
        if (!proceed) return;

        this._scheduling = true;
        try {
            const cronId = await scheduleNightlyETLIfMissing();
            if (cronId) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Nightly ETL scheduled',
                    message: 'The job is registered and will fire at 2 AM daily.',
                    variant: 'success'
                }));
            } else {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Already scheduled',
                    message: 'The nightly ETL cron is already registered. No change made.',
                    variant: 'info'
                }));
            }
            this.handleRefresh();
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not schedule',
                message: error?.body?.message || error?.message || 'Unknown error',
                variant: 'error'
            }));
        } finally {
            this._scheduling = false;
        }
    }

    handleOpenSetupJobs() {
        // Setup → Environments → Jobs → Apex Jobs — open in a new tab via
        // standard__webPage so the admin keeps the monitor tab open.
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: '/lightning/setup/AsyncApexJobs/home' }
        });
    }
    handleOpenSetupCron() {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: '/lightning/setup/ScheduledJobs/home' }
        });
    }

    // ---- Help drawer ----
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }
}