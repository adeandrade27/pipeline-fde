import { LightningElement, api, wire } from 'lwc';
import getBannerState from '@salesforce/apex/ComParentAssetBannerController.getBannerState';

export default class ComParentAssetBanner extends LightningElement {
    @api recordId;

    bannerState;
    hasError = false;
    errorMessage = 'Unable to determine parent account asset status.';

    @wire(getBannerState, { accountId: '$recordId' })
    wiredBannerState({ data, error }) {
        if (data) {
            this.bannerState = data;
            this.hasError = false;
        } else if (error) {
            this.bannerState = null;
            this.hasError = true;
        }
    }

    get showBanner() {
        return this.bannerState && this.bannerState.hasParent && !this.hasError;
    }

    get isNoParentMessage() {
        return this.bannerState && !this.bannerState.hasParent;
    }

    get parentAccountUrl() {
        return this.bannerState?.parentAccountId
            ? `/lightning/r/Account/${this.bannerState.parentAccountId}/view`
            : null;
    }

    get parentMessagePrefix() {
        if (!this.bannerState?.hasParent) {
            return '';
        }

        return this.bannerState.hasRelatedParentAssets
            ? 'Parent account '
            : 'There are no related assets on the parent account ';
    }

    get parentMessageSuffix() {
        if (!this.bannerState?.hasParent) {
            return '';
        }

        return this.bannerState.hasRelatedParentAssets
            ? ' owns additional assets for this Service Account'
            : '';
    }
}