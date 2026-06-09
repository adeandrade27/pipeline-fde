global with sharing class CategoryRemoteAction implements Callable {
    private static final String NAMED_CREDENTIAL = 'CategoryService';

    global Object call(String action, Map<String, Object> args) {
        Map<String, Object> safeArgs = args == null ? new Map<String, Object>() : args;
        Map<String, Object> input = (Map<String, Object>) safeArgs.get('input');
        Map<String, Object> output = (Map<String, Object>) safeArgs.get('output');

        if (output == null) {
            output = new Map<String, Object>();
        }

        if (String.isBlank(action)) {
            action = 'getCategory';
        }

        if (action == 'getCategory') {
            output.putAll(getCategory(input));
            return output;
        }

        throw new IllegalArgumentException('Unsupported action: ' + action);
    }

    @TestVisible
    private static Map<String, Object> getCategory(Map<String, Object> input) {
        String categoryId = input == null ? null : (String) input.get('categoryId');
        if (String.isBlank(categoryId)) {
            throw new IllegalArgumentException('Required input parameter "categoryId" was not provided.');
        }

        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint(
            'callout:' + NAMED_CREDENTIAL + '/categories/' + EncodingUtil.urlEncode(categoryId, 'UTF-8')
        );
        request.setHeader('Accept', 'application/json');

        HttpResponse response = new Http().send(request);
        Map<String, Object> result = new Map<String, Object>{
            'categoryId' => categoryId,
            'statusCode' => response.getStatusCode(),
            'success' => response.getStatusCode() >= 200 && response.getStatusCode() < 300,
            'responseBody' => response.getBody()
        };
        return result;
    }
}