import getMiniCartPayload from '@salesforce/apex/COM_MiniCartController.getMiniCartPayload';
import { LightningElement, api, track, wire } from 'lwc';

/**
 * Mini-cart summary for a WebCart: root CartItem lines, optional bundle children, totals from CartItem.TotalPrice.
 */
export default class ComMiniCart extends LightningElement {
    /** WebCart Id (CartItem.CartId) */
    @api cartId;

    /** Shown after currency amounts (for example "/month"). */
    @api priceSuffix = '/month';
    /** If true, renders the component at full available width. */
    @api fullsized = false;

    @track expandedById = {};

    _wiredPayload;
    wiredError;

    @wire(getMiniCartPayload, { cartId: '$cartId' })
    wiredMiniCart(result) {
        this._wiredPayload = result;
        if (result.data) {
            this.wiredError = undefined;
            this.expandedById = {};
        } else if (result.error) {
            this.wiredError = result.error;
        }
    }

    /**
     * @param {string} lineId
     * @returns {boolean}
     */
    isExpanded(lineId) {
        if (!lineId) {
            return true;
        }
        return this.expandedById[lineId] !== false;
    }

    handleToggleExpand(event) {
        event.preventDefault();
        event.stopPropagation();
        const lineId = event.currentTarget.dataset.lineId;
        if (!lineId) {
            return;
        }
        const next = !this.isExpanded(lineId);
        this.expandedById = { ...this.expandedById, [lineId]: next };
    }

    get displayLines() {
        const lines = this._wiredPayload?.data?.lines;
        if (!Array.isArray(lines)) {
            return [];
        }
        return lines.map((line) => this.decorateLine(line));
    }

    /**
     * @param {object} line
     * @returns {object}
     */
    decorateLine(line) {
        const hasChildren = Array.isArray(line.children) && line.children.length > 0;
        const expanded = this.isExpanded(line.id);
        return {
            chevronGlyph: expanded ? '▾' : '▸',
            children: hasChildren
                ? line.children.map((child) => ({
                      displayName: child.displayName,
                      key: child.id,
                  }))
                : [],
            displayName: line.displayName,
            expandButtonLabel: `Show or hide bundled items for ${line.displayName}`,
            expanded,
            hasChildren,
            key: line.id,
            lineId: line.id,
            priceFormatted: this.formatUsd(line.totalPrice),
            showChildren: hasChildren && expanded,
        };
    }

    get grandTotalFormatted() {
        const total = this._wiredPayload?.data?.grandTotal;
        return this.formatUsd(total);
    }

    get hasCartId() {
        return typeof this.cartId === 'string' && this.cartId.trim().length > 0;
    }

    get hasError() {
        return !!this.wiredError;
    }

    get isLoading() {
        return this.hasCartId && this._wiredPayload && !this._wiredPayload.data && !this._wiredPayload.error;
    }

    get itemBadgeLabel() {
        const count = this._wiredPayload?.data?.rootItemCount ?? 0;
        const label = count === 1 ? 'Item' : 'Items';
        return `${count} ${label}`;
    }

    get isFullSized() {
        return this.fullsized === true || this.fullsized === 'true';
    }

    get rootClass() {
        return this.isFullSized ? 'cmc-root cmc-root--fullsized slds-card' : 'cmc-root slds-card';
    }

    get lineCount() {
        return this._wiredPayload?.data?.lines?.length ?? 0;
    }

    get showLineList() {
        return this.hasCartId && !this.hasError && !this.isLoading && this.lineCount > 0;
    }

    get showEmpty() {
        return this.hasCartId && !this.hasError && !this.isLoading && this.lineCount === 0;
    }

    get showFooter() {
        return this.showLineList;
    }

    /**
     * @param {number|null|undefined} amount
     * @returns {string}
     */
    formatUsd(amount) {
        if (amount === null || amount === undefined || Number.isNaN(Number(amount))) {
            return '—';
        }
        return new Intl.NumberFormat('en-US', {
            currency: 'USD',
            maximumFractionDigits: 2,
            minimumFractionDigits: 2,
            style: 'currency',
        }).format(Number(amount));
    }
}