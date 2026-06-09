/**
 * Job to cleanup Fulfillment Relationship record data created during the demos.
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
public with sharing class Demo_CleanupFulfillmentRelationship extends Demo_Job {

    /**Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try 
        {
            cleanupFulfillmentRelationship(); 
        }
        catch (Exception e) 
        {    
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during case cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    /**Cleans up Fulfillment objects  */
    public static void cleanupFulfillmentRelationship() 
    {
		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Fulfillment Relationship data');

        // This job is being run before unwanted orders are deleted.
        // Create list of all orders that will be eventually deleted.
        List<Order>                   orders = [ SELECT Id FROM Order                    WHERE COM_SDO_Record__c = FALSE AND COM_Demo_Record__c = FALSE ];   
        List<OrderItem>           orderItems = [ SELECT Id FROM OrderItem                WHERE OrderId          IN :orders];

        // Delete Fulfillment Line Source Rel records first
        LIST<FulfillmentLineSourceRel> flsrs = [ SELECT Id FROM FulfillmentLineSourceRel WHERE SourceLineItemId IN :orderItems];
        delete flsrs;

        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + flsrs.size()   + ' Fullfillment Line Source Rel');

    }    
}