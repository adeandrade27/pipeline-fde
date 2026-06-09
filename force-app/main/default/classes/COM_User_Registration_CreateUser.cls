/**
 * @description OmniStudio Integration Procedure Remote Action class that exposes
 *              createcommunityuser and delegates helper logic to COM_User_Registration.
 */
global without sharing class COM_User_Registration_CreateUser extends COM_User_Registration implements Callable {

    /**
     * @description Callable entry point for OmniStudio Remote Action.
     * @param action Method/action name configured on the Remote Action element
     * @param args Input map containing input/output/options maps
     * @return Result map with output payload and status flags
     */
    global Object call(String action, Map<String, Object> args) {
        Map<String, Object> safeArgs = (args == null) ? new Map<String, Object>() : args;
        Map<String, Object> input = extractMap(safeArgs, 'input');
        Map<String, Object> output = extractMap(safeArgs, 'output');
        Map<String, Object> options = extractMap(safeArgs, 'options');

        Boolean success = invokeMethod(action, input, output, options);

        Map<String, Object> result = new Map<String, Object>();
        result.put('success', success);
        result.put('output', output);
        return result;
    }

    /**
     * @description Remote Action method router. Supports action name createcommunityuser.
     * @return true when the invoked operation succeeds
     */
    global Boolean invokeMethod(
        String methodName,
        Map<String, Object> input,
        Map<String, Object> output,
        Map<String, Object> options
    ) {
        try {
            if (isCreateCommunityUserAction(methodName)) {
                return createcommunityuser(input, output, options);
            }

            output.put('error', 'Unsupported method name: ' + methodName);
            return false;
        } catch (Exception e) {
            output.put('error', e.getMessage());
            return false;
        }
    }

    /**
     * @description Remote-action callable method for Integration Procedures.
     *              Method name intentionally uses lower-case to match requested action name.
     */
    global Boolean createcommunityuser(
        Map<String, Object> input,
        Map<String, Object> output,
        Map<String, Object> options
    ) {
        return createCommunityUserInternal(input, output);
    }

    private static Boolean isCreateCommunityUserAction(String methodName) {
        return String.isNotBlank(methodName)
            && methodName.trim().toLowerCase() == 'createcommunityuser';
    }

    private static Map<String, Object> extractMap(Map<String, Object> source, String key) {
        if (source.containsKey(key) && source.get(key) instanceof Map<String, Object>) {
            return (Map<String, Object>) source.get(key);
        }
        return new Map<String, Object>();
    }
}