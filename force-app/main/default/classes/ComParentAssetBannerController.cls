public with sharing class ComParentAssetBannerController {
    public class BannerState {
        @AuraEnabled public Boolean hasParent { get; set; }
        @AuraEnabled public Id parentAccountId { get; set; }
        @AuraEnabled public String parentAccountName { get; set; }
        @AuraEnabled public Boolean hasRelatedParentAssets { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static BannerState getBannerState(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('An Account Id is required.');
        }

        Account currentAccount = [
            SELECT Id, ParentId, Parent.Name
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        BannerState state = new BannerState();
        state.hasParent = currentAccount.ParentId != null;

        if (!state.hasParent) {
            state.parentAccountId = null;
            state.parentAccountName = null;
            state.hasRelatedParentAssets = false;
            state.message = 'account has no parent';
            return state;
        }

        state.parentAccountId = currentAccount.ParentId;
        state.parentAccountName = currentAccount.Parent.Name;

        Integer relatedAssetCount = [
            SELECT COUNT()
            FROM Asset
            WHERE AccountId = :currentAccount.ParentId
            AND CurrentServiceAccountId = :currentAccount.Id
        ];

        state.hasRelatedParentAssets = relatedAssetCount > 0;
        if (state.hasRelatedParentAssets) {
            state.message = 'Parent account ' + state.parentAccountName + ' owns assets for this Service Account';
        } else {
            state.message = 'There are no related assets on the parent account ' + state.parentAccountName;
        }

        return state;
    }
}