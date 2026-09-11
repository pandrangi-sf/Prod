import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import previewReportXml from '@salesforce/apex/CR_MetadataMigrationService.previewReportXml';
import migrateReportXml from '@salesforce/apex/CR_MetadataMigrationService.migrateReportXml';

export default class CrMigrationConsole extends LightningElement {
    reportName = 'Migrated Report';
    folder = 'Migrated Reports';
    reportXml = '';
    previewJson = '';
    // True only while migrateReportXml is in flight; drives the inline
    // "XML -> CR" transit animation and the disabled state on the button.
    migrating = false;

    // Phase G: toggle the help drawer when the toolbar ? button is clicked
    // (first click opens, next click closes).
    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    handleNameChange(event) {
        this.reportName = event.detail.value;
    }

    handleFolderChange(event) {
        this.folder = event.detail.value;
    }

    handleXmlChange(event) {
        this.reportXml = event.detail.value;
    }

    async preview() {
        try {
            const result = await previewReportXml({ reportName: this.reportName, reportXml: this.reportXml });
            this.previewJson = JSON.stringify(result, null, 2);
        } catch (error) {
            this.toastError(error);
        }
    }

    async migrate() {
        const confirmed = await LightningConfirm.open({
            message: `This will create a new Report Definition named "${this.reportName}" in folder "${this.folder}". Continue?`,
            label: 'Confirm Migration',
            theme: 'warning'
        });
        if (!confirmed) return;
        this.migrating = true;
        try {
            const id = await migrateReportXml({ reportName: this.reportName, folder: this.folder, reportXml: this.reportXml });
            this.dispatchEvent(new ShowToastEvent({ title: 'Report migrated', message: id, variant: 'success' }));
            this.template.querySelector('c-cr-save-button')?.triggerSuccess();
        } catch (error) {
            this.toastError(error);
        } finally {
            this.migrating = false;
        }
    }

    toastError(error) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Migration error',
                message: error?.body?.message || error.message,
                variant: 'error'
            })
        );
    }
}