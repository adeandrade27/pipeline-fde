import addToCart from '@salesforce/apex/COM_ProductCartTileController.addToCart';
import { LightningElement, api, track } from 'lwc';

/**
 * Compact product tiles: logo and monthly price only. Entire tile invokes the same
 * add-to-cart action as comProductCatalogTiles; selected state shows a blue border and checkmark badge.
 */
export default class ComProductCatalogTileSmall extends LightningElement {
    _productsRaw;
    _parsedProducts = [];

    @track addedById = {};

    @api
    get productsList() {
        return this._productsRaw;
    }
    set productsList(value) {
        this._productsRaw = value;
        this._parsedProducts = this.parseProductsInput(value);
    }

    parseProductsInput(value) {
        if (value === undefined || value === null) {
            return [];
        }
        if (typeof value === 'string') {
            try {
                const parsed = JSON.parse(value);
                return Array.isArray(parsed) ? parsed : [];
            } catch {
                return [];
            }
        }
        if (Array.isArray(value)) {
            return value;
        }
        return [];
    }

    get tileRows() {
        const list = this._parsedProducts || [];
        return list.map((product, index) => {
            const id = product.id || `row-${index}`;
            const priceAmount = this.extractPrice(product);
            const isAdded = !!this.addedById[id];
            const name = product.name ?? '';
            const ariaLabel = isAdded
                ? `${name || 'Product'} added to cart`
                : name
                  ? `Add ${name} to cart`
                  : 'Add to cart';
            return {
                ariaLabel,
                displayUrl: product.displayUrl ?? '',
                id,
                isAdded,
                key: id,
                name,
                priceAmountFormatted: this.formatUsd(priceAmount),
                tileClass: isAdded ? 'pct-sm-tile pct-sm-tile--added' : 'pct-sm-tile',
            };
        });
    }

    extractPrice(product) {
        if (typeof product?.price === 'number') {
            return product.price;
        }
        const prices = product?.prices;
        if (!Array.isArray(prices) || prices.length === 0) {
            return null;
        }
        const entry = prices.find((p) => p.isDefault === true) ?? prices[0];
        return typeof entry?.price === 'number' ? entry.price : null;
    }

    formatUsd(amount) {
        if (amount === null || amount === undefined || Number.isNaN(amount)) {
            return '—';
        }
        return new Intl.NumberFormat('en-US', {
            currency: 'USD',
            maximumFractionDigits: 2,
            minimumFractionDigits: 2,
            style: 'currency',
        }).format(amount);
    }

    handleAddToCart(event) {
        const productId = event.currentTarget.dataset.productId;
        addToCart({ productId })
            .then(() => {
                this.addedById = { ...this.addedById, [productId]: true };
            })
            .catch(() => {
                // Stub controller does not throw; keep hook for real integrations.
            });
    }
}