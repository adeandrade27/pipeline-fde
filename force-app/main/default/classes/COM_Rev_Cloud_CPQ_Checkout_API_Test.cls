/**
 * @description Unit tests for consumer checkout (Create Order) callout path.
 */
@IsTest
private class COM_Rev_Cloud_CPQ_Checkout_API_Test {
    private class CheckoutMockOk implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            Assert.isTrue(req.getEndpoint().contains('connect/consumer/checkout'), 'Expected checkout endpoint');
            Assert.areEqual('POST', req.getMethod());
            Assert.isTrue(req.getBody().contains('"inputs"'), 'Expected inputs envelope');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('[{"errors":[],"orderId":"801000000000001AAA"}]');
            return res;
        }
    }

    private class CheckoutMockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"message":"Bad request"}');
            return res;
        }
    }

    @IsTest
    static void testInvocableCreateOrder_Success() {
        Test.setMock(HttpCalloutMock.class, new CheckoutMockOk());
        COM_Rev_Cloud_CPQ_API.CheckoutRequest req = new COM_Rev_Cloud_CPQ_API.CheckoutRequest();
        req.cartId = '0a600000000001AAA';

        List<COM_Rev_Cloud_CPQ_API.CheckoutResponse> out = COM_Rev_Cloud_CPQ_Checkout_API.createOrder(
            new List<COM_Rev_Cloud_CPQ_API.CheckoutRequest>{ req }
        );

        Assert.areEqual(1, out.size());
        Assert.areEqual(200, out[0].statusCode);
        Assert.areEqual('801000000000001AAA', out[0].orderId);
        Assert.isNull(out[0].errorMessage);
    }

    @IsTest
    static void testInvocableCreateOrder_ApiError() {
        Test.setMock(HttpCalloutMock.class, new CheckoutMockError());
        COM_Rev_Cloud_CPQ_API.CheckoutRequest req = new COM_Rev_Cloud_CPQ_API.CheckoutRequest();
        req.contextId = 'ctx-value-1';

        List<COM_Rev_Cloud_CPQ_API.CheckoutResponse> out = COM_Rev_Cloud_CPQ_Checkout_API.createOrder(
            new List<COM_Rev_Cloud_CPQ_API.CheckoutRequest>{ req }
        );

        Assert.areEqual(400, out[0].statusCode);
        Assert.isTrue(String.isNotBlank(out[0].errorMessage));
    }

    @IsTest
    static void testInvocableCreateOrder_NoRequest() {
        List<COM_Rev_Cloud_CPQ_API.CheckoutResponse> out = COM_Rev_Cloud_CPQ_Checkout_API.createOrder(
            new List<COM_Rev_Cloud_CPQ_API.CheckoutRequest>()
        );
        Assert.areEqual(1, out.size());
        Assert.isTrue(String.isNotBlank(out[0].errorMessage));
    }

    @IsTest
    static void testInvocableCreateOrder_ValidationMissingIds() {
        COM_Rev_Cloud_CPQ_API.CheckoutRequest req = new COM_Rev_Cloud_CPQ_API.CheckoutRequest();
        List<COM_Rev_Cloud_CPQ_API.CheckoutResponse> out = COM_Rev_Cloud_CPQ_Checkout_API.createOrder(
            new List<COM_Rev_Cloud_CPQ_API.CheckoutRequest>{ req }
        );
        Assert.isTrue(String.isNotBlank(out[0].errorMessage));
    }

    @IsTest
    static void testCallableCheckoutWrapper() {
        Test.setMock(HttpCalloutMock.class, new CheckoutMockOk());
        Map<String, Object> input = new Map<String, Object>{
            'cartID' => '0a600000000001AAA',
            'contextID' => 'ignored-when-cart'
        };
        Map<String, Object> args = new Map<String, Object>{ 'input' => input };

        Object raw = new COM_Rev_Cloud_CPQ_Checkout_API().call('ignored', args);
        Assert.isTrue(raw instanceof Map<String, Object>);
        Map<String, Object> result = (Map<String, Object>) raw;
        Assert.areEqual(200, result.get('statusCode'));
        Assert.areEqual('801000000000001AAA', String.valueOf(result.get('orderId')));
    }

    @IsTest
    static void testCallableCheckoutOnMainApi() {
        Test.setMock(HttpCalloutMock.class, new CheckoutMockOk());
        Map<String, Object> args = new Map<String, Object>{
            'input' => new Map<String, Object>{ 'contextId' => 'ctx-only' }
        };
        Object raw = new COM_Rev_Cloud_CPQ_API().call('checkout', args);
        Map<String, Object> result = (Map<String, Object>) raw;
        Assert.areEqual(200, result.get('statusCode'));
    }
}