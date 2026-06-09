import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';


export default class NavToRLMSetup extends NavigationMixin( LightningElement ) 
{
    openRevenueSettings() 
    {
        console.log( 'Inside Open Revenue Settings' );
        
        const currentURL = window.location.href;
        console.log(currentURL);
        // Result written to the log files:
        // https://commscore-ido--devpro01.sandbox.lightning.force.com/lightning/page/home
        
        let RevSettings_url = currentURL.replace("page/home", "setup/RevenueSettings/home");
        console.log(RevSettings_url );

        // Double click may be needed for this approach.
        var win = window.open(RevSettings_url, '_blank');
        win.focus();

        /*
        this[ NavigationMixin.Navigate ] ( 
        {
            type:'standard__webPage',
            attributes:{url:  RevSettings_url }
        } );
         */
    } //openRevenueSettings


    //************************************************************************************* */
    openSFPricing() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let SFPricing_url = currentURL.replace("page/home", "setup/CorePricingSetup/home");
        console.log(SFPricing_url );

        // Double click may be needed for this approach.
        var win = window.open(SFPricing_url, '_blank');
        win.focus();
    } //openSFPricing



    //************************************************************************************* */
    openContextDefinitions() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let url = currentURL.replace("page/home", "setup/ContextManagementSetupNode/home");
        console.log(url );

        // Double click may be needed for this approach.
        var win = window.open(url, '_blank');
        win.focus();
    } //openContextDefinitions

    //************************************************************************************* */
    openDecisionTables() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let url = currentURL.replace("page/home", "setup/DecisionTables/home");
        console.log(url );

        // Double click may be needed for this approach.
        var win = window.open(url, '_blank');
        win.focus();
    }  //openDecisionTables



    //************************************************************************************* */
    openProductDiscovery() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let url = currentURL.replace("page/home", "setup/ProductDiscoverySettings/home");
        console.log(url );

        // Double click may be needed for this approach.
        var win = window.open(url, '_blank');
        win.focus();
    }  //openProductDiscovery




    //************************************************************************************* */
    // cmp/runtime_industries_epc__epcRuntimeCatalogWrapper
    openProductIndex() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let url = currentURL.replace("page/home", "cmp/runtime_industries_epc__epcRuntimeCatalogWrapper");
        console.log(url );

        // Double click may be needed for this approach.
        var win = window.open(url, '_blank');
        win.focus();
    }  //openProductIndex



    //************************************************************************************* */
    // https://commscore-ido.my.salesforce-setup.com/lightning/setup/PricingRecipeListAura/home
    openPricingRecipe() 
    {      
        const currentURL = window.location.href;
        console.log(currentURL);
        let url = currentURL.replace("page/home", "setup/PricingRecipeListAura/home");
        console.log(url );

        // Double click may be needed for this approach.
        var win = window.open(url, '_blank');
        win.focus();
    }  //openPricingRecipe




} // class