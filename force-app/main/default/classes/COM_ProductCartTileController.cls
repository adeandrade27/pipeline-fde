/**
 * Stub controller for product cart tile actions.
 * Extend addToCart when integrating with cart or CPQ APIs.
 */
public with sharing class COM_ProductCartTileController {
    /**
     * Placeholder invoked when a user adds a product from a tile.
     * @param productId Salesforce Product2 Id or external identifier from the tile payload.
     */
    @AuraEnabled
    public static void addToCart(String productId) {
        // Intentionally empty — wire to cart / Commerce / CPQ as needed.
    }
}