/**
 * @description This class provides helper methods to interact with the Salesforce
 * Connect API for Product Catalog Management (PCM) and Pricing.
 */
public with sharing class PcmPricingApiHelper {

    //================================================================================
    // Inner classes for the Deploy Index Request Body
    // These classes model the JSON structure for the request.
    //================================================================================
    
    public class IndexRequestPayload {
        public SnapshotPayload snapshot;
        public String buildType;

        public IndexRequestPayload(String snapshotId, String activation, String build) {
            this.snapshot = new SnapshotPayload(snapshotId, activation);
            this.buildType = build;
        }
    }

    public class SnapshotPayload {
        public String activationType;
        public String id;

        public SnapshotPayload(String snapshotId, String activation) {
            this.id = snapshotId;
            this.activationType = activation;
        }
    }

    /**
     * @description Deploys the Product Catalog Management (PCM) index for a given snapshot.
     * @param snapshotId The ID of the snapshot to use for the index deployment.
     * @return The body of the HTTP response from the server.
     * Based on endpoint: https://yourInstance.salesforce.com/services/data/v61.0/connect/pcm/index/deploy
     */
    public static String deployPcmIndex(String snapshotId) {
        if (String.isBlank(snapshotId)) {
            System.debug(LoggingLevel.ERROR, 'Snapshot ID is required for deploying the PCM index.');
            throw new AuraHandledException('Snapshot ID is required.');
        }

        // Updated endpoint for PCM index deployment. Using v61.0 as a recent stable API version.
        String endpoint = System.Url.getOrgDomainUrl().toExternalForm() +
                          '/services/data/v64.0/connect/pcm/index/deploy';

        // Construct the complex request body using the inner classes
        IndexRequestPayload payload = new IndexRequestPayload(snapshotId, 'IMMEDIATE', 'FULL');
        String requestBody = JSON.serialize(payload);

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('POST');
        request.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        request.setHeader('Content-Type', 'application/json; charset=UTF-8');
        request.setBody(requestBody);

        Http http = new Http();
        try {
            HttpResponse response = http.send(request);
            if (response.getStatusCode() >= 200 && response.getStatusCode() < 300) {
                System.debug(LoggingLevel.INFO, 'Successfully initiated PCM index deployment. Response: ' + response.getBody());
                return response.getBody();
            } else {
                System.debug(LoggingLevel.ERROR, 'Error deploying PCM index. Status Code: ' + response.getStatusCode() + '. Body: ' + response.getBody());
                throw new CalloutException(response.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'An exception occurred during PCM index deployment: ' + e.getMessage());
            throw e;
        }
    }
}