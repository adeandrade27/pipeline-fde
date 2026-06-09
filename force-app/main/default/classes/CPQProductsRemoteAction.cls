/**
 * CPQProductsRemoteAction
 *
 * Callable Apex class that wraps the Revenue Cloud REST API endpoint
 * POST /connect/cpq/products (Products List / Product Discovery).
 *
 * Designed to be invoked from an OmniStudio Integration Procedure
 * as a Remote Action element.
 *
 * Authorization uses a Visualforce page (SessionIdPage) to obtain
 * a valid session ID for same-org HTTP callouts — no Named Credentials required.
 *
 * Returns: Map<String, Object> with keys:
 *   - statusCode  (Integer) : HTTP status code
 *   - responseBody (String) : Raw JSON response body
 *   - errorMessage (String) : Error description (empty on success)
 */
public with sharing class CPQProductsRemoteAction implements Callable {

    private static final String API_VERSION = 'v62.0';
    private static final String ENDPOINT_PATH = '/services/data/' + API_VERSION + '/connect/cpq/products';

    // Optional String parameter keys
    private static final List<String> STRING_PARAMS = new List<String>{
        'catalogId', 'correlationId', 'currencyCode', 'cursor',
        'priceBookId', 'pricingProcedure', 'qualificationProcedure',
        'productClassificationId', 'contextDefinition', 'contextMapping',
        'searchTerm', 'transactionContextId', 'transactionId'
    };

    // Optional Boolean parameter keys
    private static final List<String> BOOLEAN_PARAMS = new List<String>{
        'enablePricing', 'enableQualification', 'includeCatalogDetails',
        'executeConfigurationRules', 'usePromotions'
    };

    // Optional Integer parameter keys
    private static final List<String> INTEGER_PARAMS = new List<String>{
        'limit', 'offset'
    };

    // Complex object parameter keys (JSON strings from Integration Procedure)
    private static final List<String> COMPLEX_PARAMS = new List<String>{
        'userContext', 'filter', 'relatedObjectFilters',
        'additionalContextData', 'additionalFields'
    };

    /**
     * Callable interface implementation.
     * OmniStudio Integration Procedure Remote Action invokes this method.
     *
     * @param action  Method name (responds to any action; default behavior is getProducts)
     * @param args    Map of input parameters from the Integration Procedure
     * @return Map<String, Object> with statusCode, responseBody, errorMessage
     */
    public Object call(String action, Map<String, Object> args) {
        Map<String, Object> result = new Map<String, Object>();

        try {
            System.debug('**********   JLH: action is : ' + action);
            // Validate required parameter
            if (args == null || !args.containsKey('categoryId') || args.get('categoryId') == null) {
                result.put('statusCode', 400);
                result.put('responseBody', '');
                result.put('errorMessage', 'categoryId is required');
                return result;
            }

            String categoryId = String.valueOf(args.get('categoryId'));
            if (String.isBlank(categoryId)) {
                result.put('statusCode', 400);
                result.put('responseBody', '');
                result.put('errorMessage', 'categoryId is required');
                return result;
            }

            // Build request body and execute callout
            String requestBody = buildRequestBody(args);
            System.debug('**********   JLH: In  REQUEST BODY: ' + requestBody);
            HttpResponse response = executeCallout(requestBody);
            System.debug('**********   JLH: In  RESPONSE: ' + response);
            System.debug('**********   JLH: In  RESPONSE BODY: ' + response.getBody());

            Integer statusCode = response.getStatusCode();
            String responseBody = response.getBody();

            result.put('statusCode', statusCode);
            result.put('responseBody', responseBody);

            if (statusCode >= 200 && statusCode < 300) {
                result.put('errorMessage', '');
            } else {
                String errorMsg = 'HTTP ' + statusCode + ': ';
                try {
                    Map<String, Object> errorBody = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
                    if (errorBody.containsKey('message')) {
                        errorMsg += String.valueOf(errorBody.get('message'));
                    } else if (errorBody.containsKey('error')) {
                        errorMsg += String.valueOf(errorBody.get('error'));
                    } else {
                        errorMsg += responseBody;
                    }
                } catch (Exception parseEx) {
                    errorMsg += responseBody;
                }
                result.put('errorMessage', errorMsg);
            }

        } catch (Exception ex) {
            result.put('statusCode', 500);
            result.put('responseBody', '');
            result.put('errorMessage', ex.getMessage() + ' | ' + ex.getStackTraceString());
        }

        return result;
    }

    /**
     * Builds the JSON request body from the input parameters map.
     * Only includes parameters that are present and non-null.
     */
    @TestVisible
    private String buildRequestBody(Map<String, Object> args) {
        Map<String, Object> body = new Map<String, Object>();

        // Required parameter
        body.put('categoryId', String.valueOf(args.get('categoryId')));

        // Optional String parameters
        for (String param : STRING_PARAMS) {
            if (args.containsKey(param) && args.get(param) != null) {
                String val = String.valueOf(args.get(param));
                if (String.isNotBlank(val)) {
                    body.put(param, val);
                }
            }
        }

        // Optional Boolean parameters
        for (String param : BOOLEAN_PARAMS) {
            if (args.containsKey(param) && args.get(param) != null) {
                Object val = args.get(param);
                if (val instanceof Boolean) {
                    body.put(param, (Boolean) val);
                } else {
                    body.put(param, Boolean.valueOf(String.valueOf(val)));
                }
            }
        }

        // Optional Integer parameters
        for (String param : INTEGER_PARAMS) {
            if (args.containsKey(param) && args.get(param) != null) {
                Object val = args.get(param);
                if (val instanceof Integer) {
                    body.put(param, (Integer) val);
                } else if (val instanceof Decimal) {
                    body.put(param, ((Decimal) val).intValue());
                } else {
                    body.put(param, Integer.valueOf(String.valueOf(val)));
                }
            }
        }

        // Optional orderBy (String array)
        if (args.containsKey('orderBy') && args.get('orderBy') != null) {
            Object orderByVal = args.get('orderBy');
            if (orderByVal instanceof List<Object>) {
                body.put('orderBy', orderByVal);
            } else {
                String orderByStr = String.valueOf(orderByVal);
                if (String.isNotBlank(orderByStr)) {
                    if (orderByStr.startsWith('[')) {
                        // JSON array string
                        body.put('orderBy', JSON.deserializeUntyped(orderByStr));
                    } else {
                        // Comma-separated string
                        List<String> orderByList = new List<String>();
                        for (String item : orderByStr.split(',')) {
                            String trimmed = item.trim();
                            if (String.isNotBlank(trimmed)) {
                                orderByList.add(trimmed);
                            }
                        }
                        body.put('orderBy', orderByList);
                    }
                }
            }
        }

        // Complex object parameters (JSON strings deserialized to objects)
        for (String param : COMPLEX_PARAMS) {
            if (args.containsKey(param) && args.get(param) != null) {
                Object val = args.get(param);
                if (val instanceof String) {
                    String jsonStr = (String) val;
                    if (String.isNotBlank(jsonStr)) {
                        body.put(param, JSON.deserializeUntyped(jsonStr));
                    }
                } else if (val instanceof Map<String, Object> || val instanceof List<Object>) {
                    // Already a structured object (e.g., from nested IP data)
                    body.put(param, val);
                }
            }
        }

        return JSON.serialize(body);
    }

    /**
     * Executes the HTTP POST callout to the connect/cpq/products endpoint.
     */
    private HttpResponse executeCallout(String requestBody) {
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String endpoint = baseUrl + ENDPOINT_PATH;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + getSessionId());
        req.setBody(requestBody);
        req.setTimeout(120000); // 2 minute timeout for large catalogs

        Http http = new Http();
        return http.send(req);
    }

    /**
     * Obtains a valid session ID by reading the SessionIdPage Visualforce page.
     * This pattern avoids Named Credentials and provides a session token
     * valid for same-org REST API callouts.
     */
    @TestVisible
    private String getSessionId() {
        if (Test.isRunningTest()) {
            return 'TEST_SESSION_ID';
        }
        String sessionId = Page.SessionIdPage.getContent().toString().trim();
        return sessionId;
    }
}