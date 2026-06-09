/**
 * Job to cleanup contracts created during the demos.
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
 * v1.1 - Mar 4, 2025 - Comms IDO+ / RLM orgs
 * 
 */
public with sharing class Demo_CleanupContracts extends Demo_Job {

    /**
     * Executes the cleanup job
     * 
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) {
        
        try 
        {
            cleanupDraftContracts(); 
        }
        catch (Exception e) 
        {
            // Error occurred
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during contract cleanup -> ' + e.getMessage());
            throw e;
        }
	}

	/**
     * Cleans up Contracts with draft status and Demo Persistent=false
	 * Not necessarily needed for B2C, but it's here just in case
     */
    public static void cleanupDraftContracts() 
    {
		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Contracts');

        // List of contracts to be deleted.
        List<Contract> contractIds = [ SELECT Id FROM Contract WHERE Status = 'Draft' AND COM_Demo_Record__c = false AND COM_SDO_Record__c = false ];

        // List of Contract Document Versions to be deleted
        List<ContractDocumentVersion> versionIds = [SELECT Id FROM ContractDocumentVersion where ContractId in :contractIds];

        // List of ContractDocVerContentDoc to delete.
        List<ContractDocVerContentDoc> contentDocIds = [SELECT Id FROM ContractDocVerContentDoc WHERE ContractDocumentVersionId in :versionIds ];
        
        delete contentDocIds;
        delete versionIds;
        delete contractIds;  

        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + contentDocIds.size() + ' Contract Doc Ver Content Doc');
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + versionIds.size() + ' Contract Document versions');
		DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + contractIds.size() + ' Draft Contracts');
	}
}