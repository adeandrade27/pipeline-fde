/**
 * Job to cleanup disputes created during the demos.
 * 
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * 
 * @version	1.0
 *
 *
 * History
 * -------
 * v1.0 - Sep  4, 2024 - Initial Version for Multiplay Demo
 * 
 */
global with sharing class Demo_CleanupDisputes extends Demo_Job implements Callable {

    /**
	 * Top level call by an OmniStudio DataRaptor or Integration Procedure (OmniStudio)
	 *
     * @param action  - The action/method to execute
     * @param args    - The input, output, and options arguments
     *
     * @returns true if the method completes successfully, false otherwise
     */ 
    public Object call(String action, Map<String, Object> args) {

        cleanupDisputes();

        return true;
    }

    /**
     * Executes the cleanup job
     * 
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) {
        
        try {

            cleanupDisputes(); 
        }
        catch (Exception e) {
            
            // Error occurred
            //DemoSystemEvent.error('Demo Cleanup', 'Error Occured during dispute cleanup -> ' + e.getMessage());
            throw e;
        }
	}

	/**
     * Cleans up any Disputes
     * 
     */
    public static void cleanupDisputes() {

        //DemoSystemEvent.info('Demo Cleanup', 'Cleaning up Disputes');

        List<Dispute> disputes = [SELECT Id, Case.Id, AccountId FROM Dispute WHERE Account.Name LIKE '% Residence'];

        List<Case> cases = new List<Case>();
        for (Dispute d : disputes) cases.add(d.Case);

        if (disputes.size() > 0) {

            Id accountId = disputes[0].AccountId;

            delete disputes;
            delete cases;
        }

        System.debug('Deleted ' + disputes.size() + ' Disputes');
        //DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + disputes.size() + ' Disputes');
    }
}