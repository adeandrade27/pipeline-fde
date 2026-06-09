/**
 * This class implements a simple chain of queuable Apex jobs.  
 * Each job will only be executed after the previous job has completed
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
public class Demo_JobChain {

    private List<Demo_Job> jobs;

    /**  Default Constructor */
    public Demo_JobChain() {
        jobs = new List<Demo_Job>();
    }

    /**
     * Constructor
     * 
     * @param jobs  The list of jobs to complete serially
     */
    public Demo_JobChain(List<Demo_Job> jobs) {

        this();
        if (jobs != null) {

            // Add all the jobs
            for(Demo_Job job : jobs) add(job);
        }
    }

    /**
     * Adds a job to the chain
     * 
     * @param job  The job to add
     */
    public void add(Demo_Job job) {

        // Add the job to the chain and link it to the previous job
        if (job != null) {
        
            // Link jobs
            if (!jobs.isEmpty()) jobs.get(jobs.size() - 1).setNextJob(job);

            jobs.add(job);
        }
    }

    /**
     * Starts processing the jobs
     * 
     * @return The Id for the first job, or null if there are no jobs
     */
    public Id start() {

        if (!jobs.isEmpty()) return System.enqueueJob(jobs.get(0));

        return null;
    }
}