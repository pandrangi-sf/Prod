import { LightningElement, api, wire } from 'lwc';
import getProviderByNPI from '@salesforce/apex/NPIRegistryController.getProviderByNPI';

export default class NpiRegistryLookup extends LightningElement {
    @api recordId;

    providerData;
    error;
    isLoading = true;

    @wire(getProviderByNPI, { recordId: '$recordId' })
    wiredProvider({ error, data }) {
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
        const query = ';' + [line, addr.city, addr.state, zip, 'United States'].filter(Boolean).join(', ');
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

    get nppesUrl() {
        return `https://npiregistry.cms.hhs.gov/api/?number=${this.providerData?.npiNumber}&version=2.1`;
    }

    // ─── Actions ───────────────────────────────────────────────────────

    handleRefresh() {
        this.isLoading = true;
        this.error = undefined;
        // Re-invoke the wire by importing refreshApex — but since wire is
        // cacheable, we use an imperative call for refresh.
        getProviderByNPI({ recordId: this.recordId })
            .then(data => {
                this.isLoading = false;
                if (data.success) {
                    this.providerData = data;
                    this.error = undefined;
                } else {
                    this.error = data.errorMessage;
                    this.providerData = undefined;
                }
            })
            .catch(() => {
                this.isLoading = false;
                this.error = 'Unable to load NPI data. Please try again.';
            });
    }
}