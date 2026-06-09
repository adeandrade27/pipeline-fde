/**
 * @description Flow (@InvocableMethod) and OmniStudio Remote Action wrapper for Revenue Cloud CPQ product details.
 *              Salesforce permits at most one @InvocableMethod per class; callout logic lives on COM_Rev_Cloud_CPQ_API.
 *              Implements Callable so Integration Procedures can use this class as remoteClass.
 * @author      COM Integration
 */
global with sharing class COM_Rev_Cloud_CPQ_ProductDetails_API implements Callable {

    /**
     * @description OmniStudio Integration Procedure Remote Action — delegates to COM_Rev_Cloud_CPQ_API product-details flow.
     *              The action parameter is forced to product-details routing so callers need not pass a specific method name.
     */
    global Object call(String action, Map<String, Object> args) {
        return new COM_Rev_Cloud_CPQ_API().call('getProductDetails', args);
    }

    @InvocableMethod(
        label='Get Revenue Cloud CPQ Product Details'
        description='Calls the Revenue Cloud connect/consumer/products/{productId} API (POST) to retrieve a single product'
        category='Revenue Cloud'
    )
    global static List<COM_Rev_Cloud_CPQ_API.ProductDetailsResponse> getProductDetails(
        List<COM_Rev_Cloud_CPQ_API.ProductDetailsRequest> requests
    ) {
        return COM_Rev_Cloud_CPQ_API.getProductDetails(requests);
    }
}