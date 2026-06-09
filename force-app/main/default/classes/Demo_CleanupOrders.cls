/**
 * Job to cleanup orders created during the demos.
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
 * v1.1 - Jan 24, 2025 - Updated for Comms IDO+
 * 
 */
public with sharing class Demo_CleanupOrders extends Demo_Job {

    /** Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try   {cleanupOrders(); }
        catch (Exception e) 
        {
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during order cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    /** Cleans up Orders with Draft and Activated status and Demo Persistent=false*/
    public static void cleanupOrders() 
    {
		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Orders');

		// Get list of draft Orders to delete
        List<Order> draftOrders = [ SELECT Id FROM Order WHERE Status = 'Draft' AND COM_SDO_Record__c = FALSE AND COM_Demo_Record__c = FALSE ];
        delete draftOrders;    
		DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + draftOrders.size() +	' Draft Orders');

		// Get list of activated orders
        // At this point, all draft orders have already been deleeted.
        // Comms IDO+ has 2 custom statuses for Order:  Submitted and Exception.
        // Since we've delted all draft orders, there should be no activated orders.
        // Don't need to filter based on Status.
        Order[] activatedOrders = [	SELECT Id FROM Order WHERE COM_SDO_Record__c = FALSE AND COM_Demo_Record__c = FALSE ];
        
        // Update statuses to Draft
        for (Order order : activatedOrders) order.Status = 'Draft';
        update activatedOrders;

		// Delete orders
        delete activatedOrders;    
	
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + activatedOrders.size() + ' Activated Orders');
    }    
}