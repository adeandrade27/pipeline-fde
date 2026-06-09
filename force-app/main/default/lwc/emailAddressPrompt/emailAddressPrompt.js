import { LightningElement, api } from 'lwc';

export default class EmailAddressPrompt extends LightningElement {
    // Configurable UI text and target OmniScript JSON nodes.
    @api labelText = 'Email Address';
    @api placeholderText = 'name@example.com';
    @api helpText = 'Enter a valid email address.';
    @api jsonNodeName = 'emailAddress';
    @api initialEmail = '';
    @api addressLabelText = 'Address';
    @api addressPlaceholderText = 'Enter address';
    @api addressNodeName = 'address';
    @api initialAddress = '';

    // Internal state for required behavior and tracked input values.
    isInputRequired = false;
    emailValue = '';
    addressValue = '';

    // Seed fields when OmniScript passes initial values.
    connectedCallback() {
        this.emailValue = this.initialEmail?.trim() ?? '';
        this.addressValue = this.initialAddress?.trim() ?? '';
    }

    @api
    get inputRequired() {
        return this.isInputRequired;
    }

    set inputRequired(value) {
        this.isInputRequired = value === true || value === 'true';
    }

    // Handle email changes and broadcast updates for OmniScript consumers.
    handleEmailChange(event) {
        this.emailValue = event.target.value?.trim() ?? '';
        this.emitDataUpdates();
    }

    // Handle address changes and broadcast updates for OmniScript consumers.
    handleAddressChange(event) {
        this.addressValue = event.target.value?.trim() ?? '';
        this.emitDataUpdates();
    }

    emitDataUpdates() {
        const jsonData = {
            [this.jsonNodeName]: this.emailValue,
            [this.addressNodeName]: this.addressValue
        };

        // Primary event for runtimes that merge directly into OmniScript JSON.
        this.dispatchEvent(
            new CustomEvent('omniupdatejson', {
                bubbles: true,
                composed: true,
                detail: jsonData
            })
        );

        // Fallback events for runtimes that listen to omniaggregate semantics.
        this.dispatchOmniAggregate(this.jsonNodeName, this.emailValue);
        this.dispatchOmniAggregate(this.addressNodeName, this.addressValue);

        // Generic custom event for parent wrappers or additional listeners.
        this.dispatchEvent(
            new CustomEvent('emailchange', {
                bubbles: true,
                composed: true,
                detail: {
                    email: this.emailValue,
                    address: this.addressValue,
                    data: jsonData
                }
            })
        );
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

    // Expose validity checking so host flows can trigger field validation.
    @api
    reportValidity() {
        const inputs = this.template.querySelectorAll('lightning-input');
        return [...inputs].every((input) => input.reportValidity());
    }

    // Expose the current email value for host components if needed.
    @api
    get emailAddress() {
        return this.emailValue;
    }

    // Expose the current address value for host components if needed.
    @api
    get address() {
        return this.addressValue;
    }
}