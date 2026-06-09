/**
 * CPQProductsRemoteActionTest
 *
 * Unit tests for the CPQProductsRemoteAction Callable class.
 * Uses HttpCalloutMock to simulate Revenue Cloud REST API responses.
 */
@IsTest
private class CPQProductsRemoteActionTest {

    // =========================================================================
    // Mock Classes
    // =========================================================================

    /**
     * Mock for a successful 200 OK response from /connect/cpq/products
     */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"products":[{"id":"01txx000001","name":"Test Product","prices":[]}],"totalSize":1,"done":true}');
            return res;
        }
    }

    /**
     * Mock for a 400 Bad Request response
     */
    private class BadRequestMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"message":"Invalid catalog ID","errorCode":"INVALID_INPUT"}');
            return res;
        }
    }

    /**
     * Mock for a 401 Unauthorized response
     */
    private class UnauthorizedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"message":"Session expired or invalid","errorCode":"INVALID_SESSION_ID"}');
            return res;
        }
    }

    /**
     * Mock for a 500 Internal Server Error response
     */
    private class ServerErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"error":"Internal server error"}');
            return res;
        }
    }

    /**
     * Mock that validates the request body structure
     */
    private class RequestValidationMock implements HttpCalloutMock {
        public String capturedBody;
        public String capturedEndpoint;
        public String capturedMethod;

        public HttpResponse respond(HttpRequest req) {
            capturedBody = req.getBody();
            capturedEndpoint = req.getEndpoint();
            capturedMethod = req.getMethod();

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"products":[],"totalSize":0,"done":true}');
            return res;
        }
    }

    // =========================================================================
    // Test Methods
    // =========================================================================

    /**
     * Test 1: Successful call with only the required categoryId parameter.
     */
    @IsTest
    static void testSuccessWithCategoryIdOnly() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Status code should be 200');
        System.assertNotEquals('', (String) result.get('responseBody'), 'Response body should not be empty');
        System.assertEquals('', result.get('errorMessage'), 'Error message should be empty on success');

        // Verify response body contains expected structure
        String responseBody = (String) result.get('responseBody');
        System.assert(responseBody.contains('products'), 'Response should contain products key');
    }

    /**
     * Test 2: Successful call with all optional parameters populated.
     */
    @IsTest
    static void testSuccessWithAllParameters() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'catalogId' => '0ZSDU0000020g74AE',
            'categoryId' => '0ZGDU0000002P0H4AU',
            'correlationId' => 'test-correlation-123',
            'currencyCode' => 'USD',
            'cursor' => 'MTAwMDAwMDAwNg==',
            'priceBookId' => '01sDU000000JVsVYAW',
            'pricingProcedure' => 'pricingProcedure',
            'qualificationProcedure' => 'ProductQualification',
            'productClassificationId' => '11BDU0000002TCC2A2',
            'contextDefinition' => 'BrowseContextDefinitionExt',
            'contextMapping' => 'ProductDiscoveryMapping',
            'searchTerm' => 'Laptop',
            'transactionContextId' => 'a1b2c3d4e5f6',
            'transactionId' => 'trans789',
            'limit' => 60,
            'offset' => 0,
            'enablePricing' => true,
            'enableQualification' => true,
            'includeCatalogDetails' => true,
            'executeConfigurationRules' => false,
            'usePromotions' => true,
            'orderBy' => 'name:asc',
            'userContext' => '{"accountId":"001DU000001o2UzYAI"}',
            'filter' => '{"criteria":[{"property":"name","operator":"eq","value":"Laptop Pro Bundle"}]}',
            'relatedObjectFilters' => '[{"objectName":"ProductSpecificationRecType","criteria":[{"property":"IsCommercial","operator":"eq","value":true}]}]',
            'additionalContextData' => '[{"nodeName":"Account","nodeData":{"id":"001DU000001o2UzYAI","name":"Cloud Kicks"}}]',
            'additionalFields' => '{"Product2":{"fields":["CanRamp","DecompositionScope","ProductCode"]}}'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Status code should be 200');
        System.assertEquals('', result.get('errorMessage'), 'Error message should be empty on success');
    }

    /**
     * Test 3: Missing categoryId returns 400 error.
     */
    @IsTest
    static void testMissingCategoryId() {
        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(400, result.get('statusCode'), 'Status code should be 400 for missing categoryId');
        System.assertEquals('categoryId is required', result.get('errorMessage'), 'Error message should indicate categoryId is required');
        System.assertEquals('', result.get('responseBody'), 'Response body should be empty');
    }

    /**
     * Test 4: Null args returns 400 error.
     */
    @IsTest
    static void testNullArgs() {
        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', null);
        Test.stopTest();

        System.assertEquals(400, result.get('statusCode'), 'Status code should be 400 for null args');
        System.assertEquals('categoryId is required', result.get('errorMessage'));
    }

    /**
     * Test 5: Blank categoryId returns 400 error.
     */
    @IsTest
    static void testBlankCategoryId() {
        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '  '
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(400, result.get('statusCode'), 'Status code should be 400 for blank categoryId');
        System.assertEquals('categoryId is required', result.get('errorMessage'));
    }

    /**
     * Test 6: Non-2xx API response returns proper error mapping with message key.
     */
    @IsTest
    static void testBadRequestResponse() {
        Test.setMock(HttpCalloutMock.class, new BadRequestMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => 'INVALID_ID'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(400, result.get('statusCode'), 'Status code should be 400');
        String errorMessage = (String) result.get('errorMessage');
        System.assert(errorMessage.contains('Invalid catalog ID'), 'Error message should contain API error: ' + errorMessage);
    }

    /**
     * Test 7: Unauthorized response returns proper error.
     */
    @IsTest
    static void testUnauthorizedResponse() {
        Test.setMock(HttpCalloutMock.class, new UnauthorizedMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(401, result.get('statusCode'), 'Status code should be 401');
        String errorMessage = (String) result.get('errorMessage');
        System.assert(errorMessage.contains('Session expired'), 'Error message should contain session error: ' + errorMessage);
    }

    /**
     * Test 8: Server error response with 'error' key (instead of 'message').
     */
    @IsTest
    static void testServerErrorResponse() {
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(500, result.get('statusCode'), 'Status code should be 500');
        String errorMessage = (String) result.get('errorMessage');
        System.assert(errorMessage.contains('Internal server error'), 'Error message should contain server error: ' + errorMessage);
    }

    /**
     * Test 9: Callable interface works with default action name.
     */
    @IsTest
    static void testCallableWithDefaultAction() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Callable remoteAction = (Callable) Type.forName('CPQProductsRemoteAction').newInstance();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU'
        };

        Test.startTest();
        Object rawResult = remoteAction.call('anyAction', args);
        Test.stopTest();

        System.assert(rawResult instanceof Map<String, Object>, 'Result should be a Map');
        Map<String, Object> result = (Map<String, Object>) rawResult;
        System.assertEquals(200, result.get('statusCode'));
    }

    /**
     * Test 10: Request body builder correctly serializes all parameter types.
     */
    @IsTest
    static void testBuildRequestBodyStructure() {
        RequestValidationMock mock = new RequestValidationMock();
        Test.setMock(HttpCalloutMock.class, mock);

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU',
            'catalogId' => '0ZSDU0000020g74AE',
            'limit' => 25,
            'enablePricing' => false,
            'orderBy' => '["name:asc","id:desc"]',
            'userContext' => '{"accountId":"001xx0000001AAA"}'
        };

        Test.startTest();
        remoteAction.call('getProducts', args);
        Test.stopTest();

        // Parse the captured request body
        String capturedBody = mock.capturedBody;
        System.assertNotEquals(null, capturedBody, 'Request body should be captured');

        Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(capturedBody);
        System.assertEquals('0ZGDU0000002P0H4AU', bodyMap.get('categoryId'), 'categoryId should be in body');
        System.assertEquals('0ZSDU0000020g74AE', bodyMap.get('catalogId'), 'catalogId should be in body as optional');
        System.assertEquals(25, bodyMap.get('limit'), 'limit should be 25');
        System.assertEquals(false, bodyMap.get('enablePricing'), 'enablePricing should be false');
        System.assert(bodyMap.containsKey('orderBy'), 'orderBy should be in body');
        System.assert(bodyMap.containsKey('userContext'), 'userContext should be deserialized into body');
    }

    /**
     * Test 11: OrderBy as comma-separated string is parsed correctly.
     */
    @IsTest
    static void testOrderByCommaSeparated() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU',
            'orderBy' => 'name:asc, id:desc'
        };

        Test.startTest();
        // This should not throw — the orderBy is parsed from comma-separated to array
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Should succeed with comma-separated orderBy');
    }

    /**
     * Test 12: Complex parameters passed as already-structured objects (not JSON strings).
     */
    @IsTest
    static void testComplexParamsAsStructuredObjects() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();

        Map<String, Object> userCtx = new Map<String, Object>{
            'accountId' => '001xx0000001AAA'
        };

        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU',
            'userContext' => userCtx
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Should succeed with structured object params');
    }

    /**
     * Test 13: Integer params passed as String values are handled correctly.
     */
    @IsTest
    static void testIntegerParamsAsStrings() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU',
            'limit' => '50'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Should succeed with string integer params');
    }

    /**
     * Test 14: Boolean params passed as String values are handled correctly.
     */
    @IsTest
    static void testBooleanParamsAsStrings() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        CPQProductsRemoteAction remoteAction = new CPQProductsRemoteAction();
        Map<String, Object> args = new Map<String, Object>{
            'categoryId' => '0ZGDU0000002P0H4AU',
            'enablePricing' => 'true',
            'enableQualification' => 'false'
        };

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) remoteAction.call('getProducts', args);
        Test.stopTest();

        System.assertEquals(200, result.get('statusCode'), 'Should succeed with string boolean params');
    }
}