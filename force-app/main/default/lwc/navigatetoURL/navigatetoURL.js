import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class sampleLightningWebComponent extends NavigationMixin( LightningElement ) {
     
    openWebPage() {

        console.log( 'Inside Open Web Page' );
        this[ NavigationMixin.Navigate ] ( {
            type:'standard__webPage',
            attributes:{
                url: 'https://www.salesforce.com/'
            }

        } );
    }

}