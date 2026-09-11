import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import listSubscriptions from '@salesforce/apex/CR_SubscriptionService.listSubscriptions';
import listSubscribableAssets from '@salesforce/apex/CR_SubscriptionService.listSubscribableAssets';
import listRecipients from '@salesforce/apex/CR_SubscriptionService.listRecipients';
import upsertSubscription from '@salesforce/apex/CR_SubscriptionService.upsertSubscription';
import deleteSubscription from '@salesforce/apex/CR_SubscriptionService.deleteSubscription';
import upsertRecipient from '@salesforce/apex/CR_SubscriptionService.upsertRecipient';
import deleteRecipient from '@salesforce/apex/CR_SubscriptionService.deleteRecipient';
import sendNow from '@salesforce/apex/CR_SubscriptionService.sendNow';

const FREQUENCY_OPTIONS = [
    { label: 'Daily', value: 'Daily' },
    { label: 'Weekly', value: 'Weekly' },
    { label: 'Monthly', value: 'Monthly' }
];

const DAY_OF_WEEK_OPTIONS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].map(
    (d) => ({ label: d, value: d })
);

const RECIPIENT_TYPE_OPTIONS = [
    { label: 'User', value: 'User' },
    { label: 'Public Group', value: 'Public Group' },
    { label: 'Email', value: 'Email' }
];

const SUBSCRIPTION_COLUMNS = [
    { label: 'Asset', fieldName: 'assetName', type: 'text', wrapText: true },
    { label: 'Type', fieldName: 'assetType', type: 'text', fixedWidth: 90 },
    { label: 'Schedule', fieldName: 'scheduleLabel', type: 'text' },
    { label: 'Active', fieldName: 'active', type: 'boolean', fixedWidth: 70 },
    { label: 'Recipients', fieldName: 'recipientCount', type: 'number', fixedWidth: 100, cellAttributes: { alignment: 'left' } },
    { label: 'Last Status', fieldName: 'lastStatus', type: 'text', fixedWidth: 110 },
    { label: 'Next Run', fieldName: 'nextRunAt', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'Edit', name: 'edit', iconName: 'utility:edit' },
                { label: 'Send test now', name: 'send', iconName: 'utility:send' },
                { label: 'Delete', name: 'delete', iconName: 'utility:delete' }
            ]
        }
    }
];

const EMPTY_DRAFT = {
    id: null,
    assetId: null,
    frequency: 'Daily',
    dayOfWeek: 'Monday',
    dayOfMonth: 1,
    hourOfDay: 6,
    active: true,
    includeHtmlTable: true,
    includeCsvAttachment: true,
    sendIfEmpty: false,
    maxInlineRows: 100,
    filterOverrideJson: ''
};

const EMPTY_RECIPIENT = {
    recipientType: 'User',
    userId: null,
    groupId: null,
    groupName: null,
    email: null
};

export default class CrSubscriptionManager extends LightningElement {
    @track subscriptions = [];
    @track recipients = [];
    @track draft = { ...EMPTY_DRAFT };
    @track newRecipient = { ...EMPTY_RECIPIENT };
    @track busy = false;
    @track loadError;
    @track showEditor = false;

    columns = SUBSCRIPTION_COLUMNS;
    frequencyOptions = FREQUENCY_OPTIONS;
    dayOfWeekOptions = DAY_OF_WEEK_OPTIONS;
    recipientTypeOptions = RECIPIENT_TYPE_OPTIONS;

    _assetsById = new Map();
    _assetOptions = [];

    connectedCallback() {
        this.loadAll();
    }

    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    async loadAll() {
        this.busy = true;
        this.loadError = null;
        try {
            const [subs, assets] = await Promise.all([listSubscriptions(), listSubscribableAssets()]);
            this.subscriptions = (subs || []).map((s) => this.decorate(s));
            this._assetsById = new Map((assets || []).map((a) => [a.id, a]));
            this._assetOptions = (assets || []).map((a) => ({
                label: `${a.assetType}: ${a.name}${a.broadcastSafe ? '' : '  (not broadcast-safe)'}`,
                value: a.id
            }));
        } catch (error) {
            this.loadError = this.errMsg(error, 'Failed to load subscriptions.');
        } finally {
            this.busy = false;
        }
    }

    decorate(summary) {
        return {
            ...summary,
            scheduleLabel: this.scheduleLabel(summary)
        };
    }

    scheduleLabel(s) {
        const hour = s.hourOfDay == null ? 6 : s.hourOfDay;
        const time = `${String(hour).padStart(2, '0')}:00`;
        if (s.frequency === 'Weekly') {
            return `Weekly · ${s.dayOfWeek || 'Monday'} · ${time}`;
        }
        if (s.frequency === 'Monthly') {
            return `Monthly · day ${s.dayOfMonth || 1} · ${time}`;
        }
        return `Daily · ${time}`;
    }

    get hasSubscriptions() {
        return this.subscriptions.length > 0;
    }

    get assetOptions() {
        return this._assetOptions;
    }

    get editorTitle() {
        return this.draft.id ? 'Edit subscription' : 'New subscription';
    }

    get showDayOfWeek() {
        return this.draft.frequency === 'Weekly';
    }

    get showDayOfMonth() {
        return this.draft.frequency === 'Monthly';
    }

    // Recipients can only be attached once the subscription exists (the child
    // record needs a parent Id).
    get recipientsDisabled() {
        return !this.draft.id;
    }

    get selectedAssetWarning() {
        const asset = this._assetsById.get(this.draft.assetId);
        if (asset && asset.broadcastSafe === false) {
            return `"${asset.name}" is not marked Broadcast Safe — delivery will be refused until an admin certifies it.`;
        }
        return null;
    }

    get isUserRecipient() {
        return this.newRecipient.recipientType === 'User';
    }

    get isGroupRecipient() {
        return this.newRecipient.recipientType === 'Public Group';
    }

    get isEmailRecipient() {
        return this.newRecipient.recipientType === 'Email';
    }

    get decoratedRecipients() {
        return this.recipients.map((r) => ({
            ...r,
            display: this.recipientDisplay(r)
        }));
    }

    recipientDisplay(r) {
        if (r.recipientType === 'Email') return r.email;
        if (r.recipientType === 'Public Group') return r.groupName || r.groupId;
        return r.userName || r.userId;
    }

    handleNew() {
        this.draft = { ...EMPTY_DRAFT };
        this.recipients = [];
        this.newRecipient = { ...EMPTY_RECIPIENT };
        this.showEditor = true;
    }

    handleCloseEditor() {
        this.showEditor = false;
        this.draft = { ...EMPTY_DRAFT };
        this.recipients = [];
    }

    async handleRowAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'edit') {
            this.openEditor(row);
        } else if (action === 'send') {
            await this.sendTest(row.id);
        } else if (action === 'delete') {
            await this.removeSubscription(row);
        }
    }

    async openEditor(row) {
        this.draft = {
            id: row.id,
            assetId: row.reportDefinitionId || row.dashboardId,
            frequency: row.frequency || 'Daily',
            dayOfWeek: row.dayOfWeek || 'Monday',
            dayOfMonth: row.dayOfMonth || 1,
            hourOfDay: row.hourOfDay == null ? 6 : row.hourOfDay,
            active: !!row.active,
            includeHtmlTable: !!row.includeHtmlTable,
            includeCsvAttachment: !!row.includeCsvAttachment,
            sendIfEmpty: !!row.sendIfEmpty,
            maxInlineRows: row.maxInlineRows || 100,
            filterOverrideJson: row.filterOverrideJson || ''
        };
        this.newRecipient = { ...EMPTY_RECIPIENT };
        this.showEditor = true;
        await this.reloadRecipients();
    }

    async reloadRecipients() {
        if (!this.draft.id) {
            this.recipients = [];
            return;
        }
        try {
            this.recipients = await listRecipients({ subscriptionId: this.draft.id });
        } catch (error) {
            this.toast(this.errMsg(error, 'Failed to load recipients.'), 'error');
        }
    }

    handleDraftChange(event) {
        const field = event.currentTarget.dataset.field;
        if (!field) return;
        const detail = event.detail || {};
        let value;
        if (typeof detail.checked === 'boolean') {
            value = detail.checked;
        } else if (detail.value !== undefined) {
            value = detail.value;
        } else {
            value = event.target.value;
        }
        if (field === 'hourOfDay' || field === 'dayOfMonth' || field === 'maxInlineRows') {
            value = value === '' || value == null ? null : Number(value);
        }
        this.draft = { ...this.draft, [field]: value };
    }

    async handleSaveSubscription() {
        if (!this.draft.assetId) {
            this.toast('Choose a report or dashboard first.', 'warning');
            return;
        }
        const asset = this._assetsById.get(this.draft.assetId);
        const payload = {
            id: this.draft.id,
            reportDefinitionId: asset && asset.assetType === 'Report' ? this.draft.assetId : null,
            dashboardId: asset && asset.assetType === 'Dashboard' ? this.draft.assetId : null,
            frequency: this.draft.frequency,
            dayOfWeek: this.draft.frequency === 'Weekly' ? this.draft.dayOfWeek : null,
            dayOfMonth: this.draft.frequency === 'Monthly' ? this.draft.dayOfMonth : null,
            hourOfDay: this.draft.hourOfDay,
            active: this.draft.active,
            includeHtmlTable: this.draft.includeHtmlTable,
            includeCsvAttachment: this.draft.includeCsvAttachment,
            sendIfEmpty: this.draft.sendIfEmpty,
            maxInlineRows: this.draft.maxInlineRows,
            filterOverrideJson: this.draft.filterOverrideJson || null
        };
        this.busy = true;
        try {
            const wasNew = !this.draft.id;
            const id = await upsertSubscription({ payloadJson: JSON.stringify(payload) });
            this.draft = { ...this.draft, id };
            this.toast(wasNew ? 'Subscription created. You can now add recipients.' : 'Subscription saved.', 'success');
            await this.loadAll();
            await this.reloadRecipients();
        } catch (error) {
            this.toast(this.errMsg(error, 'Save failed.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    async removeSubscription(row) {
        const proceed = await LightningConfirm.open({
            label: 'Delete subscription',
            theme: 'warning',
            message: `Delete the subscription for "${row.assetName || row.name}" and all its recipients?`
        });
        if (!proceed) return;
        this.busy = true;
        try {
            await deleteSubscription({ subscriptionId: row.id });
            this.toast('Subscription deleted.', 'success');
            if (this.draft.id === row.id) {
                this.handleCloseEditor();
            }
            await this.loadAll();
        } catch (error) {
            this.toast(this.errMsg(error, 'Delete failed.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    async sendTest(subscriptionId) {
        this.busy = true;
        try {
            await sendNow({ subscriptionId });
            this.toast('Test delivery queued. Check Last Status shortly.', 'success');
        } catch (error) {
            this.toast(this.errMsg(error, 'Send failed.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleRecipientTypeChange(event) {
        this.newRecipient = { ...EMPTY_RECIPIENT, recipientType: event.detail.value };
    }

    handleRecipientUser(event) {
        this.newRecipient = { ...this.newRecipient, userId: event.detail.recordId };
    }

    handleRecipientGroup(event) {
        this.newRecipient = { ...this.newRecipient, groupId: event.detail.recordId };
    }

    handleRecipientEmail(event) {
        this.newRecipient = { ...this.newRecipient, email: event.detail.value };
    }

    async handleAddRecipient() {
        if (!this.draft.id) {
            this.toast('Save the subscription before adding recipients.', 'warning');
            return;
        }
        const r = this.newRecipient;
        if (r.recipientType === 'User' && !r.userId) {
            this.toast('Pick a user.', 'warning');
            return;
        }
        if (r.recipientType === 'Public Group' && !r.groupId) {
            this.toast('Pick a public group.', 'warning');
            return;
        }
        if (r.recipientType === 'Email' && !r.email) {
            this.toast('Enter an email address.', 'warning');
            return;
        }
        const payload = {
            subscriptionId: this.draft.id,
            recipientType: r.recipientType,
            userId: r.userId,
            groupId: r.groupId,
            groupName: r.groupName,
            email: r.email
        };
        this.busy = true;
        try {
            await upsertRecipient({ payloadJson: JSON.stringify(payload) });
            this.newRecipient = { ...EMPTY_RECIPIENT };
            await this.reloadRecipients();
            await this.loadAll();
        } catch (error) {
            this.toast(this.errMsg(error, 'Could not add recipient.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleRemoveRecipient(event) {
        const recipientId = event.currentTarget.dataset.id;
        this.busy = true;
        try {
            await deleteRecipient({ recipientId });
            await this.reloadRecipients();
            await this.loadAll();
        } catch (error) {
            this.toast(this.errMsg(error, 'Could not remove recipient.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    errMsg(error, fallback) {
        return error?.body?.message || error?.message || fallback;
    }

    toast(message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title: 'Subscriptions', message, variant }));
    }
}