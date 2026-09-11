trigger CR_FolderMembershipTrigger on CR_Folder_Membership__c (
    after insert, after update, after delete, after undelete
) {
    Set<Id> folderIds = new Set<Id>();
    if (Trigger.isDelete) {
        for (CR_Folder_Membership__c m : Trigger.old) {
            if (m.Folder__c != null) {
                folderIds.add(m.Folder__c);
            }
        }
    } else {
        for (CR_Folder_Membership__c m : Trigger.new) {
            if (m.Folder__c != null) {
                folderIds.add(m.Folder__c);
            }
        }
    }
    CR_FolderSharingService.recomputeFolders(folderIds);
}