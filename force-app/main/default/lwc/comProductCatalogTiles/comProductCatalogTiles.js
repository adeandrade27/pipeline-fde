import addToCart from '@salesforce/apex/COM_ProductCartTileController.addToCart';
import { LightningElement, api, track } from 'lwc';

/**
 * Renders product plan tiles from a products list (array or JSON string).
 * Price is read from a top-level `price` number or from `prices[0].price` when shaped like Commerce APIs.
 */
export default class ComProductCatalogTiles extends LightningElement {
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
            return {
                description: product.description ?? '',
                displayUrl: product.displayUrl ?? '',
                id,
                key: id,
                name: product.name ?? '',
                priceAmountFormatted: this.formatUsd(priceAmount),
                tileClass: isAdded ? 'pct-tile pct-tile--added' : 'pct-tile',
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
        const entry =
            prices.find((p) => p.isDefault === true) ?? prices[0];
        return typeof entry?.price === 'number' ? entry.price : null;
    }

    formatUsd(amount) {
        if (amount === null || amount === undefined || Number.isNaN(amount)) {
            return '—';
        }
        return new Intl.NumberFormat('en-US', {
            currency: 'USD',
            maximumFractionDigits: 0,
            minimumFractionDigits: 0,
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