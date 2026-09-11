import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import listFolders from '@salesforce/apex/CR_FolderService.listFolders';
import getFolderContents from '@salesforce/apex/CR_FolderService.getFolderContents';
import listMembers from '@salesforce/apex/CR_FolderService.listMembers';
import addMember from '@salesforce/apex/CR_FolderService.addMember';
import updateMemberAccess from '@salesforce/apex/CR_FolderService.updateMemberAccess';
import removeMember from '@salesforce/apex/CR_FolderService.removeMember';
import canManageFolders from '@salesforce/apex/CR_FolderService.canManageFolders';
import searchPrincipals from '@salesforce/apex/CR_FolderService.searchPrincipals';

const MEMBER_TYPE_OPTIONS = [
    { label: 'User', value: 'User' },
    { label: 'Public Group', value: 'Public Group' }
];

const ACCESS_OPTIONS = [
    { label: 'Read', value: 'Read' },
    { label: 'Edit', value: 'Edit' }
];

const EMPTY_MEMBER = { memberType: 'User', userId: null, groupId: null, accessLevel: 'Read' };

export default class CrFolderManager extends LightningElement {
    @track folders = [];
    @track selectedFolderId;
    @track contents = { reports: [], dashboards: [] };
    @track members = [];
    @track newMember = { ...EMPTY_MEMBER };
    @track canManage = false;
    @track busy = false;
    @track loadError;

    @track principalResults = [];
    @track principalOpen = false;
    principalTerm = '';

    memberTypeOptions = MEMBER_TYPE_OPTIONS;
    accessOptions = ACCESS_OPTIONS;

    connectedCallback() {
        this.init();
    }

    openHelpPanel() {
        const panel = this.template.querySelector('c-cr-help-panel');
        if (panel && typeof panel.toggle === 'function') {
            panel.toggle();
        }
    }

    async init() {
        this.busy = true;
        this.loadError = null;
        try {
            this.canManage = await canManageFolders();
            await this.loadFolders();
        } catch (error) {
            this.loadError = this.errMsg(error, 'Failed to load folders.');
        } finally {
            this.busy = false;
        }
    }

    async loadFolders() {
        const data = await listFolders();
        this.folders = (data || []).map((f) => ({
            ...f,
            countLabel: this.countLabel(f),
            cssClass: f.id === this.selectedFolderId ? 'folder-item folder-item_selected' : 'folder-item'
        }));
    }

    countLabel(f) {
        const parts = [`${f.reportCount} report${f.reportCount === 1 ? '' : 's'}`,
            `${f.dashboardCount} dashboard${f.dashboardCount === 1 ? '' : 's'}`];
        if (this.canManage && f.memberCount != null) {
            parts.push(`${f.memberCount} member${f.memberCount === 1 ? '' : 's'}`);
        }
        return parts.join(' · ');
    }

    get hasFolders() {
        return this.folders.length > 0;
    }

    get selectedFolder() {
        return this.folders.find((f) => f.id === this.selectedFolderId);
    }

    get selectedFolderName() {
        const f = this.selectedFolder;
        return f ? f.name : '';
    }

    get hasReports() {
        return this.contents.reports && this.contents.reports.length > 0;
    }

    get hasDashboards() {
        return this.contents.dashboards && this.contents.dashboards.length > 0;
    }

    get showMembers() {
        return this.canManage && this.selectedFolderId;
    }

    get isUserMember() {
        return this.newMember.memberType === 'User';
    }

    get isGroupMember() {
        return this.newMember.memberType === 'Public Group';
    }

    get principalLabel() {
        return this.isGroupMember ? 'Public Group' : 'User';
    }

    get principalPlaceholder() {
        return this.isGroupMember ? 'Search public groups…' : 'Search users…';
    }

    get hasPrincipalResults() {
        return this.principalResults.length > 0;
    }

    get principalComboClass() {
        return 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click' +
            (this.principalOpen ? ' slds-is-open' : '');
    }

    get decoratedMembers() {
        return this.members.map((m) => ({
            ...m,
            display: m.memberType === 'Public Group' ? (m.groupName || m.groupId) : (m.userName || m.userId)
        }));
    }

    async handleSelectFolder(event) {
        const folderId = event.currentTarget.dataset.id;
        if (!folderId || folderId === this.selectedFolderId) {
            return;
        }
        this.selectedFolderId = folderId;
        this.newMember = { ...EMPTY_MEMBER };
        this.resetPrincipal();
        this.folders = this.folders.map((f) => ({
            ...f,
            cssClass: f.id === this.selectedFolderId ? 'folder-item folder-item_selected' : 'folder-item'
        }));
        await this.loadContents();
    }

    async loadContents() {
        this.busy = true;
        try {
            this.contents = await getFolderContents({ folderId: this.selectedFolderId });
            if (this.canManage) {
                this.members = await listMembers({ folderId: this.selectedFolderId });
            }
        } catch (error) {
            this.toast(this.errMsg(error, 'Failed to load folder contents.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleMemberTypeChange(event) {
        this.newMember = { ...EMPTY_MEMBER, memberType: event.detail.value };
        this.resetPrincipal();
    }

    resetPrincipal() {
        this.principalTerm = '';
        this.principalResults = [];
        this.principalOpen = false;
    }

    async runPrincipalSearch(term) {
        try {
            const results = await searchPrincipals({ memberType: this.newMember.memberType, term });
            this.principalResults = results || [];
            this.principalOpen = true;
        } catch (error) {
            this.principalResults = [];
            this.toast(this.errMsg(error, 'Could not search.'), 'error');
        }
    }

    // Show an initial list on focus so the admin can pick without typing.
    handlePrincipalFocus() {
        this.runPrincipalSearch(this.principalTerm);
    }

    handlePrincipalInput(event) {
        this.principalTerm = event.target.value;
        // A new search term invalidates any prior selection.
        this.newMember = { ...this.newMember, userId: null, groupId: null };
        this.runPrincipalSearch(this.principalTerm);
    }

    // Selection runs on mousedown (before the input's blur) so the click lands
    // before the dropdown closes — no setTimeout needed.
    handlePrincipalSelect(event) {
        const { id, name } = event.currentTarget.dataset;
        if (this.isGroupMember) {
            this.newMember = { ...this.newMember, groupId: id, userId: null };
        } else {
            this.newMember = { ...this.newMember, userId: id, groupId: null };
        }
        this.principalTerm = name;
        this.principalOpen = false;
    }

    handlePrincipalBlur() {
        this.principalOpen = false;
    }

    handleAccessChange(event) {
        this.newMember = { ...this.newMember, accessLevel: event.detail.value };
    }

    async handleAddMember() {
        const m = this.newMember;
        if (m.memberType === 'User' && !m.userId) {
            this.toast('Pick a user.', 'warning');
            return;
        }
        if (m.memberType === 'Public Group' && !m.groupId) {
            this.toast('Pick a public group.', 'warning');
            return;
        }
        this.busy = true;
        try {
            await addMember({
                payloadJson: JSON.stringify({
                    folderId: this.selectedFolderId,
                    memberType: m.memberType,
                    userId: m.userId,
                    groupId: m.groupId,
                    accessLevel: m.accessLevel
                })
            });
            this.newMember = { ...EMPTY_MEMBER };
            this.resetPrincipal();
            await this.loadContents();
            await this.loadFolders();
            this.toast('Member added.', 'success');
        } catch (error) {
            this.toast(this.errMsg(error, 'Could not add member.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleAccessToggle(event) {
        const membershipId = event.currentTarget.dataset.id;
        const accessLevel = event.detail.value;
        this.busy = true;
        try {
            await updateMemberAccess({ membershipId, accessLevel });
            await this.loadContents();
        } catch (error) {
            this.toast(this.errMsg(error, 'Could not update access.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleRemoveMember(event) {
        const membershipId = event.currentTarget.dataset.id;
        const proceed = await LightningConfirm.open({
            label: 'Remove member',
            theme: 'warning',
            message: 'Remove this member from the folder? They will lose folder-based access to its reports and dashboards.'
        });
        if (!proceed) {
            return;
        }
        this.busy = true;
        try {
            await removeMember({ membershipId });
            await this.loadContents();
            await this.loadFolders();
            this.toast('Member removed.', 'success');
        } catch (error) {
            this.toast(this.errMsg(error, 'Could not remove member.'), 'error');
        } finally {
            this.busy = false;
        }
    }

    errMsg(error, fallback) {
        return error?.body?.message || error?.message || fallback;
    }

    toast(message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title: 'Report Folders', message, variant }));
    }
}