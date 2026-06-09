/**
 * @description Remote Apex callouts to Revenue Cloud CPQ Connect REST APIs:
 *              - Retrieve product list: POST .../connect/cpq/products
 *              - Retrieve product details: POST .../connect/consumer/products/{productId}
 *              - Create order from cart: POST .../connect/consumer/checkout
 *              (See Communications Developer Guide — Consumer product resource, cart order.)
 *              Implements Callable for OmniStudio Integration Procedure Remote Action.
 *              Exposes @InvocableMethod for Flow invocation.
 *              Authorization via session-based Bearer token (no Named Credentials).
 * @author      COM Integration
 * @date        2026-04-05
 */
global with sharing class COM_Rev_Cloud_CPQ_API implements Callable 
{

    private static final String API_VERSION = 'v66.0';
    private static final String ENDPOINT_PATH               = '/services/data/' + API_VERSION + '/connect/cpq/products';
    private static final String PRODUCT_DETAILS_PATH_PREFIX = '/services/data/' + API_VERSION + '/connect/cpq/products/';
    private static final String CONSUMER_CHECKOUT_PATH      = '/services/data/' + API_VERSION + '/connect/consumer/checkout';
    //private static final String CONSUMER_PRODUCT_DETAILS_PATH_PREFIX = '/services/data/' + API_VERSION + '/connect/consumer/products/';

    // ─────────────────────────────────────────────────────────────────────────
    // Inner class: Invocable request wrapper
    // ─────────────────────────────────────────────────────────────────────────

    global class ProductsListRequest {
        @InvocableVariable(label='Catalog ID' description='ID of the catalog')
        global String catalogId;

        @InvocableVariable(label='Category ID' required=true description='ID of the category')
        global String categoryId;

        @InvocableVariable(label='Price Book ID' description='ID of the price book')
        global String priceBookId;

        @InvocableVariable(label='Product Classification ID' description='ID of the product classification')
        global String productClassificationId;

        @InvocableVariable(label='Currency Code' description='Currency code for pricing and filtering')
        global String currencyCode;

        @InvocableVariable(label='Correlation ID' description='Unique identifier for request tracking')
        global String correlationId;

        @InvocableVariable(label='Cursor' description='Pagination cursor position')
        global String cursor;

        @InvocableVariable(label='Search Term' description='Text search on product name')
        global String searchTerm;

        @InvocableVariable(label='Context Definition' description='Custom context definition API name')
        global String contextDefinition;

        @InvocableVariable(label='Context Mapping' description='Context mapping of the context definition')
        global String contextMapping;

        @InvocableVariable(label='Pricing Procedure' description='Custom pricing procedure API name')
        global String pricingProcedure;

        @InvocableVariable(label='Qualification Procedure' description='Custom qualification procedure API name')
        global String qualificationProcedure;

        @InvocableVariable(label='Enable Pricing' description='Enable pricing for products (default true)')
        global Boolean enablePricing;

        @InvocableVariable(label='Enable Qualification' description='Enable qualification rules (default true)')
        global Boolean enableQualification;

        @InvocableVariable(label='Include Catalog Details' description='Include catalog details in response')
        global Boolean includeCatalogDetails;

        @InvocableVariable(label='Use Promotions' description='Fetch eligible promotions from GPM')
        global Boolean usePromotions;

        @InvocableVariable(label='Limit' description='Number of items per page (default 10)')
        global Integer limitSize;

        @InvocableVariable(label='Order By' description='Comma-separated sort fields (e.g. name:asc,id:desc)')
        global String orderBy;

        @InvocableVariable(label='Account ID' description='Account ID for user context')
        global String accountId;

        @InvocableVariable(label='Contact ID' description='Contact ID for user context')
        global String contactId;

        @InvocableVariable(
            label='Filter JSON'
            description='Valid JSON for the request body filter only (merged under key filter). Example: {"criteria":[{"property":"name","operator":"contains","value":"Blaze"}]}. Do not wrap with a "filter" property.'
        )
        global String filterJson;

        @InvocableVariable(label='Additional Fields JSON' description='JSON string for additionalFields map')
        global String additionalFieldsJson;

        @InvocableVariable(label='Additional Context Data JSON' description='JSON string for additionalContextData')
        global String additionalContextDataJson;

        @InvocableVariable(label='Related Object Filter JSON' description='JSON string for relatedObjectFilter')
        global String relatedObjectFilterJson;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner class: Invocable response wrapper
    // ─────────────────────────────────────────────────────────────────────────

    global class ProductsListResponse {
        @InvocableVariable(label='HTTP Status Code')
        global Integer statusCode;

        @InvocableVariable(label='Response Body')
        global String responseBody;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner class: Product details (Invocable) request / response
    // ─────────────────────────────────────────────────────────────────────────

    global class ProductDetailsRequest {
        @InvocableVariable(label='Product ID' required=true description='Salesforce product ID (e.g. Product2) to retrieve')
        global String productId;

        @InvocableVariable(label='Category ID' description='Category for catalog context')
        global String categoryId;

        @InvocableVariable(label='Catalog ID' description='ID of the catalog')
        global String catalogId;

        @InvocableVariable(label='Price Book ID' description='ID of the price book')
        global String priceBookId;

        @InvocableVariable(label='Product Classification ID' description='ID of the product classification')
        global String productClassificationId;

        @InvocableVariable(label='Currency Code' description='Currency code for pricing')
        global String currencyCode;

        @InvocableVariable(label='Correlation ID' description='Unique identifier for request tracking')
        global String correlationId;

        @InvocableVariable(label='Context Definition' description='Custom context definition API name')
        global String contextDefinition;

        @InvocableVariable(label='Context Mapping' description='Context mapping of the context definition')
        global String contextMapping;

        @InvocableVariable(label='Pricing Procedure' description='Custom pricing procedure API name')
        global String pricingProcedure;

        @InvocableVariable(label='Qualification Procedure' description='Custom qualification procedure API name')
        global String qualificationProcedure;

        @InvocableVariable(label='Enable Pricing' description='Enable pricing for the product')
        global Boolean enablePricing;

        @InvocableVariable(label='Enable Qualification' description='Enable qualification rules')
        global Boolean enableQualification;

        @InvocableVariable(label='Include Catalog Details' description='Include catalog details in response')
        global Boolean includeCatalogDetails;

        @InvocableVariable(label='Use Promotions' description='Fetch eligible promotions from GPM')
        global Boolean usePromotions;

        @InvocableVariable(label='Account ID' description='Account ID for user context')
        global String accountId;

        @InvocableVariable(label='Contact ID' description='Contact ID for user context')
        global String contactId;

        @InvocableVariable(
            label='Filter JSON'
            description='Valid JSON for the request body filter only (merged under key filter). Example: {"criteria":[{"property":"name","operator":"contains","value":"Blaze"}]}. Do not wrap with a "filter" property.'
        )
        global String filterJson;

        @InvocableVariable(label='Additional Fields JSON' description='JSON string for additionalFields map')
        global String additionalFieldsJson;

        @InvocableVariable(label='Additional Context Data JSON' description='JSON string for additionalContextData')
        global String additionalContextDataJson;

        @InvocableVariable(label='Related Object Filter JSON' description='JSON string for relatedObjectFilter')
        global String relatedObjectFilterJson;
    }

    global class ProductDetailsResponse {
        @InvocableVariable(label='HTTP Status Code')
        global Integer statusCode;

        @InvocableVariable(label='Response Body')
        global String responseBody;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    /**
     * @description Request for POST connect/consumer/checkout (Create Order).
     *              At least one of cartId or contextId is required; if both are sent, cartId takes precedence per API documentation.
     */
    global class CheckoutRequest {
        @InvocableVariable(label='Cart ID' description='WebCart Id (takes precedence over contextId when both are set)')
        global String cartId;

        @InvocableVariable(label='Context ID' description='Context Id used when cartId is not supplied')
        global String contextId;
    }

    global class CheckoutResponse {
        @InvocableVariable(label='HTTP Status Code')
        global Integer statusCode;

        @InvocableVariable(label='Response Body')
        global String responseBody;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Order ID' description='Created Order Id when the API returns success (parsed from response JSON)')
        global String orderId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Callable interface (OmniStudio Integration Procedure Remote Action)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Entry point for OmniStudio Integration Procedure Remote Action.
     *              Reads parameters from the input map, executes the callout, and
     *              returns the parsed response.
     * @param action The method name invoked by the Integration Procedure
     * @param args   Input parameter map from the Integration Procedure
     * @return Parsed API response as Map<String, Object>
     */
    global Object call(String action, Map<String, Object> args)
    {
        Map<String, Object> result = new Map<String, Object>();
        Map<String, Object> outputMap = new Map<String, Object>();
        if (args != null && args.containsKey('output') && args.get('output') instanceof Map<String, Object>) {
            outputMap = (Map<String, Object>) args.get('output');
        }

        try {
            HttpResponse res;

            if (isCheckoutAction(action)) {
                CheckoutRequest checkoutReq = mapArgsToCheckoutRequest(args);
                validateCheckoutRequest(checkoutReq);
                res = executeCheckoutCallout(checkoutReq);
            } else if (isProductDetailsAction(action)) {
                ProductDetailsRequest pdReq = mapArgsToProductDetailsRequest(args);
                validateProductDetailsRequest(pdReq);
                res = executeProductDetailsCallout(pdReq);
            } else {
                ProductsListRequest req = mapArgsToRequest(args);
                System.debug('**********   JLH: Before validateRequest');
                validateRequest(req);

                System.debug('**********   JLH: After validateRequest');
                res = executeCallout(req);
                System.debug('**********   JLH: After executeCallout');
            }

            // Provide top-level fields expected by many Integration Procedure Remote Action mappings.
            if (isCheckoutAction(action)) {
                result = parseCheckoutHttpResponse(res);
            } else {
                result = parseResponse(res);
            }
            System.debug('**********   JLH: responseBody: ' + res.getBody());
            result.put('responseBody', res.getBody());
            result.put('rawBody', res.getBody());
            try {
                result.put('responseJson', JSON.deserializeUntyped(res.getBody()));
            } catch (Exception parseEx) {
                result.put('responseJson', null);
            }

            
        } catch (Exception e) {
            result.put('statusCode', 500);
            result.put('isSuccess', false);
            result.put('error', e.getMessage());
        }

        // OmniStudio Remote Action typically reads from args.output.
        outputMap.putAll(result);

        // Preserve existing shape for any IP that maps from "output.*".
        result.put('output', new Map<String, Object>(result));
        System.debug('**********   JLH: Just before return result.  output: ' + result.get('output'));
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // @InvocableMethod (Flow invocation)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Invocable method for Flow and Process Builder invocation.
     * @param requests List of ProductsListRequest (only first element is processed)
     * @return List of ProductsListResponse with statusCode, responseBody, and errorMessage
     */
    @InvocableMethod(
        label='Get Revenue Cloud CPQ Products'
        description='Calls the Revenue Cloud connect/cpq/products API to retrieve a product list'
        category='Revenue Cloud'
    )
    global static List<ProductsListResponse> getProducts(List<ProductsListRequest> requests)
    {
        System.debug('**********   JLH: Starting getProducts  ' );
        List<ProductsListResponse> results = new List<ProductsListResponse>();
        ProductsListResponse resp = new ProductsListResponse();

        if (requests == null || requests.isEmpty()) {
            System.debug('**********   JLH: 1st condition  ' );
            resp.statusCode = null;
            resp.errorMessage = 'No request provided';
            results.add(resp);
            return results;
        }

        try {
            ProductsListRequest req = requests[0];
            validateRequest(req);
            HttpResponse res = executeCallout(req);
            System.debug('**********   JLH: Http Response: ' + res);
            resp.statusCode = res.getStatusCode();
            resp.responseBody = res.getBody();
            System.debug('**********   JLH: Http Response Body: '        + resp.responseBody);
            System.debug('**********   JLH: Http Response Status Code: ' + resp.statusCode);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                resp.errorMessage = 'API returned status ' + res.getStatusCode();
            }
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        System.debug('**********   JLH: In getProudcts RESULTS: ' + resp);
        results.add(resp);
        return results;
    }

    /**
     * @description Invoked from Flow through COM_Rev_Cloud_CPQ_ProductDetails_API (one InvocableMethod per class).
     *              POST connect/consumer/products/{productId}; only first request element is processed.
     * @param requests List of ProductDetailsRequest (only first element is processed)
     */
    global static List<ProductDetailsResponse> getProductDetails(List<ProductDetailsRequest> requests)
    {
        List<ProductDetailsResponse> results = new List<ProductDetailsResponse>();
        ProductDetailsResponse resp = new ProductDetailsResponse();

        if (requests == null || requests.isEmpty()) {
            resp.statusCode = null;
            resp.errorMessage = 'No request provided';
            results.add(resp);
            return results;
        }

        try {
            ProductDetailsRequest req = requests[0];
            validateProductDetailsRequest(req);
            HttpResponse res = executeProductDetailsCallout(req);
            resp.statusCode = res.getStatusCode();
            resp.responseBody = res.getBody();
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                resp.errorMessage = 'API returned status ' + res.getStatusCode();
            }
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        results.add(resp);
        return results;
    }

    /**
     * @description Invoked from Flow through COM_Rev_Cloud_CPQ_Checkout_API (one @InvocableMethod per class).
     *              POST connect/consumer/checkout; only first request element is processed.
     */
    global static List<CheckoutResponse> createOrderFromCheckout(List<CheckoutRequest> requests) {
        List<CheckoutResponse> results = new List<CheckoutResponse>();
        CheckoutResponse resp = new CheckoutResponse();

        if (requests == null || requests.isEmpty()) {
            resp.statusCode = null;
            resp.errorMessage = 'No request provided';
            results.add(resp);
            return results;
        }

        try {
            CheckoutRequest req = requests[0];
            validateCheckoutRequest(req);
            HttpResponse res = executeCheckoutCallout(req);
            resp.statusCode = res.getStatusCode();
            resp.responseBody = res.getBody();
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                resp.orderId = extractOrderIdFromCheckoutBody(res.getBody());
            }
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                resp.errorMessage = 'API returned status ' + res.getStatusCode();
            }
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        results.add(resp);
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description OmniStudio Remote Action: checkout / create order method names (case-insensitive).
     */
    @TestVisible
    private static Boolean isCheckoutAction(String action) {
        if (String.isBlank(action)) {
            return false;
        }
        String a = action.trim().toLowerCase();
        return a == 'createorderfromcheckout'
            || a == 'createorder'
            || a == 'checkout'
            || a == 'consumercheckout';
    }

    /**
     * @description OmniStudio Remote Action: use method name getProductDetails, retrieveProductDetails, or productDetails.
     */
    @TestVisible
    private static Boolean isProductDetailsAction(String action) {
        if (String.isBlank(action)) {
            return false;
        }
        String a = action.trim().toLowerCase();
        return a == 'getproductdetails'
            || a == 'retrieveproductdetails'
            || a == 'productdetails';
    }

    /**
     * @description Maps the Integration Procedure input args to a ProductDetailsRequest.
     */
    private static ProductDetailsRequest mapArgsToProductDetailsRequest(Map<String, Object> args)
    {
        ProductDetailsRequest req = new ProductDetailsRequest();

        if (args == null) {
            return req;
        }

        Map<String, Object> inputMap;
        if (args.containsKey('input') && args.get('input') instanceof Map<String, Object>) {
            inputMap = (Map<String, Object>) args.get('input');
        } else {
            inputMap = args;
        }

        req.productId = getStringParam(inputMap, 'productId');
        req.categoryId = getStringParam(inputMap, 'categoryId');
        req.catalogId = getStringParam(inputMap, 'catalogId');
        req.priceBookId = getStringParam(inputMap, 'priceBookId');
        req.productClassificationId = getStringParam(inputMap, 'productClassificationId');
        req.currencyCode = getStringParam(inputMap, 'currencyCode');
        req.correlationId = getStringParam(inputMap, 'correlationId');
        req.contextDefinition = getStringParam(inputMap, 'contextDefinition');
        req.contextMapping = getStringParam(inputMap, 'contextMapping');
        req.pricingProcedure = getStringParam(inputMap, 'pricingProcedure');
        req.qualificationProcedure = getStringParam(inputMap, 'qualificationProcedure');
        req.accountId = getStringParam(inputMap, 'accountId');
        req.contactId = getStringParam(inputMap, 'contactId');
        req.filterJson = getStringParam(inputMap, 'filterJson');
        req.additionalFieldsJson = getStringParam(inputMap, 'additionalFieldsJson');
        req.additionalContextDataJson = getStringParam(inputMap, 'additionalContextDataJson');
        req.relatedObjectFilterJson = getStringParam(inputMap, 'relatedObjectFilterJson');

        req.enablePricing = getBooleanParam(inputMap, 'enablePricing');
        req.enableQualification = getBooleanParam(inputMap, 'enableQualification');
        req.includeCatalogDetails = getBooleanParam(inputMap, 'includeCatalogDetails');
        req.usePromotions = getBooleanParam(inputMap, 'usePromotions');

        return req;
    }

    /**
     * @description Maps Integration Procedure args to CheckoutRequest (supports cartID/contextID aliases from API docs).
     */
    private static CheckoutRequest mapArgsToCheckoutRequest(Map<String, Object> args) {
        CheckoutRequest req = new CheckoutRequest();
        if (args == null) {
            return req;
        }
        Map<String, Object> inputMap;
        if (args.containsKey('input') && args.get('input') instanceof Map<String, Object>) {
            inputMap = (Map<String, Object>) args.get('input');
        } else {
            inputMap = args;
        }
        req.cartId = firstNonBlankString(
            getStringParam(inputMap, 'cartId'),
            getStringParam(inputMap, 'cartID')
        );
        req.contextId = firstNonBlankString(
            getStringParam(inputMap, 'contextId'),
            getStringParam(inputMap, 'contextID')
        );
        return req;
    }

    private static String firstNonBlankString(String a, String b) {
        if (String.isNotBlank(a)) {
            return a;
        }
        return String.isNotBlank(b) ? b : null;
    }

    @TestVisible
    private static void validateCheckoutRequest(CheckoutRequest req) {
        if (req == null || (String.isBlank(req.cartId) && String.isBlank(req.contextId))) {
            throw new CPQApiException(
                'At least one of cartId or contextId is required for connect/consumer/checkout (Create Order).'
            );
        }
    }

    /**
     * @description JSON body per CME Create Order: { "inputs": [ { "cartId", "contextId" } ] }.
     */
    @TestVisible
    private static String buildCheckoutRequestBody(CheckoutRequest req) {
        Map<String, Object> row = new Map<String, Object>();
        putIfNotBlank(row, 'cartId', req.cartId);
        putIfNotBlank(row, 'contextId', req.contextId);
        Map<String, Object> envelope = new Map<String, Object>();
        envelope.put('inputs', new List<Object>{ row });
        return JSON.serialize(envelope);
    }

    @TestVisible
    private static HttpResponse executeCheckoutCallout(CheckoutRequest req) {
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String endpoint = baseUrl + CONSUMER_CHECKOUT_PATH;
        String requestBody = buildCheckoutRequestBody(req);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Authorization', 'Bearer ' + getApiSessionId());
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('Accept', 'application/json');
        httpReq.setBody(requestBody);
        httpReq.setTimeout(120000);

        Http http = new Http();
        return http.send(httpReq);
    }

    /**
     * @description Parses checkout array response: [ { "errors": [], "orderId": "..." } ].
     */
    @TestVisible
    private static Map<String, Object> parseCheckoutHttpResponse(HttpResponse res) {
        Map<String, Object> result = new Map<String, Object>();
        Integer statusCode = res.getStatusCode();
        result.put('statusCode', statusCode);
        String responseBody = res.getBody();

        if (statusCode >= 200 && statusCode < 300) {
            result.put('isSuccess', true);
            try {
                List<Object> parsedList = (List<Object>) JSON.deserializeUntyped(responseBody);
                result.put('responseJson', parsedList);
                if (parsedList != null && !parsedList.isEmpty() && parsedList[0] instanceof Map<String, Object>) {
                    Map<String, Object> firstRow = (Map<String, Object>) parsedList[0];
                    result.put('orderId', firstRow.get('orderId'));
                    result.put('errors', firstRow.get('errors'));
                }
            } catch (Exception e) {
                result.put('isSuccess', false);
                result.put('error', 'Failed to parse checkout response: ' + e.getMessage());
                result.put('rawBody', responseBody);
            }
        } else {
            result.put('isSuccess', false);
            result.put('error', 'API returned status ' + statusCode);
            try {
                Object errParsed = JSON.deserializeUntyped(responseBody);
                result.put('errorDetails', errParsed);
            } catch (Exception e) {
                result.put('rawBody', responseBody);
            }
        }
        return result;
    }

    @TestVisible
    private static String extractOrderIdFromCheckoutBody(String responseBody) {
        if (String.isBlank(responseBody)) {
            return null;
        }
        try {
            List<Object> parsedList = (List<Object>) JSON.deserializeUntyped(responseBody);
            if (parsedList != null && !parsedList.isEmpty() && parsedList[0] instanceof Map<String, Object>) {
                Object oid = ((Map<String, Object>) parsedList[0]).get('orderId');
                return oid != null ? String.valueOf(oid) : null;
            }
        } catch (Exception e) {
            // leave null; caller still has full responseBody
        }
        return null;
    }

    @TestVisible
    private static void validateProductDetailsRequest(ProductDetailsRequest req) {
        String productId = (req == null) ? null : req.productId;
        if (String.isBlank(productId)) {
            throw new CPQApiException('productId is required. Please provide a valid Product ID.');
        }
    }

    /**
     * @description JSON body for POST .../connect/consumer/products/{productId}
     *              (productId is only in the URL; optional fields match the prior CPQ product-details shape).
     */
    @TestVisible
    private static String buildProductDetailsRequestBody(ProductDetailsRequest req) {
        Map<String, Object> body = new Map<String, Object>();

        putIfNotBlank(body, 'categoryId', req.categoryId);
        putIfNotBlank(body, 'catalogId', req.catalogId);
        putIfNotBlank(body, 'priceBookId', req.priceBookId);
        putIfNotBlank(body, 'productClassificationId', req.productClassificationId);
        putIfNotBlank(body, 'currencyCode', req.currencyCode);
        putIfNotBlank(body, 'correlationId', req.correlationId);
        putIfNotBlank(body, 'contextDefinition', req.contextDefinition);
        putIfNotBlank(body, 'contextMapping', req.contextMapping);
        putIfNotBlank(body, 'pricingProcedure', req.pricingProcedure);
        putIfNotBlank(body, 'qualificationProcedure', req.qualificationProcedure);

        putIfNotNull(body, 'enablePricing', req.enablePricing);
        putIfNotNull(body, 'enableQualification', req.enableQualification);
        putIfNotNull(body, 'includeCatalogDetails', req.includeCatalogDetails);
        putIfNotNull(body, 'usePromotions', req.usePromotions);

        if (String.isNotBlank(req.accountId) || String.isNotBlank(req.contactId)) {
            Map<String, Object> userCtx = new Map<String, Object>();
            putIfNotBlank(userCtx, 'accountId', req.accountId);
            putIfNotBlank(userCtx, 'contactId', req.contactId);
            body.put('userContext', userCtx);
        }

        deserializeJsonParam(body, 'filter', req.filterJson);
        deserializeJsonParam(body, 'additionalFields', req.additionalFieldsJson);
        deserializeJsonParam(body, 'relatedObjectFilter', req.relatedObjectFilterJson);

        if (String.isNotBlank(req.additionalContextDataJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(req.additionalContextDataJson);
                body.put('additionalContextData', parsed);
            } catch (Exception e) {
                throw new CPQApiException('Invalid JSON for additionalContextData: ' + e.getMessage());
            }
        }

        return JSON.serialize(body);
    }

    @TestVisible
    private static HttpResponse executeProductDetailsCallout(ProductDetailsRequest req) {
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String endpoint = baseUrl + PRODUCT_DETAILS_PATH_PREFIX + req.productId;
        String requestBody = buildProductDetailsRequestBody(req);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Authorization', 'Bearer ' + getApiSessionId());
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('Accept', 'application/json');
        httpReq.setBody(requestBody);
        httpReq.setTimeout(120000);

        Http http = new Http();

        return http.send(httpReq);
    }

    /**
     * @description Maps the Integration Procedure input args to a ProductsListRequest.
     */
    private static ProductsListRequest mapArgsToRequest(Map<String, Object> args) 
    {
        ProductsListRequest req = new ProductsListRequest();

        if (args == null) {
            return req;
        }

        // Extract the 'input' sub-map from the OmniStudio args; fall back to args itself
        Map<String, Object> inputMap;
        if (args.containsKey('input') && args.get('input') instanceof Map<String, Object>) {
            inputMap = (Map<String, Object>) args.get('input');
        } else {
            inputMap = args;
        }

        // String params
 
        req.categoryId                 = getStringParam(inputMap, 'categoryId');
        req.filterJson                 = getStringParam(inputMap, 'filterJson');
        System.debug('**********   JLH: In mapArgsToRequest categoryId: ' + req.categoryId);
        /*
        req.catalogId                  = getStringParam(inputMap, 'catalogId');
        req.priceBookId                = getStringParam(inputMap, 'priceBookId');
        req.productClassificationId    = getStringParam(inputMap, 'productClassificationId');
        req.currencyCode               = getStringParam(inputMap, 'currencyCode');
        req.correlationId              = getStringParam(inputMap, 'correlationId');
        req.cursor                     = getStringParam(inputMap, 'cursor');
        req.searchTerm                 = getStringParam(inputMap, 'searchTerm');
        req.contextDefinition          = getStringParam(inputMap, 'contextDefinition');
        req.contextMapping             = getStringParam(inputMap, 'contextMapping');
        req.pricingProcedure           = getStringParam(inputMap, 'pricingProcedure');
        req.qualificationProcedure     = getStringParam(inputMap, 'qualificationProcedure');
        req.accountId                  = getStringParam(inputMap, 'accountId');
        req.contactId                  = getStringParam(inputMap, 'contactId');

        req.additionalFieldsJson       = getStringParam(inputMap, 'additionalFieldsJson');
        req.additionalContextDataJson  = getStringParam(inputMap, 'additionalContextDataJson');
        req.relatedObjectFilterJson    = getStringParam(inputMap, 'relatedObjectFilterJson');
        req.orderBy                    = getStringParam(inputMap, 'orderBy');

        // Boolean params
        req.enablePricing         = getBooleanParam(inputMap, 'enablePricing');
        req.enableQualification   = getBooleanParam(inputMap, 'enableQualification');
        req.includeCatalogDetails = getBooleanParam(inputMap, 'includeCatalogDetails');
        req.usePromotions         = getBooleanParam(inputMap, 'usePromotions');

        // Integer params
        req.limitSize = getIntegerParam(inputMap, 'limitSize');
        if (req.limitSize == null) {
            req.limitSize = getIntegerParam(inputMap, 'limit');
        }
*/
        return req;
    }

    /**
     * @description Validates that required fields are present.
     */
    @TestVisible
    private static void validateRequest(ProductsListRequest req) {
        String categoryId = (req == null) ? null : req.categoryId;
        if (String.isBlank(categoryId)) {
            throw new CPQApiException('categoryId is required. Please provide a valid Category ID.');
        }
    }

    /**
     * @description Builds the JSON request body from the ProductsListRequest.
     */
    @TestVisible
    private static String buildRequestBody(ProductsListRequest req) 
    {
        Map<String, Object> body = new Map<String, Object>();

        // Required
        body.put('categoryId', req.categoryId);

        deserializeJsonParam(body, 'filter', req.filterJson);

        // Optional strings

        /*
        putIfNotBlank(body, 'catalogId', req.catalogId);
        putIfNotBlank(body, 'priceBookId', req.priceBookId);
        putIfNotBlank(body, 'productClassificationId', req.productClassificationId);
        putIfNotBlank(body, 'currencyCode', req.currencyCode);
        putIfNotBlank(body, 'correlationId', req.correlationId);
        putIfNotBlank(body, 'cursor', req.cursor);
        putIfNotBlank(body, 'searchTerm', req.searchTerm);
        putIfNotBlank(body, 'contextDefinition', req.contextDefinition);
        putIfNotBlank(body, 'contextMapping', req.contextMapping);
        putIfNotBlank(body, 'pricingProcedure', req.pricingProcedure);
        putIfNotBlank(body, 'qualificationProcedure', req.qualificationProcedure);

        // Optional booleans
        putIfNotNull(body, 'enablePricing', req.enablePricing);
        putIfNotNull(body, 'enableQualification', req.enableQualification);
        putIfNotNull(body, 'includeCatalogDetails', req.includeCatalogDetails);
        putIfNotNull(body, 'usePromotions', req.usePromotions);

        // Limit (mapped from limitSize)
        if (req.limitSize != null) {
            body.put('limit', req.limitSize);
        }

        // Order By — comma-separated string to List
        if (String.isNotBlank(req.orderBy)) {
            List<String> orderByList = new List<String>();
            for (String s : req.orderBy.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    orderByList.add(trimmed);
                }
            }
            if (!orderByList.isEmpty()) {
                body.put('orderBy', orderByList);
            }
        }

        // User Context — nested object
        if (String.isNotBlank(req.accountId) || String.isNotBlank(req.contactId)) {
            Map<String, Object> userCtx = new Map<String, Object>();
            putIfNotBlank(userCtx, 'accountId', req.accountId);
            putIfNotBlank(userCtx, 'contactId', req.contactId);
            body.put('userContext', userCtx);
        }

        // Complex JSON params — deserialize raw JSON strings
        deserializeJsonParam(body, 'additionalFields', req.additionalFieldsJson);
        deserializeJsonParam(body, 'relatedObjectFilter', req.relatedObjectFilterJson);

        if (String.isNotBlank(req.additionalContextDataJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(req.additionalContextDataJson);
                body.put('additionalContextData', parsed);
            } catch (Exception e) {
                throw new CPQApiException('Invalid JSON for additionalContextData: ' + e.getMessage());
            }
        }
            */

        return JSON.serialize(body);
    }

    /**
     * @description Executes the HTTP callout to the Revenue Cloud API.
     */
    @TestVisible
    private static HttpResponse executeCallout(ProductsListRequest req) {
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String endpoint = baseUrl + ENDPOINT_PATH;
        String requestBody = buildRequestBody(req);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Authorization', 'Bearer ' + getApiSessionId());
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setBody(requestBody);
        httpReq.setTimeout(120000);

        Http http = new Http();

        return http.send(httpReq);
    }

    /**
     * @description Retrieves an API-capable session ID.
     *              In Lightning / OmniStudio context, UserInfo.getSessionId()
     *              returns a UI-scoped token that is NOT valid for REST API calls.
     *              This method falls back to a Visualforce page that exposes
     *              $Api.Session_ID, which IS API-capable.
     * @return A valid session ID for REST API authorization
     */
    @TestVisible
    private static String getApiSessionId() {
        // In test context, UserInfo.getSessionId() is sufficient (mocks handle auth)
        if (Test.isRunningTest()) {
            return UserInfo.getSessionId();
        }

        // Try the VF page approach first — it returns an API-capable session
        try {
            PageReference sessionPage = Page.COM_Rev_Cloud_CPQ_SessionId;
            String sessionId = sessionPage.getContent().toString().trim();
            if (String.isNotBlank(sessionId)) {
                return sessionId;
            }
        } catch (Exception e) {
            // VF page may not be available (e.g., in certain async contexts)
            // Fall through to UserInfo.getSessionId()
        }

        // Fallback: direct session ID (works in Apex-triggered / Classic contexts)
        String sessionId = UserInfo.getSessionId();
        if (String.isBlank(sessionId)) {
            throw new CPQApiException(
                'Unable to obtain a valid API session. ' +
                'This callout cannot be executed in the current context (e.g., async Apex). ' +
                'Consider using Named Credentials for async invocations.'
            );
        }
        return sessionId;
    }

    /**
     * @description Parses the HTTP response into a structured Map.
     */
    @TestVisible
    private static Map<String, Object> parseResponse(HttpResponse res) 
    {
        Map<String, Object> result = new Map<String, Object>();

        Integer statusCode = res.getStatusCode();
        result.put('statusCode', statusCode);

        String responseBody = res.getBody();

        if (statusCode == 200) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
                result.putAll(parsed);
                result.put('isSuccess', true);
            } catch (Exception e) {
                result.put('isSuccess', false);
                result.put('error', 'Failed to parse response: ' + e.getMessage());
                result.put('rawBody', responseBody);
            }
        } else {
            result.put('isSuccess', false);
            result.put('error', 'API returned status ' + statusCode);
            try {
                Map<String, Object> errorParsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
                result.put('errorDetails', errorParsed);
            } catch (Exception e) {
                result.put('rawBody', responseBody);
            }
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utility methods
    // ─────────────────────────────────────────────────────────────────────────

    private static String getStringParam(Map<String, Object> args, String key) {
        Object val = args.get(key);
        return val != null ? String.valueOf(val) : null;
    }

    private static Boolean getBooleanParam(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null) {
            return null;
        }
        if (val instanceof Boolean) {
            return (Boolean) val;
        }
        return Boolean.valueOf(String.valueOf(val));
    }

    private static Integer getIntegerParam(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null) {
            return null;
        }
        if (val instanceof Integer) {
            return (Integer) val;
        }
        try {
            return Integer.valueOf(String.valueOf(val));
        } catch (Exception e) {
            return null;
        }
    }

    private static void putIfNotBlank(Map<String, Object> m, String key, String value) {
        if (String.isNotBlank(value)) {
            m.put(key, value);
        }
    }

    private static void putIfNotNull(Map<String, Object> m, String key, Object value) {
        if (value != null) {
            m.put(key, value);
        }
    }

    private static void deserializeJsonParam(Map<String, Object> body, String key, String jsonStr) {
        if (String.isNotBlank(jsonStr)) {
            try {
                Object parsed = JSON.deserializeUntyped(jsonStr);
                body.put(key, parsed);
            } catch (Exception e) {
                throw new CPQApiException('Invalid JSON for ' + key + ': ' + e.getMessage());
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Custom exception
    // ─────────────────────────────────────────────────────────────────────────

    global class CPQApiException extends Exception {}
}