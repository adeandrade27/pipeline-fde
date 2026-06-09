/**
 * @description Flow (@InvocableMethod) and OmniStudio Remote Action wrapper for Revenue Cloud
 *              Create Order (POST connect/consumer/checkout). Salesforce allows at most one
 *              @InvocableMethod per class; callout logic lives on COM_Rev_Cloud_CPQ_API.
 *              Implements Callable so Integration Procedures can use this class as remoteClass.
 * @author      COM Integration
 */
global with sharing class COM_Rev_Cloud_CPQ_Checkout_API implements Callable {

    /**
     * @description OmniStudio Integration Procedure Remote Action — routes to checkout (Create Order) on COM_Rev_Cloud_CPQ_API.
     *              The action name from the IP is ignored; routing is fixed to createOrderFromCheckout.
     */
    global Object call(String action, Map<String, Object> args) {
        return new COM_Rev_Cloud_CPQ_API().call('createOrderFromCheckout', args);
    }

    @InvocableMethod(
        label='Create Revenue Cloud Order (Consumer Checkout)'
        description='POST connect/consumer/checkout — creates an order from a WebCart using cartId and/or contextId (CME Developer Guide)'
        category='Revenue Cloud'
    )
    global static List<COM_Rev_Cloud_CPQ_API.CheckoutResponse> createOrder(
        List<COM_Rev_Cloud_CPQ_API.CheckoutRequest> requests
    ) {
        return COM_Rev_Cloud_CPQ_API.createOrderFromCheckout(requests);
    }
}