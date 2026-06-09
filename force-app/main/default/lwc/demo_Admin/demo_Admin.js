import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
/*
import setupJob from '@salesforce/apex/Demo_Setup.setup';
import getOmniScripts from '@salesforce/apex/DemoOmniStudioUtils.getOmniScripts';
import getOmniScript from '@salesforce/apex/DemoOmniStudioUtils.getOmniScript';
import activateOmniScript from '@salesforce/apex/DemoOmniStudioUtils.activate';
import deactivateOmniScript from '@salesforce/apex/DemoOmniStudioUtils.deactivate';*/
import cleanupJob from '@salesforce/apex/Demo_Cleanup.cleanup';
import optimizeJob from '@salesforce/apex/Demo_Cleanup.optimize';
import publishInfoEvent from '@salesforce/apex/DemoSystemEvent.info';
import publishErrorEvent from '@salesforce/apex/DemoSystemEvent.error';

export default class demo_Admin extends LightningElement 
{

    @api buttonsDisabled = false;
    @track optimizeButtonVisible = false;

    // Modal
    @track lwcOmniScripts = [];
    @track lwcOsUrl = null;

    // Timer Jobs
    jobMonitor;

    /**
     * Initialize the component
     * 
     */


    /**
     * Shows an error toast message
     * 
     * @param error  The error message to display
     */
    showError(error) {

        console.error("Job Error -> " + JSON.stringify(error));

        let errorMsg = "";
        if (error.body && error.body.exceptionType) errorMsg += error.body.exceptionType + ": ";
        if (error.body && error.body.pageErrors && error.body.pageErrors[0].message) errorMsg += error.body.pageErrors[0].message;
        
        const toast = new ShowToastEvent({
            title: "Error",
            message: errorMsg,
            variant: 'error',
            mode: 'dismissable'
        });
        this.dispatchEvent(toast);
    }





    /*** Performs the Cleanup Operation     */
    cleanup() 
    {
        try {
            // Disable the button until the job completes
            console.log("Starting Cleanup Job");
            this.buttonsDisabled = true;

            cleanupJob()
                .then(result => {
                    console.log("Cleanup Job Complete");
                })
                .catch(error => {
                    this.showError(error);
                })
                .finally(() => {
                    this.buttonsDisabled = false;
                });
        } catch (err) {
            console.error("Error running cleanup job -> " + err);
        }
    }

    /**
     * Monitors one or more batch jobs for completion/errors
     * 
     * @param start_time  Approximately when the jobs were started
     * @param jobList     The list of Apex queueable/batch job names to monitor
     * @param nextTask    An optional next function to run
     */
    monitorJobs(start_time, jobList, nextTask) {

        try {

            console.log("Monitoring Jobs " + JSON.stringify(jobList) + " since " + start_time);

            monitorApexJobs({start_time, jobList})
                .then(result => {

                    console.log(result);
                    if (result.isComplete) {
                    
                        // Stop monitoring
                        clearInterval(this.monitorJob);

                        // Trigger next task if necessary
                        if (nextTask) nextTask(this);
                    }
                })
                .catch(error => {
                    this.showError(error);
                    clearInterval(this.monitorJob);
                });

        } catch (err) {
            console.error("Error running cache monitor -> " + err);
            clearInterval(this.monitorJob);
        }
    }

    /**
     * Monitors an asynchronous process for completion/errors
     *      
     * @param jobId     The Async Job to monitor
     * @param nextTask  An optional next function to run
     */
    monitorAsyncJob(jobId, nextTask) {

        try {

            console.log("Monitoring Async Process " + jobId);

            monitorAsyncProcess({asyncId: jobId})
                .then(result => {

                    console.log(result);
                    if (result.isComplete) {
                    
                        // Stop monitoring
                        clearInterval(this.monitorJob);

                        // Trigger next task if necessary
                        if (nextTask) nextTask(this);
                    }
                })
                .catch(error => {
                    this.showError(error);
                    clearInterval(this.monitorJob);
                });

        } catch (err) {
            console.error("Error monitoring async process -> " + err);
            clearInterval(this.monitorJob);
        }
    }

 


}