/**
 * @description Base helper methods for Experience Cloud user registration.
 *              This class is designed to be extended by Remote Action wrapper classes.
 */
global virtual without sharing class COM_User_Registration {

    public static final List<Id> TSO_ORGS = new List<Id>{
        '00D5e0000011gdXEAQ'
    };

    global class UserRegistrationException extends Exception {}

    private class CommunityUserInput {
        String username;
        String email;
        String firstName;
        String lastName;
        String contactId;
        String accountId;
        String profileId;
        String profileName;
        String password;
    }

    /**
     * @description Creates a community user from OmniStudio-style input/output maps.
     * @param input Input map from Integration Procedure Remote Action
     * @param output Output map to return values and errors
     * @return true when operation completes successfully
     */
    protected Boolean createCommunityUserInternal(
        Map<String, Object> input,
        Map<String, Object> output
    ) {
        CommunityUserInput request = parseCommunityUserInput(input);
        validateCommunityUserInput(request);
        request.profileId = resolveProfileId(request.profileId, request.profileName);

        if (TSO_ORGS.contains(UserInfo.getOrganizationId())) {
            output.put('warning', 'User was not created because this org is marked as a Trialforce Source Org.');
            return true;
        }

        Id userId = createUserRecord(request);
        output.put('UserId', userId);
        return true;
    }

    protected CommunityUserInput parseCommunityUserInput(Map<String, Object> input) {
        Map<String, Object> safeInput = (input == null) ? new Map<String, Object>() : input;
        CommunityUserInput request = new CommunityUserInput();

        request.username = getStringValue(safeInput, 'Username');
        request.email = getStringValue(safeInput, 'Email');
        request.firstName = getStringValue(safeInput, 'FirstName');
        request.lastName = getStringValue(safeInput, 'LastName');
        request.contactId = getStringValue(safeInput, 'ContactId');
        request.accountId = getStringValue(safeInput, 'AccountId');
        request.profileId = getStringValue(safeInput, 'ProfileId');
        request.profileName = getStringValue(safeInput, 'ProfileName');
        request.password = getStringValue(safeInput, 'Password');

        return request;
    }

    protected void validateCommunityUserInput(CommunityUserInput request) {
        requireValue(request.username, 'Missing Username');
        requireValue(request.email, 'Missing Email');
        requireValue(request.firstName, 'Missing FirstName');
        requireValue(request.lastName, 'Missing LastName');
        requireValue(request.contactId, 'Missing ContactId');
        requireValue(request.accountId, 'Missing AccountId');
    }

    protected String resolveProfileId(String profileId, String profileName) {
        if (String.isNotBlank(profileName)) {
            List<Profile> profiles = [
                SELECT Id
                FROM Profile
                WHERE Name = :profileName
                LIMIT 1
            ];
            if (profiles.isEmpty()) {
                throw new UserRegistrationException('Profile "' + profileName + '" was not found.');
            }
            return profiles[0].Id;
        }

        requireValue(profileId, 'Missing ProfileId');
        return profileId;
    }

    protected Id createUserRecord(CommunityUserInput request) {
        User userRecord = new User();
        userRecord.FirstName = request.firstName;
        userRecord.LastName = request.lastName;
        userRecord.Email = request.email;
        userRecord.Alias = buildAlias(request.firstName, request.lastName);
        userRecord.Username = request.username;
        userRecord.CommunityNickname = buildCommunityNickname(request.username);
        userRecord.ContactId = request.contactId;
        userRecord.LocaleSidKey = 'en_US';
        userRecord.TimeZoneSidKey = 'GMT';
        userRecord.ProfileId = request.profileId;
        userRecord.LanguageLocaleKey = 'en_US';
        userRecord.EmailEncodingKey = 'UTF-8';
        userRecord.IsActive = true;

        if (Auth.CommunitiesUtil.isGuestUser()) {
            return Site.createExternalUser(userRecord, request.accountId, request.password, false);
        }

        insert userRecord;
        System.resetPassword(userRecord.Id, true);
        return userRecord.Id;
    }

    private static String getStringValue(Map<String, Object> source, String key) {
        Object value = source.get(key);
        return value == null ? null : String.valueOf(value);
    }

    private static void requireValue(String value, String errorMessage) {
        if (String.isBlank(value)) {
            throw new UserRegistrationException(errorMessage);
        }
    }

    private static String buildAlias(String firstName, String lastName) {
        String safeFirst = sanitizeNamePart(firstName);
        String safeLast = sanitizeNamePart(lastName);
        String aliasSeed = safeFirst.left(1) + safeLast;
        return aliasSeed.left(8);
    }

    private static String buildCommunityNickname(String username) {
        if (String.isBlank(username)) {
            return null;
        }
        Integer atIndex = username.indexOf('@');
        if (atIndex > 0) {
            return username.left(atIndex);
        }
        return username.left(Math.min(40, username.length()));
    }

    private static String sanitizeNamePart(String rawValue) {
        if (String.isBlank(rawValue)) {
            return 'x';
        }
        String cleaned = rawValue.deleteWhitespace().toLowerCase();
        return String.isBlank(cleaned) ? 'x' : cleaned;
    }
}