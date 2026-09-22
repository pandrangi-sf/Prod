import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getProviderByNPI from '@salesforce/apex/NPIRegistryController.getProviderByNPI';

export default class NpiRegistryLookup extends LightningElement {
    @api recordId;

    providerData;
    error;
    isLoading = true;

    // The whole wire result is kept so Refresh can invalidate it. An imperative
    // call to a cacheable method is served from the Lightning client cache, so
    // the old Refresh re-rendered the cached payload without re-contacting NPPES.
    wiredResult;

    @wire(getProviderByNPI, { recordId: '$recordId' })
    wiredProvider(result) {
        this.wiredResult = result;
        const { error, data } = result;
        this.isLoading = false;
        if (data) {
            if (data.success) {
                this.providerData = data;
                this.error = undefined;
            } else {
                this.error = data.errorMessage;
                this.providerData = undefined;
            }
        } else if (error) {
            this.error = 'Unable to load NPI data. Please try again.';
            this.providerData = undefined;
        }
    }

    // ─── Computed Properties ───────────────────────────────────────────

    get hasData() {
        return this.providerData != null;
    }

    get isIndividual() {
        return this.providerData?.enumerationType === 'NPI-1';
    }

    get isOrganization() {
        return this.providerData?.enumerationType === 'NPI-2';
    }

    get providerDisplayName() {
        if (this.isOrganization) {
            return this.providerData.organizationName || 'Unknown Organization';
        }
        const parts = [
            this.providerData.firstName,
            this.providerData.middleName,
            this.providerData.lastName
        ].filter(Boolean);
        const name = parts.join(' ');
        return this.providerData.credential
            ? `${name}, ${this.providerData.credential}`
            : name;
    }

    get providerTypeLabel() {
        return this.isIndividual ? 'Individual' : 'Organization';
    }

    get statusLabel() {
        return this.providerData?.status === 'A' ? 'Active' : 'Deactivated';
    }

    get statusVariant() {
        return this.providerData?.status === 'A' ? 'success' : 'error';
    }

    get genderLabel() {
        const g = this.providerData?.gender;
        if (g === 'M') return 'Male';
        if (g === 'F') return 'Female';
        return g || '—';
    }

    get hasAddresses() {
        return this.providerData?.addresses?.length > 0;
    }

    get locationAddress() {
        return this.providerData?.addresses?.find(a => a.addressPurpose === 'LOCATION');
    }

    get mailingAddress() {
        return this.providerData?.addresses?.find(a => a.addressPurpose === 'MAILING');
    }

    buildMapUrl(addr) {
        if (!addr) return '';
        const line = [addr.addressLine1, addr.addressLine2].filter(Boolean).join(' ');
        const zip = addr.postalCode ? addr.postalCode.substring(0, 5) : '';
        const query = [line, addr.city, addr.state, zip, 'United States'].filter(Boolean).join(', ');
        return 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(query);
    }

    get locationMapUrl() {
        return this.buildMapUrl(this.locationAddress);
    }

    get mailingMapUrl() {
        return this.buildMapUrl(this.mailingAddress);
    }

    get hasTaxonomies() {
        return this.providerData?.taxonomies?.length > 0;
    }

    get taxonomies() {
        return this.providerData?.taxonomies?.map((t, idx) => ({
            ...t,
            key: `tax-${idx}`,
            primaryLabel: t.isPrimary ? 'Yes' : 'No'
        }));
    }

    get hasIdentifiers() {
        return this.providerData?.identifiers?.length > 0;
    }

    get identifiers() {
        return this.providerData?.identifiers?.map((id, idx) => ({
            ...id,
            key: `id-${idx}`
        }));
    }

    get soleProprietorLabel() {
        const value = this.providerData?.sole_proprietor;
        if (value === 'YES') return 'Yes';
        if (value === 'NO') return 'No';
        return value || '—';
    }

    // A Contact with no NPI is an ordinary state, not a failure, so it is shown
    // as information rather than in red.
    get errorIsInfo() {
        return (this.error || '').indexOf('No NPI number') === 0;
    }

    get errorClass() {
        return this.errorIsInfo
            ? 'slds-scoped-notification slds-media slds-media_center slds-theme_info'
            : 'slds-scoped-notification slds-media slds-media_center slds-theme_error';
    }

    get errorIcon() {
        return this.errorIsInfo ? 'utility:info' : 'utility:error';
    }

    get nppesUrl() {
        return `https://npiregistry.cms.hhs.gov/api/?number=${this.providerData?.npiNumber}&version=2.1`;
    }

    // ─── Actions ───────────────────────────────────────────────────────

    async handleRefresh() {
        this.isLoading = true;
        this.error = undefined;
        try {
            await refreshApex(this.wiredResult);
        } catch (e) {
            this.error = 'Unable to load NPI data. Please try again.';
            this.providerData = undefined;
        } finally {
            this.isLoading = false;
        }
    }
}