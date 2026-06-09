import { LightningElement, api } from 'lwc';

/** Demo addresses for type-ahead (no external API). */
const MOCK_ADDRESSES = [
    '600 Cumberland Street, Ottawa, ON, K1N 6N7, Canada',
    '123 Main Street, New York, NY, 10001, USA',
    '456 Broadway, New York, NY, 10013, USA',
    '789 Elm Street, Albany, NY, 12207, USA',
    '100 Congress Avenue, Austin, TX, 78701, USA',
    '2500 North Stemmons Freeway, Dallas, TX, 75207, USA',
    '1 Ocean Drive, Miami, FL, 33139, USA',
    '200 Bayfront Parkway, Sarasota, FL, 34236, USA',
    '1600 Pennsylvania Avenue NW, Washington, DC, 20500, USA',
    '1 Infinite Loop, Cupertino, CA, 95014, USA'
];

const MIN_QUERY_LENGTH = 1;

/**
 * Returns true when the formatted address is in New York (state).
 * @param {string} address
 * @returns {boolean}
 */
function isNewYorkAddress(address) {
    if (!address || typeof address !== 'string') {
        return false;
    }
    const upper = address.toUpperCase();
    if (upper.includes('NEW YORK')) {
        return true;
    }
    // Common USPS-style state token
    const nyPatterns = [', NY,', ', NY ', ' NY,', ' NY USA', ' NY, USA'];
    return nyPatterns.some((p) => upper.includes(p));
}

function isTexasAddress(address) {
    if (!address || typeof address !== 'string') {
        return false;
    }
    const upper = address.toUpperCase();
    return upper.includes('TEXAS') || upper.includes(', TX,') || upper.includes(' TX ');
}

function isFloridaAddress(address) {
    if (!address || typeof address !== 'string') {
        return false;
    }
    const upper = address.toUpperCase();
    return upper.includes('FLORIDA') || upper.includes(', FL,') || upper.includes(' FL ');
}

export default class AddressAvailabilityLookup extends LightningElement {
    @api labelText = 'Please enter your address';
    @api placeholderText = 'Start typing an address';
    @api addressNodeName = 'address';
    @api serviceAvailabilityNodeName = 'Service_Availablity';

    searchTerm = '';
    suggestions = [];
    selectedAddress = null;
    serviceAvailability = '';
    showSuggestions = false;

    get isCheckDisabled() {
        return !this.selectedAddress;
    }

    get hasResult() {
        return Boolean(this.serviceAvailability);
    }

    get availabilityMessage() {
        return this.hasResult ? `${this.serviceAvailabilityNodeName} = ${this.serviceAvailability}` : '';
    }

    get ariaExpanded() {
        return this.showSuggestions ? 'true' : 'false';
    }

    handleSearchInput(event) {
        this.searchTerm = event.target.value;
        this.selectedAddress = null;
        this.serviceAvailability = '';
        this.emitDataUpdates();

        const q = this.searchTerm.trim();
        if (q.length < MIN_QUERY_LENGTH) {
            this.suggestions = [];
            this.showSuggestions = false;
            return;
        }

        const lower = q.toLowerCase();
        this.suggestions = MOCK_ADDRESSES.filter((addr) => addr.toLowerCase().includes(lower));
        this.showSuggestions = this.suggestions.length > 0;
    }

    handleSearchFocus() {
        if (this.searchTerm.trim().length >= MIN_QUERY_LENGTH && this.suggestions.length > 0) {
            this.showSuggestions = true;
        }
    }

    handleSearchBlur() {
        this.showSuggestions = false;
    }

    /**
     * Prevents input blur before click so selection still fires.
     * @param {MouseEvent} event
     */
    handleSuggestionMouseDown(event) {
        event.preventDefault();
    }

    handleSelectSuggestion(event) {
        const value = event.currentTarget.dataset.address;
        if (!value) {
            return;
        }
        this.selectedAddress = value;
        this.searchTerm = value;
        this.suggestions = [];
        this.showSuggestions = false;
        this.serviceAvailability = '';
        this.emitDataUpdates();
    }

    handleCheckAvailability() {
        if (!this.selectedAddress) {
            return;
        }

        if (isNewYorkAddress(this.selectedAddress)) {
            this.serviceAvailability = 'Unavailable';
        } else if (isTexasAddress(this.selectedAddress)) {
            this.serviceAvailability = 'Partially Available - 500Mbps';
        } else if (isFloridaAddress(this.selectedAddress)) {
            this.serviceAvailability = 'Available - 1Gbps';
        } else {
            this.serviceAvailability = 'Partially Available - 500Mbps';
        }

        this.emitDataUpdates();
    }

    emitDataUpdates() {
        const jsonData = {
            [this.addressNodeName]: this.selectedAddress ?? this.searchTerm?.trim() ?? '',
            [this.serviceAvailabilityNodeName]: this.serviceAvailability
        };

        this.dispatchEvent(
            new CustomEvent('omniupdatejson', {
                bubbles: true,
                composed: true,
                detail: jsonData
            })
        );

        this.dispatchOmniAggregate(this.addressNodeName, jsonData[this.addressNodeName]);
        this.dispatchOmniAggregate(this.serviceAvailabilityNodeName, this.serviceAvailability);
    }

    dispatchOmniAggregate(nodeName, value) {
        this.dispatchEvent(
            new CustomEvent('omniaggregate', {
                bubbles: true,
                composed: true,
                detail: {
                    data: value,
                    elementId: nodeName,
                    nodeName
                }
            })
        );
    }
}