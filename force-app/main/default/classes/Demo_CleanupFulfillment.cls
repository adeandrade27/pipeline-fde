/**
 * Job to cleanup Fulfillment data created during the demos.
 * 
 * @author	Lars Helgeson (lars.helgeson@salesforce.com)
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * @author  Justin Harris (justin.harris@salesforce.com)
 * 
 * @version	1.1
 *
 *
 * History
 * -------
 * v1.0 - Jan  3, 2022 - Initial Version for Multiplay Demo
 * v1.1 - Jan 23, 2025 - Updated for Comms IDO Plus demo org
 * 
 */
public with sharing class Demo_CleanupFulfillment extends Demo_Job {

    /**Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try 
        {
            cleanupFulfillment(); 
        }
        catch (Exception e) 
        {    
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during case cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    /**Cleans up Fulfillment objects  */
    public static void cleanupFulfillment() 
    {
		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Fulfillment data');

        // **************************************************************************************************************
        // 2025-05-27.
        // To delete fulfillment assets, its first necessary to delete related record(s) from AssetFulfillmentDecomp.
        List<FulfillmentAsset>           fAssets = [ SELECT Id FROM FulfillmentAsset ];

        // **************************************************************************************************************
        // Delete fulfillment assets. 
        // AssetFulfillmentDecomp
        List<AssetFulfillmentDecomp>    fDecomp = [SELECT Id FROM AssetFulfillmentDecomp WHERE FulfillmentTargetAssetId IN :fAssets];
        delete fDecomp;
        delete fAssets;


 

       

         // **************************************************************************************************************
        // Delete Fulfillment Plans. 


        // Unwanted orders are deleted before this job is executed.
        // Do NOT delete from FulfillmentPlan if Source Identifier(aka Order id) is in the list of orders.

        // 2025-05-27
        // List<Order> : All remaining orders are ones to keep
        List<Order>                   orders = [ SELECT Id FROM Order ];
        Set<Id> orderIds = new Set<Id>();
        for (Order o : orders) {
            orderIds.add(o.Id);
        }

        List<FulfillmentPlan>         fplans = [ SELECT Id FROM FulfillmentPlan          WHERE SourceIdentifier     NOT IN :orderIds];
        delete fplans;
      

        // Create list of Fulfillment Orders and Fulfillment Order Line Items to be deleted.    
        //List<FulfillmentOrder>       forders = [SELECT Id FROM FulfillmentOrder         WHERE OrderId                NOT IN :orders];
        //List<FulfillmentOrderLineItem> forli = [Select Id FROM FulfillmentOrderLineItem WHERE FulfillmentOrderId     IN :forders];
        //delete forli;
        //delete forders;

        // **************************************************************************************************************
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + fplans.size()  + ' Fullfillment Plans');
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + fAssets.size() + ' Fullfillment Assets');
        //DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + forli.size()   + ' Fullfillment Order Line Items');
        //DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + forders.size() + ' Fullfillment Orders');
    }    
}