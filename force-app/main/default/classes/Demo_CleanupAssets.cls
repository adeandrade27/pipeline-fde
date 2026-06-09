/**
 * Job to cleanup assets created during the demos.
 * 
 * @author	Lars Helgeson (lars.helgeson@salesforce.com)
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * @author  Justin Harris (justin.harris@salesforce.com)
 * 
 * @version	1.1
 *
 * History
 * -------
 * v1.0 - Jan  3, 2022 - Initial Version for Multiplay Demo
 * v1.1 - Jan 23, 2025 - Updated for Comms IDO Plus demo org
 */
public with sharing class Demo_CleanupAssets extends Demo_Job {

    /** Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try {  cleanupAssets();         }
        catch (Exception e) {
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during asset cleanup -> ' + e.getMessage());
            throw e;
        }
	}

	/**Cleans up Assets with  COM_Demo_Record__c = FALSE AND COM_SDO_Record__c = False */
    public static void cleanupAssets() {

		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Assets');

        // List of assets to be deted.
        List <Asset>          assets = [SELECT Id FROM Asset  WHERE COM_Demo_Record__c = FALSE AND COM_SDO_Record__c = False];

        // List of asset relationships related to assets being deleted.
        List <AssetRelationship> assetRelationships = [Select Id FROM AssetRelationship WHERE RelatedAssetId IN :assets ];

        // Delete
        delete assetRelationships;
        delete assets;

        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + assetRelationships.size() + ' Asset Relationships');
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + assets.size() + ' Assets');

        /*
        List<AssetRelationship> assetRelationships = new List<AssetRelationship>();
        for(AssetRelationship rel : [SELECT Id, Asset.Demo_Persistent__c, RelatedAsset.Demo_Persistent__c FROM AssetRelationship]) {
            if (!rel.Asset.Demo_Persistent__c && !rel.RelatedAsset.Demo_Persistent__c) assetRelationships.add(rel);
        }
        if (!assetRelationships.isEmpty()) {
            delete assetRelationships;
            DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + assetRelationships.size() + ' Asset Relationships');
        }

        List<Asset> assets = [SELECT Id, Product2.Name FROM Asset WHERE Demo_Persistent__c = false];
        delete assets;

        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + assets.size() + ' Assets');*/
    }
}