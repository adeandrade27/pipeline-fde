import { LightningElement, api } from "lwc";

export default class ComServiceAvailable extends LightningElement {
    @api headline = "Great News!";
    @api messagePrefix = "We have speeds up to ";
    @api serviceSpeed = "500 Mbps";
    @api messageSuffix = " at your location.";
}