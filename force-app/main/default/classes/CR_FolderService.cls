public with sharing class CR_FolderService {

    // CR_Folder__c.Name is a standard text Name field, capped at 80 chars; the
    // legacy Folder__c text field allowed 255. Folder labels are short in practice,
    // so we cap rather than fail.
    private static final Integer NAME_MAX = 80;

    // Get-or-create a folder by label. Returns null for blank input. Used by the
    // report/dashboard save paths to mirror the legacy Folder__c text into the
    // new Folder_Ref__c lookup during the dual-write transition.
    public static Id resolveFolderId(String folderName) {
        if (String.isBlank(folderName)) {
            return null;
        }
        String trimmed = folderName.trim();
        if (trimmed.length() > NAME_MAX) {
            trimmed = trimmed.substring(0, NAME_MAX);
        }
        List<CR_Folder__c> existing = [
            SELECT Id FROM CR_Folder__c WHERE Name = :trimmed LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        CR_Folder__c folder = new CR_Folder__c(Name = trimmed);
        insert folder;
        return folder.Id;
    }

    // ---- Folders tab (crFolderManager) ----

    private static void assertManageFolders() {
        if (!FeatureManagement.checkPermission('Manage_Report_Folders')) {
            throw new AuraHandledException('You do not have permission to manage report folders.');
        }
    }

    // Lets the LWC show/hide admin controls.
    @AuraEnabled(cacheable=true)
    public static Boolean canManageFolders() {
        return FeatureManagement.checkPermission('Manage_Report_Folders');
    }

    // Browse view: every folder with content counts. Member counts are only
    // computed for folder admins (regular users lack CR_Folder_Membership__c read).
    @AuraEnabled(cacheable=true)
    public static List<FolderSummary> listFolders() {
        Map<Id, Integer> reportCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Folder_Ref__c fid, COUNT(Id) c FROM Report_Definition__c
            WHERE Folder_Ref__c != null GROUP BY Folder_Ref__c
        ]) {
            reportCounts.put((Id) ar.get('fid'), (Integer) ar.get('c'));
        }
        Map<Id, Integer> dashCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Folder_Ref__c fid, COUNT(Id) c FROM Dashboard__c
            WHERE Folder_Ref__c != null GROUP BY Folder_Ref__c
        ]) {
            dashCounts.put((Id) ar.get('fid'), (Integer) ar.get('c'));
        }
        Boolean canManage = FeatureManagement.checkPermission('Manage_Report_Folders');
        Map<Id, Integer> memberCounts = new Map<Id, Integer>();
        if (canManage) {
            for (AggregateResult ar : [
                SELECT Folder__c fid, COUNT(Id) c FROM CR_Folder_Membership__c
                WHERE Folder__c != null GROUP BY Folder__c
            ]) {
                memberCounts.put((Id) ar.get('fid'), (Integer) ar.get('c'));
            }
        }
        List<FolderSummary> out = new List<FolderSummary>();
        for (CR_Folder__c f : [
            SELECT Id, Name, Description__c, Category__c FROM CR_Folder__c ORDER BY Name ASC LIMIT 1000
        ]) {
            FolderSummary s = new FolderSummary();
            s.id = f.Id;
            s.name = f.Name;
            s.description = f.Description__c;
            s.category = f.Category__c;
            s.reportCount = reportCounts.containsKey(f.Id) ? reportCounts.get(f.Id) : 0;
            s.dashboardCount = dashCounts.containsKey(f.Id) ? dashCounts.get(f.Id) : 0;
            s.memberCount = canManage ? (memberCounts.containsKey(f.Id) ? memberCounts.get(f.Id) : 0) : null;
            out.add(s);
        }
        return out;
    }

    // The reports + dashboards inside a folder. Runs with sharing, so after the
    // OWD->Private flip a user sees only what they have access to.
    @AuraEnabled(cacheable=true)
    public static FolderContents getFolderContents(Id folderId) {
        FolderContents contents = new FolderContents();
        if (folderId == null) {
            return contents;
        }
        for (Report_Definition__c r : [
            SELECT Id, Name FROM Report_Definition__c WHERE Folder_Ref__c = :folderId ORDER BY Name ASC LIMIT 1000
        ]) {
            contents.reports.add(new AssetRef(r.Id, r.Name));
        }
        for (Dashboard__c d : [
            SELECT Id, Name FROM Dashboard__c WHERE Folder_Ref__c = :folderId ORDER BY Name ASC LIMIT 1000
        ]) {
            contents.dashboards.add(new AssetRef(d.Id, d.Name));
        }
        return contents;
    }

    @AuraEnabled
    public static List<MemberDto> listMembers(Id folderId) {
        assertManageFolders();
        List<MemberDto> out = new List<MemberDto>();
        if (folderId == null) {
            return out;
        }
        List<CR_Folder_Membership__c> rows = [
            SELECT Id, Member_Type__c, User__c, User__r.Name, Group_Id__c, Access_Level__c
            FROM CR_Folder_Membership__c WHERE Folder__c = :folderId ORDER BY CreatedDate ASC
        ];
        Set<Id> groupIds = new Set<Id>();
        for (CR_Folder_Membership__c m : rows) {
            Id gid = safeId(m.Group_Id__c);
            if (gid != null) {
                groupIds.add(gid);
            }
        }
        Map<Id, String> groupNames = new Map<Id, String>();
        if (!groupIds.isEmpty()) {
            for (Group g : [SELECT Id, Name FROM Group WHERE Id IN :groupIds]) {
                groupNames.put(g.Id, g.Name);
            }
        }
        for (CR_Folder_Membership__c m : rows) {
            MemberDto d = new MemberDto();
            d.id = m.Id;
            d.memberType = m.Member_Type__c;
            d.accessLevel = m.Access_Level__c;
            d.userId = m.User__c;
            d.userName = (m.User__r != null) ? m.User__r.Name : null;
            d.groupId = m.Group_Id__c;
            Id gid = safeId(m.Group_Id__c);
            d.groupName = (gid != null && groupNames.containsKey(gid)) ? groupNames.get(gid) : m.Group_Id__c;
            out.add(d);
        }
        return out;
    }

    // Typeahead for the "add member" picker. Returns up to 25 active users or
    // public groups whose name matches the term (all of each type when the term
    // is blank, so the admin gets an initial list on focus). We search server-side
    // because lightning-record-picker does not support the Group object at all and,
    // for User, shows nothing until the running user has a most-recently-used list.
    @AuraEnabled(cacheable=true)
    public static List<PrincipalDto> searchPrincipals(String memberType, String term) {
        assertManageFolders();
        List<PrincipalDto> out = new List<PrincipalDto>();
        String pattern = '%' + (term == null ? '' : term.trim()) + '%';
        if (memberType == 'Public Group') {
            for (Group g : [
                SELECT Id, Name, DeveloperName FROM Group
                WHERE Type = 'Regular' AND Name LIKE :pattern ORDER BY Name ASC LIMIT 25
            ]) {
                out.add(new PrincipalDto(g.Id, g.Name, g.DeveloperName));
            }
        } else {
            for (User u : [
                SELECT Id, Name, Username FROM User
                WHERE IsActive = true AND Name LIKE :pattern ORDER BY Name ASC LIMIT 25
            ]) {
                out.add(new PrincipalDto(u.Id, u.Name, u.Username));
            }
        }
        return out;
    }

    @AuraEnabled
    public static Id addMember(String payloadJson) {
        assertManageFolders();
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No member data provided.');
        }
        MemberInput input = (MemberInput) JSON.deserialize(payloadJson, MemberInput.class);
        if (String.isBlank(input.folderId)) {
            throw new AuraHandledException('Folder is required.');
        }
        CR_Folder_Membership__c m = new CR_Folder_Membership__c();
        m.Folder__c = (Id) input.folderId;
        m.Member_Type__c = String.isBlank(input.memberType) ? 'User' : input.memberType;
        m.User__c = String.isBlank(input.userId) ? null : (Id) input.userId;
        m.Group_Id__c = input.groupId;
        m.Access_Level__c = String.isBlank(input.accessLevel) ? 'Read' : input.accessLevel;
        try {
            insert m;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return m.Id;
    }

    @AuraEnabled
    public static void updateMemberAccess(Id membershipId, String accessLevel) {
        assertManageFolders();
        if (membershipId == null) {
            return;
        }
        update new CR_Folder_Membership__c(
            Id = membershipId,
            Access_Level__c = (accessLevel == 'Edit') ? 'Edit' : 'Read'
        );
    }

    @AuraEnabled
    public static void removeMember(Id membershipId) {
        assertManageFolders();
        if (membershipId == null) {
            return;
        }
        delete [SELECT Id FROM CR_Folder_Membership__c WHERE Id = :membershipId];
    }

    private static Id safeId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return (Id) value;
        } catch (Exception e) {
            return null;
        }
    }

    public class FolderSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public String category;
        @AuraEnabled public Integer reportCount;
        @AuraEnabled public Integer dashboardCount;
        @AuraEnabled public Integer memberCount;
    }

    public class AssetRef {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        public AssetRef(Id id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public class FolderContents {
        @AuraEnabled public List<AssetRef> reports = new List<AssetRef>();
        @AuraEnabled public List<AssetRef> dashboards = new List<AssetRef>();
    }

    public class MemberDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String memberType;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public String accessLevel;
    }

    public class PrincipalDto {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String secondary;
        public PrincipalDto(Id id, String name, String secondary) {
            this.id = id;
            this.name = name;
            this.secondary = secondary;
        }
    }

    public class MemberInput {
        public String folderId;
        public String memberType;
        public String userId;
        public String groupId;
        public String accessLevel;
    }
}