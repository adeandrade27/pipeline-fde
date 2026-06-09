public class QuoteRecipientHelper 
{
    
    public static void performBeforeInsertLogic(List<QuoteLineItemRecipient> newQuoteRecipients) 
    {
    
        for (QuoteLineItemRecipient obj : newQuoteRecipients) 
        {
            switch on obj.ServicePostalCode.substring(0,1) {
                            
                when '6', '7' {
                    obj.MaxDownloadSpeed = '250 Mbps';
                    obj.MaxUploadSpeed = '125 Mbps';
                    obj.BroadbandConnectionType = 'Copper';
                }
                
                when '8' {
                    obj.BroadbandConnectionType = 'Near-Net';
                }
                
                when '9' {
                    obj.BroadbandConnectionType = 'Off-Net';
                }
                
                when else {
                    obj.MaxDownloadSpeed = '1 Gbps';
                    obj.MaxUploadSpeed = '1 Gbps';
                    obj.BroadbandConnectionType = 'Fiber';                
                }
            }
        }
    }
}