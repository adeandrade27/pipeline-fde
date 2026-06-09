public with sharing class COM_GetReleaseVersion 
{
    
    @InvocableMethod(label='COM Get Release Version' 
                     description='Returns version number of org'
                     category='Utility')


    public static List<String> getRelease(List<InputRequest> requests) 
    {
        List<String> results = new List<String>();

        String getListEndpoint = System.Url.getOrgDomainUrl().toExternalForm() + '/releaseVersion.jsp';
        HttpRequest getRequest = new HttpRequest();
        getRequest.setEndpoint(getListEndpoint);
        getRequest.setMethod ('GET' );
        getRequest.setHeader ('Authorization', 'Bearer ' + UserInfo.getSessionId());
        Http http = new Http();
        HttpResponse getResponse = http.send (getRequest);
        String responseBody = getResponse.getBody();



        // Example 2: Extract using substring (if you know the pattern)
        Integer startIndex = responseBody.indexOf('ReleaseName') +12;
        Integer endIndex = responseBody.indexOf('<', startIndex);
        String token = responseBody.substring(startIndex, endIndex);
        System.debug('Extracted Token: ' + token);
            

        results.add(token);
        return results;
    } // public getRelease
    
    public class InputRequest 
    {
        @InvocableVariable(label='blank' description='No input required' required=false)
        public String name;
    } // class InputRequest
}