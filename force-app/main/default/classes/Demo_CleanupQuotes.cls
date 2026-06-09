/**
 * Job to cleanup Quotes created during the demos.
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
public with sharing class Demo_CleanupQuotes  extends Demo_Job {

    /**Executes the cleanup job
     * @param context  The Queueable Context
     */
    public override void executeJob(QueueableContext context) 
    {
        try 
        {
            cleanupQuotes (); 
        }
        catch (Exception e) 
        {    
            DemoSystemEvent.error('Demo Cleanup', 'Error Occured during case cleanup -> ' + e.getMessage());
            throw e;
        }
	}

    /**Cleans up Quotes  with  Demo Persistent=false   */
    public static void cleanupQuotes () 
    {
		DemoSystemEvent.info('Demo Cleanup', 'Cleaning up non-persistent Quotes ');

        // List of quotes to delete.
        List<Quote> quotes = [SELECT Id FROM Quote WHERE COM_SDO_Record__c = FALSE AND COM_Demo_Record__c = FALSE];

        // List Quote Line Items for the quotes being deleted.
        List<QuoteLineItem> qli = [SELECT Id FROM QuoteLineItem WHERE QuoteId IN :quotes];
        delete qli;
        
        delete quotes;
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + qli.size() +     ' Quote Line Items');
        DemoSystemEvent.info('Demo Cleanup', 'Deleted ' + quotes.size() + ' Quotes');
    }    
}