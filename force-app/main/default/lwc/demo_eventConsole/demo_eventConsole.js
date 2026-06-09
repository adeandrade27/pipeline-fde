/*
  This custom LWC listens for Platform Events and populates each event in a table.
  
  @author Joe McMaster
  @version 1.1
    
  History
  =======
  Jul 15, 2021 - v1.0 - Initial version created for the Multiplay Demo
  Jan  4, 2022 - v1.1 - Implemented event sorting
  
*/
import { LightningElement, api } from 'lwc';
import { subscribe, unsubscribe, onError, setDebugFlag, isEmpEnabled } from 'lightning/empApi';

export default class demo_eventConsole extends LightningElement {

    // Default System Event Channel
    @api channelName = '/event/Demo_System_Event__e';

    @api keyField = "id";

    @api rows = [];

    @api
    columns = [
        {
            label: 'Timestamp',
            fieldName: 'timestamp',
            type: 'date',
            typeAttributes: {
                year: 'numeric',
                month: 'numeric',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit'
            },
            cellAttributes: {
                alignment: 'center'
            },
            hideDefaultActions: true,
            wrapText: true,
            initialWidth: 175
        },
        {
            label: 'Severity',
            fieldName: 'severity',
            hideDefaultActions: true,
            wrapText: true,
            initialWidth: 85,
            cellAttributes: {
                alignment: 'center'
            }
        },
        {
            label: 'Event Type',
            fieldName: 'type',
            hideDefaultActions: true,
            wrapText: true,
            initialWidth: 150,
            cellAttributes: {
                alignment: 'center'
            }
        },
        {
            label: 'Message',
            fieldName: 'message',
            hideDefaultActions: true,
            wrapText: true,
            initialWidth: 750
        }
    ];

    // Channel Subscription Object
    subscription = {};

    /**
     * LWC Lifecycle hook called when this component is added to the DOM.
     * We will initialize the platform event subscription and error handler
     * at this stage.
     */
    connectedCallback() {

        // Register Error Listener       
        this.registerErrorListener();

        // Subscribe to the demo event channel
        this.handleSubscribe();
    }

    /**
     * LWC Lifecycle hook called when this component is removed from the DOM.
     * We will terminate the event subscription at this stage.
     */
    disconnectedCallback() {

        // Unsubscribe
        unsubscribe(this.subscription, response => {
            console.log('Disconnecting from Demo Event Channel: ', JSON.stringify(response));
        });
    }

    /**
     * Establishes the platform event subscription and message handler
     * 
     */
    handleSubscribe() {

        // Bind class instance so we can use it in the event handler
        const self = this;
        const messageCallback = function (response) {

            try {

                let payload = response.data.payload;
                console.log(payload.Type__c + " Event (" + payload.Timestamp__c + ") - > " + payload.Severity__c + " - " + payload.Message__c);
                let msg = {
                    id: response.data.event.replayId,
                    timestamp: payload.Timestamp__c,
                    type: payload.Type__c,
                    severity: payload.Severity__c,
                    message: payload.Message__c
                };

                self.rows = [...self.rows, msg];

                // Sort by timestamp
                self.rows.sort((a, b) => {

                    let atime = Date.parse(a.timestamp);
                    let btime = Date.parse(b.timestamp);

                    if (atime < btime) return -1;
                    else if (atime > btime) return 1;
                    return 0;
                });

            } catch (err) {
                console.error("Error receiving demo event - > " + err);
            }
        };

        // Make sure we can use CometD here
        isEmpEnabled().then(empEnabled => {

            if (empEnabled) {

                // Enable debugging
                setDebugFlag(false);

                // Invoke subscribe method of empApi. Pass reference to messageCallback
                subscribe(this.channelName, -1, messageCallback).then(response => {

                    // Response contains the subscription information on subscribe call
                    console.log("Connected to Demo Event Channel: " + this.channelName);
                    this.subscription = response;
                });
            }
            else console.error("EmpJs Streaming API library cannot be used");
        });
    }

    /**
     * Registers an error listener
     * 
     */
    registerErrorListener() {

        // Handle Errors
        onError(error => {

            console.error('Received error from server: ', JSON.stringify(error));

            // JOE - The following check determines if the connection needs to be re-initialized
            //       This isn't working in the B2C demo            
            if ("advice" in error && "reconnect" in error.advice && error.advice.reconnect == "handshake") {
                
                console.error("JOE need to reconnect!");
                console.log("Callback = " + messageCallback);

                /*subscribe(this.channelName, -1, messageCallback).then(response => {

                    // Response contains the subscription information on subscribe call
                    console.log("Connected to Demo Event Channel: " + this.channelName);
                    this.subscription = response;
                });*/
            }
        });
    }

    /**
     * Removes all existing events in the table
     * 
     */
    clearTable() {

        this.rows = [];
    }
}