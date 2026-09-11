public with sharing class CR_HelpService {
    public class HelpSection {
        @AuraEnabled public String heading { get; set; }
        @AuraEnabled public String body { get; set; }
        @AuraEnabled public String iconName { get; set; }
        @AuraEnabled public Decimal sectionOrder { get; set; }
    }

    // Cacheable so the panel re-opens instantly after the first fetch in a
    // session. Help content rarely changes; if a record IS edited the page
    // refresh path picks it up via cache invalidation on the LWC side.
    @AuraEnabled(cacheable=true)
    public static List<HelpSection> getHelpForTool(String toolKey) {
        List<HelpSection> sections = new List<HelpSection>();
        if (String.isBlank(toolKey)) {
            return sections;
        }
        // Role-aware help: admins (Vital Reports Admin View) see All + Admin
        // topics; everyone else sees All + User topics. A blank audience is
        // treated as All for backward compatibility with pre-existing topics.
        Boolean isAdmin = FeatureManagement.checkPermission('Vital_Reports_Admin_View');
        for (CR_Help_Topic__mdt topic : [
            SELECT Heading__c, Body__c, Icon_Name__c, Section_Order__c, Audience__c
            FROM CR_Help_Topic__mdt
            WHERE Tool_Key__c = :toolKey
            ORDER BY Section_Order__c NULLS LAST, Heading__c
        ]) {
            String audience = String.isBlank(topic.Audience__c) ? 'All' : topic.Audience__c;
            Boolean visible = audience == 'All'
                || (audience == 'Admin' && isAdmin)
                || (audience == 'User' && !isAdmin);
            if (!visible) {
                continue;
            }
            HelpSection s = new HelpSection();
            s.heading = topic.Heading__c;
            s.body = topic.Body__c;
            s.iconName = String.isBlank(topic.Icon_Name__c) ? 'utility:info' : topic.Icon_Name__c;
            s.sectionOrder = topic.Section_Order__c;
            sections.add(s);
        }
        return sections;
    }
}