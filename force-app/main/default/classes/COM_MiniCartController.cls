/**
 * Supplies WebCart line data for the comMiniCart LWC from CartItem records.
 */
public with sharing class COM_MiniCartController {
    /**
     * Serializable tree node for a cart line and optional nested bundle children.
     */
    public class MiniCartLineDTO {
        @AuraEnabled
        public List<MiniCartLineDTO> children;
        @AuraEnabled
        public String displayName;
        @AuraEnabled
        public String id;
        @AuraEnabled
        public Decimal totalPrice;
    }

    /**
     * Root lines, top-level line count, and sum of every CartItem.TotalPrice on the cart.
     */
    public class MiniCartPayload {
        @AuraEnabled
        public Decimal grandTotal;
        @AuraEnabled
        public List<MiniCartLineDTO> lines;
        @AuraEnabled
        public Integer rootItemCount;
    }

    /**
     * Loads cart lines for a WebCart Id and builds a parent/child tree by ParentCartItemId.
     *
     * @param cartId WebCart Id (CartItem.CartId)
     * @return Payload with lines, rootItemCount, and grandTotal (sum of all TotalPrice values)
     */
    @AuraEnabled(cacheable=true)
    public static MiniCartPayload getMiniCartPayload(String cartId) {
        MiniCartPayload payload = new MiniCartPayload();
        payload.lines = new List<MiniCartLineDTO>();
        payload.grandTotal = 0;
        payload.rootItemCount = 0;

        if (String.isBlank(cartId)) {
            return payload;
        }

        List<CartItem> rows = [
            SELECT Id, Name, ParentCartItemId, Product2Id, Product2.Name, TotalPrice
            FROM CartItem
            WHERE CartId = :cartId
            ORDER BY ParentCartItemId NULLS FIRST, CreatedDate
        ];

        Map<Id, List<CartItem>> childrenByParent = new Map<Id, List<CartItem>>();
        List<CartItem> roots = new List<CartItem>();

        for (CartItem row : rows) {
            if (row.TotalPrice != null) {
                payload.grandTotal += row.TotalPrice;
            }
            if (row.ParentCartItemId == null) {
                roots.add(row);
            } else {
                if (!childrenByParent.containsKey(row.ParentCartItemId)) {
                    childrenByParent.put(row.ParentCartItemId, new List<CartItem>());
                }
                childrenByParent.get(row.ParentCartItemId).add(row);
            }
        }

        for (CartItem root : roots) {
            payload.lines.add(toLineDto(root, childrenByParent));
        }
        payload.rootItemCount = roots.size();
        return payload;
    }

    private static String resolveDisplayName(CartItem row) {
        if (row.Product2Id != null && row.Product2 != null && String.isNotBlank(row.Product2.Name)) {
            return row.Product2.Name;
        }
        if (String.isNotBlank(row.Name)) {
            return row.Name;
        }
        return String.valueOf(row.Id);
    }

    private static MiniCartLineDTO toLineDto(CartItem row, Map<Id, List<CartItem>> childrenByParent) {
        MiniCartLineDTO dto = new MiniCartLineDTO();
        dto.children = new List<MiniCartLineDTO>();
        dto.displayName = resolveDisplayName(row);
        dto.id = row.Id;
        dto.totalPrice = row.TotalPrice;
        if (childrenByParent.containsKey(row.Id)) {
            for (CartItem child : childrenByParent.get(row.Id)) {
                dto.children.add(toLineDto(child, childrenByParent));
            }
        }
        return dto;
    }
}