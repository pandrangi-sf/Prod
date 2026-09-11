public with sharing class CR_GroupResolver {

    @TestVisible private static Integer maxUsers = 1000;
    @TestVisible private static Integer maxDepth = 6;

    // Resolve subscription recipient rows (User / Public Group / Email) into a
    // deduped, sorted list of email addresses. Public Groups are expanded to
    // their member users (recursively through nested groups/roles); only active
    // users with an email are included.
    public static List<String> resolveEmails(List<CR_Subscription_Recipient__c> recipients) {
        Set<String> emails = new Set<String>();
        Set<Id> userIds = new Set<Id>();
        Set<Id> groupIds = new Set<Id>();

        for (CR_Subscription_Recipient__c r : recipients) {
            String type = String.isBlank(r.Recipient_Type__c) ? 'User' : r.Recipient_Type__c;
            if (type == 'Email' && String.isNotBlank(r.Email__c)) {
                emails.add(r.Email__c);
            } else if (type == 'Public Group' && String.isNotBlank(r.Group_Id__c)) {
                try {
                    groupIds.add((Id) r.Group_Id__c);
                } catch (Exception e) {
                    // malformed id — skip silently
                }
            } else if (r.User__c != null) {
                userIds.add(r.User__c);
            } else if (String.isNotBlank(r.Email__c)) {
                emails.add(r.Email__c);
            }
        }

        if (!groupIds.isEmpty()) {
            userIds.addAll(expandGroups(groupIds));
        }
        if (!userIds.isEmpty()) {
            for (User u : [SELECT Email FROM User WHERE Id IN :userIds AND IsActive = true AND Email != null LIMIT 1000]) {
                emails.add(u.Email);
            }
        }

        List<String> result = new List<String>(emails);
        result.sort();
        return result;
    }

    // Breadth-first expansion of public groups to user ids, bounded by depth and
    // total users so a huge/nested group can't blow limits.
    private static Set<Id> expandGroups(Set<Id> groupIds) {
        Set<Id> users = new Set<Id>();
        Set<Id> toProcess = new Set<Id>(groupIds);
        Set<Id> processed = new Set<Id>();
        Integer depth = 0;

        while (!toProcess.isEmpty() && depth < maxDepth && users.size() < maxUsers) {
            Set<Id> nextGroups = new Set<Id>();
            for (GroupMember gm : [SELECT UserOrGroupId FROM GroupMember WHERE GroupId IN :toProcess]) {
                Id memberId = gm.UserOrGroupId;
                String prefix = String.valueOf(memberId).substring(0, 3);
                if (prefix == '005') {
                    users.add(memberId);
                } else if (!processed.contains(memberId)) {
                    nextGroups.add(memberId);
                }
            }
            processed.addAll(toProcess);
            toProcess = nextGroups;
            depth++;
        }
        return users;
    }
}