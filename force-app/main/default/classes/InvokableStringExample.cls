public with sharing class InvokableStringExample 
{
     @InvocableMethod(label='Get Welcome Message' 
                     description='Returns a welcome message string'
                     category='Utility')
    public static List<Result> getWelcomeMessage(List<Request> requests) {
        List<Result> results = new List<Result>();
        
        for (Request req : requests) {
            Result result = new Result();
            result.message = 'Hello ' +  '! Welcome to Salesforce.';
            // result.message = 'Hello ' + req.name + '! Welcome to Salesforce.';
            results.add(result);
        }
        
        return results;
    }
    
    public class Request {
        @InvocableVariable(label='Name' description='The name to include in the message' required=false)
        public String name;
    }
    
    public class Result {
        @InvocableVariable(label='Welcome Message' description='The generated welcome message')
        public String message;
    }







} // publi class