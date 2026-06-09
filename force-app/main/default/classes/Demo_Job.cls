/**
 * This class represents a Chainable (Queueable) Apex job, that can run a subsequent job after
 * it completes.
 * 
 * @author	Joe McMaster (joe.mcmaster@salesforce.com)
 * 
 * @version	1.0
 *
 *
 * History
 * -------
 * v1.0 - Oct  7, 2021 - Initial Version for Multiplay Demo
 * 
 */
public abstract class Demo_Job implements Queueable, Finalizer {
    
    private Demo_Job nextJob;

    /**
     * Default Constructor
     * 
     */
    public Demo_Job() {
        nextJob = null;
    }

    /**
     * Sets the subsequent job that should be run once this job completes
     * 
     * @param nextJob The next job that should be run after this one
     */
    public void setNextJob(Demo_Job nextJob) {

        this.nextJob = nextJob;
    }

    /**
     * Executes this job.  Sub-classes should implement this method
     * 
     * @param context  The Queueable context 
     */
    public abstract void executeJob(QueueableContext context);

    /**
     * Begins execution of this job.  This method sets up the finalizer (next job) and
     * then executes this job
     * 
     * @param context  The Queueable context
     */
    public void execute(QueueableContext context) {

        // Attach finalizer which will run next job once this job has completed
        System.attachFinalizer(this);
        
        // Now run this job
        executeJob(context);
    }

    /**
     * Executes once this job has completed.  
     * If an error has occurred, any subsequent jobs will not be enqueued for execution.
     * 
     * @param context  The finalizer context
     */
    public void execute(FinalizerContext context) {

        // Check for failures
        switch on context.getResult() {
      
            // Success
            when SUCCESS {
        
                if (nextJob != null) System.enqueueJob(nextJob);
            }
            // Failure
            when UNHANDLED_EXCEPTION {
                
                System.Debug(LoggingLevel.ERROR, 'Job ID: ' + context.getAsyncApexJobId() + '): FAILED! with error: ' + context.getException());
            }
        }

    }
}