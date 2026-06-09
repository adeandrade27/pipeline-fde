/**
 * Job to cleanup cases created during the demos.
 * 
 * @author	Lars Helgeson (lars.helgeson@salesforce.com)
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * 
 * @version	1.0
 *
 *
 * History
 * -------
 * v1.0 - Jan  3, 2022 - Initial Version for Multiplay Demo
 * 
 */
public with sharing class Demo_CleanupCases extends Demo_Job {

    /**
     * Executes the cleanup job
     * 
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) {
        
        try {

            cleanupCases(); 
        }
        catch (Exception e) {
            
            // Error occurred
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during case cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    /**
     * Cleans up Cases with  Demo Persistent=false
     * 
     */
    public static void cleanupCases() {

		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Cases');

        List<Case> cases = [SELECT Id FROM Case WHERE COM_Demo_Record__c = false];
        delete cases;
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + cases.size() + ' Cases');
    }    
}