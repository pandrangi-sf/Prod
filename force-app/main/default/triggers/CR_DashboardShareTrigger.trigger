// Keeps folder-based shares in sync when a dashboard is created or its folder changes.
trigger CR_DashboardShareTrigger on Dashboard__c (after insert, after update) {
    Set<Id> changed = new Set<Id>();
    if (Trigger.isInsert) {
        for (Dashboard__c d : Trigger.new) {
            if (d.Folder_Ref__c != null) {
                changed.add(d.Id);
            }
        }
    } else {
        for (Dashboard__c d : Trigger.new) {
            if (d.Folder_Ref__c != Trigger.oldMap.get(d.Id).Folder_Ref__c) {
                changed.add(d.Id);
            }
        }
    }
    if (!changed.isEmpty()) {
        CR_FolderSharingService.recomputeDashboards(changed);
    }
}