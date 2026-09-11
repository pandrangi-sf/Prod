/**
 * Apex managed sharing driven by folder membership. For every report/dashboard
 * whose Folder_Ref__c points at a folder, each CR_Folder_Membership__c grants the
 * member (user or public group) a Read or Edit share.
 *
 * Shares use RowCause = 'Manual' (the default for custom-object shares). A custom
 * Apex sharing reason would be cleaner — it would let us distinguish folder shares
 * from hand-created ones — but the SharingReason metadata would not deploy in this
 * org, so we use Manual and scope deletes to the records we manage. These objects
 * expose no Share button, so collisions with genuine manual shares are not expected.
 *
 * Runs `without sharing` so it can recompute shares regardless of which user's DML
 * triggered it. Inserts use allOrNone=false on purpose: while OWD is Public Read
 * Only, Read shares are rejected by the platform (they don't exceed the org default)
 * and simply no-op; they become meaningful — and succeed — only after the gated
 * OWD->Private flip, at which point recomputeAll() (or the backfill script) re-runs.
 */
public without sharing class CR_FolderSharingService {

    private static final String ROW_CAUSE = 'Manual';

    private class Member {
        Id principalId;
        String access;
        Member(Id principalId, String access) {
            this.principalId = principalId;
            this.access = access;
        }
    }

    // Recompute shares for every report/dashboard in the given folders.
    public static void recomputeFolders(Set<Id> folderIds) {
        if (folderIds == null || folderIds.isEmpty()) {
            return;
        }
        Set<Id> reportIds = new Set<Id>();
        for (Report_Definition__c r : [SELECT Id FROM Report_Definition__c WHERE Folder_Ref__c IN :folderIds]) {
            reportIds.add(r.Id);
        }
        Set<Id> dashboardIds = new Set<Id>();
        for (Dashboard__c d : [SELECT Id FROM Dashboard__c WHERE Folder_Ref__c IN :folderIds]) {
            dashboardIds.add(d.Id);
        }
        recomputeReports(reportIds);
        recomputeDashboards(dashboardIds);
    }

    public static void recomputeReports(Set<Id> reportIds) {
        if (reportIds == null || reportIds.isEmpty()) {
            return;
        }
        Map<Id, Id> folderByRecord = new Map<Id, Id>();
        Set<Id> folderIds = new Set<Id>();
        for (Report_Definition__c r : [SELECT Id, Folder_Ref__c FROM Report_Definition__c WHERE Id IN :reportIds]) {
            if (r.Folder_Ref__c != null) {
                folderByRecord.put(r.Id, r.Folder_Ref__c);
                folderIds.add(r.Folder_Ref__c);
            }
        }
        delete [
            SELECT Id FROM Report_Definition__Share
            WHERE ParentId IN :reportIds AND RowCause = :ROW_CAUSE
        ];
        Map<Id, List<Member>> membersByFolder = loadMembers(folderIds);
        List<Report_Definition__Share> toInsert = new List<Report_Definition__Share>();
        for (Id recordId : folderByRecord.keySet()) {
            List<Member> members = membersByFolder.get(folderByRecord.get(recordId));
            if (members == null) {
                continue;
            }
            for (Member m : members) {
                toInsert.add(new Report_Definition__Share(
                    ParentId = recordId,
                    UserOrGroupId = m.principalId,
                    AccessLevel = m.access
                ));
            }
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, false);
        }
    }

    public static void recomputeDashboards(Set<Id> dashboardIds) {
        if (dashboardIds == null || dashboardIds.isEmpty()) {
            return;
        }
        Map<Id, Id> folderByRecord = new Map<Id, Id>();
        Set<Id> folderIds = new Set<Id>();
        for (Dashboard__c d : [SELECT Id, Folder_Ref__c FROM Dashboard__c WHERE Id IN :dashboardIds]) {
            if (d.Folder_Ref__c != null) {
                folderByRecord.put(d.Id, d.Folder_Ref__c);
                folderIds.add(d.Folder_Ref__c);
            }
        }
        delete [
            SELECT Id FROM Dashboard__Share
            WHERE ParentId IN :dashboardIds AND RowCause = :ROW_CAUSE
        ];
        Map<Id, List<Member>> membersByFolder = loadMembers(folderIds);
        List<Dashboard__Share> toInsert = new List<Dashboard__Share>();
        for (Id recordId : folderByRecord.keySet()) {
            List<Member> members = membersByFolder.get(folderByRecord.get(recordId));
            if (members == null) {
                continue;
            }
            for (Member m : members) {
                toInsert.add(new Dashboard__Share(
                    ParentId = recordId,
                    UserOrGroupId = m.principalId,
                    AccessLevel = m.access
                ));
            }
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, false);
        }
    }

    // Full recompute across every folder that has members — used by the backfill
    // script before the OWD->Private flip.
    public static void recomputeAll() {
        Set<Id> folderIds = new Set<Id>();
        for (AggregateResult ar : [
            SELECT Folder__c fid FROM CR_Folder_Membership__c WHERE Folder__c != null GROUP BY Folder__c
        ]) {
            folderIds.add((Id) ar.get('fid'));
        }
        recomputeFolders(folderIds);
    }

    private static Map<Id, List<Member>> loadMembers(Set<Id> folderIds) {
        Map<Id, List<Member>> out = new Map<Id, List<Member>>();
        if (folderIds == null || folderIds.isEmpty()) {
            return out;
        }
        for (CR_Folder_Membership__c m : [
            SELECT Folder__c, Member_Type__c, User__c, Group_Id__c, Access_Level__c
            FROM CR_Folder_Membership__c
            WHERE Folder__c IN :folderIds
        ]) {
            Id principal = resolvePrincipal(m);
            if (principal == null) {
                continue;
            }
            String access = (m.Access_Level__c == 'Edit') ? 'Edit' : 'Read';
            if (!out.containsKey(m.Folder__c)) {
                out.put(m.Folder__c, new List<Member>());
            }
            out.get(m.Folder__c).add(new Member(principal, access));
        }
        return out;
    }

    private static Id resolvePrincipal(CR_Folder_Membership__c m) {
        if (m.Member_Type__c == 'Public Group') {
            if (String.isBlank(m.Group_Id__c)) {
                return null;
            }
            try {
                return (Id) m.Group_Id__c;
            } catch (Exception e) {
                return null;
            }
        }
        return m.User__c;
    }
}