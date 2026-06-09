/**
 * @description Test class for COM_Rev_Cloud_CPQ_API.
 *              Validates Callable interface, @InvocableMethod, request body construction,
 *              response parsing, and error handling with HttpCalloutMock.
 * @author      COM Integration
 * @date        2026-04-05
 */
@IsTest
private class COM_Rev_Cloud_CPQ_API_Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Mock: Successful 200 response
    // ─────────────────────────────────────────────────────────────────────────

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            // Validate request structure
            System.assertEquals('POST', req.getMethod(), 'HTTP method should be POST');
            System.assert(req.getEndpoint().contains('/connect/cpq/products'), 'Endpoint should contain /connect/cpq/products');
            System.assert(req.getHeader('Authorization').startsWith('Bearer '), 'Authorization header should start with Bearer');
            System.assertEquals('application/json', req.getHeader('Content-Type'), 'Content-Type should be application/json');

            // Validate request body contains categoryId
            String body = req.getBody();
            System.assert(body.contains('"categoryId"'), 'Request body must contain categoryId');

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'products' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'id' => '01txx0000006j08AAA',
                        'name' => 'Test Product',
                        'productCode' => 'TP-001'
                    }
                },
                'totalSize' => 1,
                'cursor' => 'nextPageToken123'
            }));
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mock: Error 400 response
    // ─────────────────────────────────────────────────────────────────────────

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'message' => 'Invalid categoryId',
                'errorCode' => 'INVALID_INPUT'
            }));
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mock: Malformed response body
    // ─────────────────────────────────────────────────────────────────────────

    private class MalformedResponseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/html');
            res.setBody('<html>Server Error</html>');
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mock: Full request body validator
    // ─────────────────────────────────────────────────────────────────────────

    private class FullParamMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String body = req.getBody();
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

            // Validate all expected fields are present
            System.assertEquals('0ZSxx000000001GAA', (String) parsed.get('catalogId'));
            System.assertEquals('0ZGxx000000001dAA', (String) parsed.get('categoryId'));
            System.assertEquals('01sxx0000001qxxAAA', (String) parsed.get('priceBookId'));
            System.assertEquals('USD', (String) parsed.get('currencyCode'));
            System.assertEquals('corr-123', (String) parsed.get('correlationId'));
            System.assertEquals(20, (Integer) parsed.get('limit'));
            System.assertEquals(false, (Boolean) parsed.get('enablePricing'));
            System.assertEquals(true, (Boolean) parsed.get('enableQualification'));
            System.assertEquals(true, (Boolean) parsed.get('includeCatalogDetails'));
            System.assertEquals('Laptop', (String) parsed.get('searchTerm'));

            // Validate orderBy is a list
            List<Object> orderByList = (List<Object>) parsed.get('orderBy');
            System.assertEquals(2, orderByList.size());
            System.assertEquals('name:asc', (String) orderByList[0]);

            // Validate userContext
            Map<String, Object> userCtx = (Map<String, Object>) parsed.get('userContext');
            System.assertNotEquals(null, userCtx, 'userContext should be present');
            System.assertEquals('001xx0000001AAA', (String) userCtx.get('accountId'));

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"products":[],"totalSize":0}');
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests: Callable interface (Integration Procedure Remote Action)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testCallable_MinimalParams() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGxx000000001dAA',
            'catalogId' => '0ZSxx000000001GAA'
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        Object result = instance.call('getProducts', args);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        Map<String, Object> resultMap = (Map<String, Object>) result;
        System.assertEquals(true, resultMap.get('isSuccess'), 'Should be successful');
        System.assertEquals(200, resultMap.get('statusCode'), 'Status code should be 200');
        System.assertNotEquals(null, resultMap.get('products'), 'Products should be present');
    }

    @IsTest
    static void testCallable_AllParams() {
        Test.setMock(HttpCalloutMock.class, new FullParamMock());

        Map<String, Object> args = new Map<String, Object>{
            'catalogId' => '0ZSxx000000001GAA',
            'categoryId' => '0ZGxx000000001dAA',
            'priceBookId' => '01sxx0000001qxxAAA',
            'currencyCode' => 'USD',
            'correlationId' => 'corr-123',
            'cursor' => 'MTAwMDAwMDAwNw==',
            'searchTerm' => 'Laptop',
            'contextDefinition' => 'BrowseContextDef',
            'contextMapping' => 'ProductDiscoveryMapping',
            'pricingProcedure' => 'CustomPricing',
            'qualificationProcedure' => 'CustomQual',
            'productClassificationId' => '11BDU0000002TCC2A2',
            'enablePricing' => false,
            'enableQualification' => true,
            'includeCatalogDetails' => true,
            'usePromotions' => false,
            'limitSize' => 20,
            'orderBy' => 'name:asc, id:desc',
            'accountId' => '001xx0000001AAA',
            'contactId' => '003xx00000D7AAI',
            'filterJson' => '{"criteria":[{"fieldName":"name","operator":"contains","value":"phone"}]}',
            'additionalFieldsJson' => '{"Product2":{"fields":["CustomField1__c"]}}',
            'additionalContextDataJson' => '[{"nodeName":"Contract","nodeData":{"id":"xxx231"}}]',
            'relatedObjectFilterJson' => '[{"objectName":"ProductSpecificationRecType","criteria":[{"fieldName":"IsCommerical","operator":"eq","value":"true"}]}]'
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        Object result = instance.call('getProducts', args);
        Test.stopTest();

        Map<String, Object> resultMap = (Map<String, Object>) result;
        System.assertEquals(true, resultMap.get('isSuccess'));
    }

    @IsTest
    static void testCallable_MissingCategoryId() {
        Map<String, Object> args = new Map<String, Object>{
            'catalogId' => '0ZSxx000000001GAA'
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        try {
            instance.call('getProducts', args);
            System.assert(false, 'Should have thrown CPQApiException');
        } catch (COM_Rev_Cloud_CPQ_API.CPQApiException e) {
            System.assert(e.getMessage().contains('categoryId is required'), 'Error message should mention categoryId');
        }
        Test.stopTest();
    }

    @IsTest
    static void testCallable_NullArgs() {
        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        try {
            instance.call('getProducts', null);
            System.assert(false, 'Should have thrown CPQApiException');
        } catch (COM_Rev_Cloud_CPQ_API.CPQApiException e) {
            System.assert(e.getMessage().contains('categoryId is required'));
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests: @InvocableMethod (Flow invocation)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInvocable_Success() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';
        req.catalogId = '0ZSxx000000001GAA';

        Test.startTest();
        List<String> results = COM_Rev_Cloud_CPQ_API.getProducts(new List<COM_Rev_Cloud_CPQ_API.ProductsListRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        String jsonResult = results[0];
        System.assert(jsonResult.contains('products'), 'Response should contain products');
    }

    @IsTest
    static void testInvocable_NullInput() {
        Test.startTest();
        List<String> results = COM_Rev_Cloud_CPQ_API.getProducts(null);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].contains('error'), 'Should return error for null input');
    }

    @IsTest
    static void testInvocable_EmptyList() {
        Test.startTest();
        List<String> results = COM_Rev_Cloud_CPQ_API.getProducts(new List<COM_Rev_Cloud_CPQ_API.ProductsListRequest>());
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].contains('error'), 'Should return error for empty list');
    }

    @IsTest
    static void testInvocable_MissingCategoryId() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();

        Test.startTest();
        try {
            COM_Rev_Cloud_CPQ_API.getProducts(new List<COM_Rev_Cloud_CPQ_API.ProductsListRequest>{ req });
            System.assert(false, 'Should have thrown CPQApiException');
        } catch (COM_Rev_Cloud_CPQ_API.CPQApiException e) {
            System.assert(e.getMessage().contains('categoryId is required'));
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests: Error handling
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testErrorResponse() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGxx000000001dAA'
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        Object result = instance.call('getProducts', args);
        Test.stopTest();

        Map<String, Object> resultMap = (Map<String, Object>) result;
        System.assertEquals(false, resultMap.get('isSuccess'), 'Should not be successful');
        System.assertEquals(400, resultMap.get('statusCode'), 'Status code should be 400');
        System.assertNotEquals(null, resultMap.get('errorDetails'), 'Error details should be present');
    }

    @IsTest
    static void testMalformedResponse() {
        Test.setMock(HttpCalloutMock.class, new MalformedResponseMock());

        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGxx000000001dAA'
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        Object result = instance.call('getProducts', args);
        Test.stopTest();

        Map<String, Object> resultMap = (Map<String, Object>) result;
        System.assertEquals(false, resultMap.get('isSuccess'), 'Should not be successful on parse failure');
        System.assertNotEquals(null, resultMap.get('rawBody'), 'Raw body should be preserved');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests: Request body construction
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBuildRequestBody_MinimalParams() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';

        String body = COM_Rev_Cloud_CPQ_API.buildRequestBody(req);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

        System.assertEquals('0ZGxx000000001dAA', parsed.get('categoryId'), 'categoryId must be present');
        // Optional fields should not be present
        System.assertEquals(null, parsed.get('catalogId'), 'catalogId should not be in body when null');
        System.assertEquals(null, parsed.get('userContext'), 'userContext should not be in body when no account/contact');
    }

    @IsTest
    static void testBuildRequestBody_WithUserContext() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';
        req.accountId = '001xx0000001AAA';
        req.contactId = '003xx00000D7AAI';

        String body = COM_Rev_Cloud_CPQ_API.buildRequestBody(req);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

        Map<String, Object> userCtx = (Map<String, Object>) parsed.get('userContext');
        System.assertNotEquals(null, userCtx, 'userContext should be present');
        System.assertEquals('001xx0000001AAA', userCtx.get('accountId'));
        System.assertEquals('003xx00000D7AAI', userCtx.get('contactId'));
    }

    @IsTest
    static void testBuildRequestBody_OrderBySplit() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';
        req.orderBy = 'name:asc, id:desc';

        String body = COM_Rev_Cloud_CPQ_API.buildRequestBody(req);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

        List<Object> orderByList = (List<Object>) parsed.get('orderBy');
        System.assertEquals(2, orderByList.size());
        System.assertEquals('name:asc', orderByList[0]);
        System.assertEquals('id:desc', orderByList[1]);
    }

    @IsTest
    static void testBuildRequestBody_InvalidFilterJson() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';
        req.filterJson = 'not valid json{{{';

        try {
            COM_Rev_Cloud_CPQ_API.buildRequestBody(req);
            System.assert(false, 'Should have thrown CPQApiException for invalid JSON');
        } catch (COM_Rev_Cloud_CPQ_API.CPQApiException e) {
            System.assert(e.getMessage().contains('Invalid JSON for filter'));
        }
    }

    @IsTest
    static void testBuildRequestBody_InvalidAdditionalContextDataJson() {
        COM_Rev_Cloud_CPQ_API.ProductsListRequest req = new COM_Rev_Cloud_CPQ_API.ProductsListRequest();
        req.categoryId = '0ZGxx000000001dAA';
        req.additionalContextDataJson = '{{invalid}}';

        try {
            COM_Rev_Cloud_CPQ_API.buildRequestBody(req);
            System.assert(false, 'Should have thrown CPQApiException for invalid JSON');
        } catch (COM_Rev_Cloud_CPQ_API.CPQApiException e) {
            System.assert(e.getMessage().contains('Invalid JSON for additionalContextData'));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests: Callable with limit key mapping
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testCallable_LimitKeyMapping() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // Pass 'limit' instead of 'limitSize' — class should handle both
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGxx000000001dAA',
            'catalogId' => '0ZSxx000000001GAA',
            'limit' => 25
        };

        COM_Rev_Cloud_CPQ_API instance = new COM_Rev_Cloud_CPQ_API();

        Test.startTest();
        Object result = instance.call('getProducts', args);
        Test.stopTest();

        Map<String, Object> resultMap = (Map<String, Object>) result;
        System.assertEquals(true, resultMap.get('isSuccess'));
    }
}