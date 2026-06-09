/**
 * Handy utility for generating demo admin platform events
 *  
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * @version	1.3
 *
 *
 * History
 * -------
 * v1.0 - Aug 19, 2021 - Initial Version
 * v1.1 - Oct  4, 2021 - Exposed info() and error() methods so they can be called from an LWC
 * v1.2 - Jan  4, 2022 - Added a more accurate Timestamp to each event
 * v1.3 - Jul  7, 2023 - Added warn() method
 *
 */
public with sharing class DemoSystemEvent {

    /**
     * Creates and sends a demo system event
     * 
     * @param type     The event type
     * @param severity The severity (Info, Error, etc.)
     * @param message  The message to send
     */
    private static void send(String type, String severity, String message) {

        // Create the event
        Demo_System_Event__e event = new Demo_System_Event__e();
        event.Timestamp__c = DateTime.now().formatGMT('yyyy-MM-dd\'T\'HH:mm:ss.SSSZ');  // Need accurate timestamp for receivers to properly order events, PE CreatedDate insufficient
        event.Type__c      = type;
        event.Severity__c  = severity;
        event.Message__c   = message;

        List<Demo_System_Event__e> events = new List<Demo_System_Event__e>();
        events.add(event);
        
        // Transmit the Event
        List<Database.SaveResult> results = EventBus.publish(events);        
    }

    /**
     * Creates and sends an informational demo system event
     * 
     * @param type     The event type
     * @param message  The message to send
     */
    @AuraEnabled
    public static void info(String type, String message) {

        System.debug(LoggingLevel.INFO, type + ' - ' + message);
        send(type, 'Info', message);
    }

    /**
     * Creates and sends a warning demo system event
     * 
     * @param type     The event type
     * @param message  The message to send
     */
    @AuraEnabled    
    public static void warn(String type, String message) {

        System.debug(LoggingLevel.WARN, type + ' - ' + message);
        send(type, 'Warning', message);
    }

    /**
     * Creates and sends an error demo system event
     * 
     * @param type     The event type
     * @param message  The message to send
     */
    @AuraEnabled    
    public static void error(String type, String message) {

        System.debug(LoggingLevel.ERROR, type + ' - ' + message);
        send(type, 'Error', message);
    }
}