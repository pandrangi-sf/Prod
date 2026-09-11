// Keeps folder-based shares in sync when a report is created or its folder changes.
trigger CR_ReportDefinitionShareTrigger on Report_Definition__c (after insert, after update) {
    Set<Id> changed = new Set<Id>();
    if (Trigger.isInsert) {
        for (Report_Definition__c r : Trigger.new) {
            if (r.Folder_Ref__c != null) {
                changed.add(r.Id);
            }
        }
    } else {
        for (Report_Definition__c r : Trigger.new) {
            if (r.Folder_Ref__c != Trigger.oldMap.get(r.Id).Folder_Ref__c) {
                changed.add(r.Id);
            }
        }
    }
    if (!changed.isEmpty()) {
        CR_FolderSharingService.recomputeReports(changed);
    }
}