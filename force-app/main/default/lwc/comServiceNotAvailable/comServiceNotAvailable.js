import { LightningElement, api } from 'lwc';

export default class ComServiceNotAvailable extends LightningElement {
    @api titleText = "Service isn't available for this area... yet";
    @api subtitleText = 'Enter your email address to get updated when services are available.';
    @api emailLabelText = 'Email';
    @api emailPlaceholderText = 'your email adress';
    @api checkboxLabelText = 'I agree to be contacted at the above email address regarding new products and services.';
    @api emailNodeName = 'Contact_Email_Address';
    @api consentNodeName = 'contact_consent';
    @api initialEmail = '';
    @api initialConsent = false;

    emailValue = '';
    isConsentChecked = false;

    connectedCallback() {
        this.emailValue = this.initialEmail?.trim() ?? '';
        this.isConsentChecked = this.initialConsent === true || this.initialConsent === 'true';
    }

    handleEmailChange(event) {
        this.emailValue = event.target.value?.trim() ?? '';
        this.emitDataUpdates();
    }

    handleConsentChange(event) {
        this.isConsentChecked = event.target.checked;
        this.emitDataUpdates();
    }

    emitDataUpdates() {
        const jsonData = {
            [this.emailNodeName]: this.emailValue,
            [this.consentNodeName]: this.isConsentChecked
        };

        this.dispatchEvent(
            new CustomEvent('omniupdatejson', {
                bubbles: true,
                composed: true,
                detail: jsonData
            })
        );

        this.dispatchOmniAggregate(this.emailNodeName, this.emailValue);
        this.dispatchOmniAggregate(this.consentNodeName, this.isConsentChecked);
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

    @api
    reportValidity() {
        const inputs = this.template.querySelectorAll('lightning-input');
        return [...inputs].every((input) => input.reportValidity());
    }
}