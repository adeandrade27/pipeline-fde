/**
 * Calls Connect CPQ REST: POST /services/data/{version}/connect/cpq/products
 * Omnistudio Integration Procedure Remote Action: implement Callable (call method).
 * Optional: @InvocableMethod for Flow / Invocable actions.
 */
public with sharing class CpqConnectProductsService implements System.Callable {
    public static final String DEFAULT_API_VERSION = 'v66.0';

    /** Callable action when method name is omitted or matches this value */
    public static final String ACTION_GET_PRODUCTS_BY_CATEGORY = 'getProductsByCategory';

    public class ServiceException extends Exception {}

    public class InvocableRequest {
        @InvocableVariable(required = true label = 'Category Id' description = 'CPQ category Id (18-char)')
        public String categoryId;

        @InvocableVariable(label = 'API Version' description = 'REST API version, e.g. v66.0')
        public String apiVersion;
    }

    public class InvocableResponse {
        @InvocableVariable(label = 'HTTP Status Code')
        public Integer statusCode;

        @InvocableVariable(label = 'Response Body')
        public String responseBody;

        @InvocableVariable(label = 'Error Message')
        public String errorMessage;
    }

    /**
     * Omnistudio / Remote Apex: args typically include categoryId, optional apiVersion.
     * action: use {@link #ACTION_GET_PRODUCTS_BY_CATEGORY} or blank to run the same.
     */
    public Object call(String action, Map<String, Object> args) {
        Map<String, Object> a = args == null ? new Map<String, Object>() : args;
        String act = String.isBlank(action) ? ACTION_GET_PRODUCTS_BY_CATEGORY : action.trim();
        if (act.equalsIgnoreCase(ACTION_GET_PRODUCTS_BY_CATEGORY)) {
            return fetchProductsResultMap(stringArg(a, 'categoryId'), stringArg(a, 'apiVersion'));
        }
        throw new ServiceException('Unknown action: ' + action);
    }

    @InvocableMethod(
        label = 'Get CPQ Products by Category'
        description = 'POST to Connect CPQ products endpoint for a category Id'
    )
    public static List<InvocableResponse> getProductsByCategory(List<InvocableRequest> requests) {
        List<InvocableResponse> out = new List<InvocableResponse>();
        if (requests == null || requests.isEmpty()) {
            return out;
        }
        System.debug('JLH:  requests: ' + requests);
        for (InvocableRequest req : requests) {
            out.add(toInvocableResponse(req));
        
        }
        System.debug('out: ' + out);
        return out;
    }

    public static HttpResponse fetchProductsByCategory(String categoryId) {
        return fetchProductsByCategory(categoryId, null);
    }

    public static HttpResponse fetchProductsByCategory(String categoryId, String apiVersion) {
        if (String.isBlank(categoryId)) {
            throw new ServiceException('categoryId is required');
        }
        String version = String.isNotBlank(apiVersion) ? apiVersion : DEFAULT_API_VERSION;
        String endpoint =
            Url.getOrgDomainUrl().toExternalForm() +
            '/services/data/' +
            version +
            '/connect/cpq/products';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + getApiSessionId());
        // req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setBody(JSON.serialize(new Map<String, Object>{ 'categoryId' => categoryId }));

        return new Http().send(req);
    }


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
            throw new ServiceException(
                'Unable to obtain a valid API session. ' +
                'This callout cannot be executed in the current context (e.g., async Apex). ' +
                'Consider using Named Credentials for async invocations.'
            );
        }
        return sessionId;
    }


    private static Map<String, Object> fetchProductsResultMap(String categoryId, String apiVersion) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            HttpResponse res = fetchProductsByCategory(categoryId, apiVersion);
            result.put('statusCode', res.getStatusCode());
            result.put('responseBody', res.getBody());
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                result.put('errorMessage', 'HTTP ' + String.valueOf(res.getStatusCode()));
            }
        } catch (Exception e) {
            result.put('statusCode', 0);
            result.put('errorMessage', e.getMessage());
        }
        return result;
    }

    private static InvocableResponse toInvocableResponse(InvocableRequest invocableReq) {
        InvocableResponse r = new InvocableResponse();
        Map<String, Object> m = fetchProductsResultMap(invocableReq.categoryId, invocableReq.apiVersion);
        Object sc = m.get('statusCode');
        r.statusCode = sc == null ? null : Integer.valueOf(String.valueOf(sc));
        r.responseBody = (String) m.get('responseBody');
        r.errorMessage = (String) m.get('errorMessage');
        return r;
    }

    private static String stringArg(Map<String, Object> args, String key) {
        if (!args.containsKey(key) || args.get(key) == null) {
            return null;
        }
        return String.valueOf(args.get(key));
    }



}