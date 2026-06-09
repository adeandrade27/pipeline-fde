/**
 * This class provides some useful functions that can be used within OmniStudio DataRaptor & Integration Procedure
 * formulas when working with Revenue Cloud Advanced (RCA).
 * 
 * To call this function from an IP/DM
 * 
 * FUNCTION('RCAOSUtils', <function_name>, <args>)
 * 
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * @version	1.1
 * 
 *
 * History
 * -------
 * v1.0 - May 20, 2025 - Initial version
 * v1.1 - Apr  8, 2026 - Updated to allow OS to run Invocable Actions and Flows
 */
global class RCAOSUtils implements Callable {

    // Latest Salesforce API (fetched dynamically)
    // For example: {"label":"Summer '24","url":"/services/data/v61.0","version":"61.0"}
    static Map<String, Object> SF_API = null;
    static Id STANDARD_PRICEBOOK_ID = null;

    /**
	 * Top level call by an OmniStudio DataRaptor or Integration Procedure (OmniStudio)
	 *
     * @param action  - The action/method to execute
     * @param args    - The input, output, and options arguments
     *
     * @returns true if the method completes successfully, false otherwise
     */ 
     public Object call(String action, Map<String, Object> args) {

        Map<String, Object> input = (Map<String, Object>)args.get('input');
        Map<String, Object> output = (Map<String, Object>)args.get('output');
        Map<String, Object> options = (Map<String, Object>)args.get('options');

        switch on (action.toLowerCase()) {

            when 'init' {
                return init(input, output, options);
            }
            when 'runinvocableaction' {
                return runInvocableAction(input, output, options);
            }
            when 'runflow' {
                return runFlow(input, output, options); 
            }
        }

        // If we make it here, the action was invalid
        InvalidParameterValueException e = new InvalidParameterValueException('callable', 'Invalid action: ' + action);
        throw e;
    }

    /**
     * Returns the latest API endpoint for this Salesforce instance in the form:
     *
     * {
     *   "label":"Summer '24",
     *   "url":"/services/data/v61.0",
     *   "version":"61.0"
     * }
     *
     * @return The latest Salesforce API details     
     */
    private static Map<String, Object> getAPI() {

        if (SF_API == null) {

            // Get the Salesforce Version
            HttpRequest req = new HttpRequest();
            req.setMethod('GET');
            req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/data');
            req.setHeader('Content-Type', 'application/json');
        
            Http http = new Http();
            httpResponse res = http.send(req);

            List<Object> verList = (List<Object>)JSON.deserializeUntyped(res.getBody());
            if (!verList.isEmpty()) SF_API = (Map<String, Object>)verList.get(verList.size() - 1);
        }

        return SF_API;
    }

    /**
     * Returns the Standard Price Book Id for this Salesforce instance
     *
     * @return The Standard Price Book Id
     */
    private static Id getStandardPricebookId() {

        if (STANDARD_PRICEBOOK_ID == null) STANDARD_PRICEBOOK_ID = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        return STANDARD_PRICEBOOK_ID;
    }    

    /**
     * This method returns connection related information for RCA
     *
     * The method is called by a Formula as follows:
     * 
     * FUNCTION('RCAUtils', 'init')
     *
     * @param inputMap  - The input provided by the function call
     * @param outputMap - Any output to be provided back to the DR/IP
     * @param options   - Any options to aid in the execution of the method although DR/IP doesn't provide any when calling this function
     *
     * @returns true if the method executes successfully
     */
    private Boolean init(Map<String, Object> inputMap, Map<String, Object> outputMap, Map<String, Object> options) {
    		
        outputMap.put('result', new Map<String, Object>{
            'authorization' => 'Bearer ' + UserInfo.getSessionId(),
            'baseUrl' => URL.getOrgDomainUrl().toExternalForm(),
            'apiUrl' => URL.getOrgDomainUrl().toExternalForm() + getAPI().get('url'),
            'priceBookId' => (String)getStandardPricebookId()
        });

        return true;
    }

    /**
	 * Executes an Invocable Action.  Note, not all Standard Actions can be called!
     * 
     * Use the following values should/can be included within the inputMap
     * -invocableAction = MyCoolInvocableAction
     * -type = standard or custom (defaults to standard if not provided)
	 *
     * @param inputMap  - The input provided by the function call
     * @param outputMap - Any output to be provided back to the DR/IP 
     * @param options   - Any options to aid in the execution of the method although DR/IP doesn't provide any when calling this function
     *
     * @returns true if the method completes successfully, false otherwise
     */ 
    private Boolean runInvocableAction(Map<String, Object> inputMap, Map<String, Object> outputMap, Map<String, Object> options) {

        // Get the action to run
        String invocableAction = (String)inputMap.get('invocableAction');    // Class Name of the Invocable Action
        if (invocableAction == null) {
            InvalidParameterValueException e = new InvalidParameterValueException('runInvocableAction', 'Missing "invocableAction" parameter.');
			throw e;
		}
        Boolean isCustom = inputMap.containsKey('type') ? String.valueOf(inputMap.get('type')).equalsIgnoreCase('custom') : false;

        // Create the invocable action
        Invocable.Action action;
        if (isCustom) {
            System.debug('Invoking Custom Action: ' + invocableAction);
            action = Invocable.Action.createCustomAction('apex', invocableAction);
        }
        else {
            System.debug('Invoking Standard Action: ' + invocableAction);
            action = Invocable.Action.createStandardAction(invocableAction);         
        }
        
        // Set the input parameters
        if (inputMap != null) for (String key : inputMap.keySet()) {
            if (!key.equalsIgnoreCase('invocableAction') && !key.equalsIgnoreCase('type')) action.setInvocationParameter(key, inputMap.get(key));
        }

        // Execute the action
        List<Invocable.Action.Result> results = action.invoke();

        // Set the output parameters
        for (Invocable.Action.Result result : results) {    

            // Check for Output Parameters
            Map<String, Object> outputParams = result.getOutputParameters();
            if (outputParams != null) {

                for(String key : outputParams.keySet()) {
                                        
                    Object value = outputParams.get(key);

                    // Handle null values
                    if (value == null) outputMap.put(key, null);

                    // Simple Types
                    else if (value instanceof String || value instanceof List<String> ||
                            value instanceof Integer || value instanceof List<Integer> ||
                            value instanceof Boolean || value instanceof List<Boolean> ||
                            value instanceof Double || value instanceof List<Double> ||
                            value instanceof Long || value instanceof List<Long> ||
                            value instanceof Map<String, Object>) {
                                
                        outputMap.put(key, value);
                    }
                    // Complex Types such as List<Object>.  Some objects cannot be serialized
                    else {

                        try {
                            outputMap.put(key, JSON.deserializeUntyped(JSON.serialize(value)));
                        }
                        catch (Exception e) {
                            outputMap.put(key, value.toString());
                            //outputMap.put(key, 'ignored as class ' + String.valueOf(value).split(':')[0] + ' as it is not serializable');
                        }
                    }
                }
            }

            // Check Results for any Errors
            for(Invocable.Action.Error error : result.getErrors()) outputMap.put('error', error.getCode() + ' - ' + error.getMessage());            
        }
        
        return true;
    }

    /**
	 * Executes a Flow.  Use the following input values to specify the action
     * 
     * flow = my_cool_flow - The API Name of the Flow
	 *
     * @param inputMap  - The input provided by the function call
     * @param outputMap - Any output to be provided back to the DR/IP
     * @param options   - Any options to aid in the execution of the method although DR/IP doesn't provide any when calling this function
     *
     * @returns true if the method completes successfully, false otherwise
     */ 
    private Boolean runFlow(Map<String, Object> inputMap, Map<String, Object> outputMap, Map<String, Object> options) {

        // Get the action to run
        String flowApiName = (String)inputMap.get('flow');    // API Name of the Flow
        if (flowApiName == null) throw new InvalidParameterValueException('runFlow', 'Missing "flow" input parameter.');		

        // Build the list of Output Variables from the Flow
        List<FlowDefinitionView> flowDefs = [SELECT Id, Label, ActiveVersionId FROM FlowDefinitionView WHERE ApiName = :flowAPIName AND isActive = true LIMIT 1];
        if (flowDefs.isEmpty()) throw new InvalidParameterValueException('runFlow', 'No active flow found with API name: ' + flowAPIName);

        Id activeFlowVersionId = flowDefs[0].ActiveVersionId;
        List<FlowVariableView> outputVars = [SELECT ApiName, DataType, ObjectType FROM FlowVariableView WHERE FlowVersionViewId = :activeFlowVersionId AND IsOutput = true];

        // Instantiate the Flow
        System.debug('Invoking Flow: ' + flowDefs[0].Label + ' (' + flowApiName + ') with inputs: ' + JSON.serialize(inputMap));
        Flow.Interview flowInterview = Flow.Interview.createInterview(flowApiName, inputMap);

        // Start the Flow
        // Note! This can only be used for Autolaunched and User Provisioning Flows
        flowInterview.start();
     
        for (FlowVariableView outputVar : outputVars) {

            Object value = flowInterview.getVariableValue(outputVar.ApiName);

            // Handle null values
            if (value == null) outputMap.put(outputVar.ApiName, null);

            // Simple Types
            else if (value instanceof String || value instanceof List<String> ||
                     value instanceof Integer || value instanceof List<Integer> ||
                     value instanceof Boolean || value instanceof List<Boolean> ||
                     value instanceof Double || value instanceof List<Double> ||
                     value instanceof Long || value instanceof List<Long> ||
                     value instanceof Map<String, Object>) {
                            
                outputMap.put(outputVar.ApiName, value);
            }

            // Complex Types such as List<Object>.  Some objects cannot be serialized
            else {

                try {
                    outputMap.put(outputVar.ApiName, JSON.deserializeUntyped(JSON.serialize(value)));
                }
                catch (Exception e) {
                    outputMap.put(outputVar.ApiName, value.toString());
                    //outputMap.put(outputVar.ApiName, 'ignored as class ' + String.valueOf(value).split(':')[0] + ' as it is not serializable');
                }
            }
        }

        return true;
    }


    /**
	 * Executes a Flow.  Use the following input values to specify the action
     * 
     * flow = my_cool_flow - The API Name of the Flow
	 *
     * @param inputMap  - The input provided by the function call
     * @param outputMap - Any output to be provided back to the DR/IP
     * @param options   - Any options to aid in the execution of the method although DR/IP doesn't provide any when calling this function
     *
     * @returns true if the method completes successfully, false otherwise
     */ 
    private Boolean runFlow_DELETEME(Map<String, Object> inputMap, Map<String, Object> outputMap, Map<String, Object> options) {

        // Get the action to run
        String flowApiName = (String)inputMap.get('flow');    // API Name of the Flow
        if (flowApiName == null) throw new InvalidParameterValueException('runFlow', 'Missing "flow" input parameter.');		

        // Instantiate the Flow
        System.debug('Invoking Flow: ' + flowApiName + ' with inputs: ' + JSON.serialize(inputMap));
        Flow.Interview flowInterview = Flow.Interview.createInterview(flowApiName, inputMap);

        // Start the Flow
        // Note! This can only be used for Autolaunched and User Provisioning Flows
        flowInterview.start();
     
        // When dynamically calling a Flow, there is not method to get the output variables, 
        // so we need to rely on the OmniScript to provide a list of output variables to grab
        String outputVarNames = (String)inputMap.get('outputVars');    // Comma separated list of output variable names
        if (outputVarNames != null) {

            for(String outputVar : outputVarNames.split(',')) {
                
                String key = outputVar.trim();
                Object value = flowInterview.getVariableValue(key);

                // Handle null values
                if (value == null) outputMap.put(key, null);

                // Simple Types
                else if (value instanceof String || value instanceof List<String> ||
                         value instanceof Integer || value instanceof List<Integer> ||
                         value instanceof Boolean || value instanceof List<Boolean> ||
                         value instanceof Double || value instanceof List<Double> ||
                         value instanceof Long || value instanceof List<Long> ||
                         value instanceof Map<String, Object>) {
                            
                    outputMap.put(key, value);
                }

                // Complex Types such as List<Object>.  Some objects cannot be serialized
                else {

                    try {
                        outputMap.put(key, JSON.deserializeUntyped(JSON.serialize(value)));
                    }
                    catch (Exception e) {
                        outputMap.put(key, value.toString());
                        //outputMap.put(key, 'ignored as class ' + String.valueOf(value).split(':')[0] + ' as it is not serializable');
                    }
                }
            }
        }

        return true;
    }
}