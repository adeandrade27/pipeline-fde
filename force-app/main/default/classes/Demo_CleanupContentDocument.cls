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
public with sharing class Demo_CleanupContentDocument extends Demo_Job {

    /** Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try {  cleanupContentDocuments();         }
        catch (Exception e) {
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during content document cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    public static void cleanupContentDocuments() {

		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up PDF content documents');

        // List of assets to be deted.
        List <ContentDocument> contentdocs = [SELECT Id FROM ContentDocument where FileType = 'PDF'];

        // Delete
        delete contentdocs;
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + contentdocs.size() + ' Content Document PDFs');
    }
}