public with sharing class CR_HomeTileService {

    public class HomeTile {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String iconName { get; set; }
        @AuraEnabled public String target { get; set; }
        @AuraEnabled public String colorScheme { get; set; }
    }

    // Richer shape for the admin manager — includes inactive tiles and the
    // edit-only fields (audience, order, active) the launchpad view omits.
    public class AdminTile {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String iconName { get; set; }
        @AuraEnabled public String target { get; set; }
        @AuraEnabled public String colorScheme { get; set; }
        @AuraEnabled public String audience { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
    }

    public class TabOption {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    @TestVisible private static final String ADMIN_PERMISSION_API_NAME = 'Vital_Reports_Admin_View';
    @TestVisible private static final String MANAGE_PERMISSION_API_NAME = 'Manage_Home_Tiles';
    @TestVisible private static final String DEFAULT_COLOR = 'slate';

    // Returns the tiles the running user should see on the Vital Reports Home
    // page. Admins (granted Vital_Reports_Admin_View) additionally see tiles
    // with Audience__c = 'Admin'. Tiles pointing at tabs that don't resolve —
    // or that the user can't see — are silently skipped so they never render
    // as broken links. Tiles now live in CR_Launchpad_Tile__c (admin-editable),
    // superseding the CR_Home_Tile__mdt catalog.
    @AuraEnabled(cacheable=true)
    public static List<HomeTile> getTilesForCurrentUser() {
        Boolean isAdmin = FeatureManagement.checkPermission(ADMIN_PERMISSION_API_NAME);

        List<CR_Launchpad_Tile__c> all = [
            SELECT Id, Name, Description__c, Icon_Name__c, Target_Tab_API_Name__c,
                   Audience__c, Color_Scheme__c, Display_Order__c
            FROM CR_Launchpad_Tile__c
            WHERE Is_Active__c = true
            ORDER BY Display_Order__c NULLS LAST, Name
        ];

        List<CR_Launchpad_Tile__c> matching = new List<CR_Launchpad_Tile__c>();
        Set<String> requestedTabs = new Set<String>();
        for (CR_Launchpad_Tile__c t : all) {
            Boolean audienceMatches =
                t.Audience__c == 'Both' ||
                t.Audience__c == 'User' ||
                (t.Audience__c == 'Admin' && isAdmin);
            if (!audienceMatches) continue;
            matching.add(t);
            if (String.isNotBlank(t.Target_Tab_API_Name__c)) {
                requestedTabs.add(t.Target_Tab_API_Name__c);
            }
        }

        Set<String> validTabNames = new Set<String>();
        if (!requestedTabs.isEmpty()) {
            for (TabDefinition td : [SELECT Name FROM TabDefinition WHERE Name IN :requestedTabs]) {
                validTabNames.add(td.Name);
            }
        }

        List<HomeTile> result = new List<HomeTile>();
        for (CR_Launchpad_Tile__c t : matching) {
            if (!validTabNames.contains(t.Target_Tab_API_Name__c)) continue;
            HomeTile h = new HomeTile();
            h.key = t.Id;
            h.label = t.Name;
            h.description = t.Description__c;
            h.iconName = t.Icon_Name__c;
            h.target = t.Target_Tab_API_Name__c;
            h.colorScheme = String.isBlank(t.Color_Scheme__c) ? DEFAULT_COLOR : t.Color_Scheme__c;
            result.add(h);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean canManageTiles() {
        return FeatureManagement.checkPermission(MANAGE_PERMISSION_API_NAME);
    }

    // Every tile (active + inactive, all audiences) for the admin manager grid.
    @AuraEnabled
    public static List<AdminTile> listAllTiles() {
        assertManage();
        List<AdminTile> result = new List<AdminTile>();
        for (CR_Launchpad_Tile__c t : [
            SELECT Id, Name, Description__c, Icon_Name__c, Target_Tab_API_Name__c,
                   Audience__c, Color_Scheme__c, Display_Order__c, Is_Active__c
            FROM CR_Launchpad_Tile__c
            ORDER BY Display_Order__c NULLS LAST, Name
        ]) {
            AdminTile a = new AdminTile();
            a.id = t.Id;
            a.label = t.Name;
            a.description = t.Description__c;
            a.iconName = t.Icon_Name__c;
            a.target = t.Target_Tab_API_Name__c;
            a.colorScheme = t.Color_Scheme__c;
            a.audience = t.Audience__c;
            a.displayOrder = t.Display_Order__c;
            a.isActive = t.Is_Active__c;
            result.add(a);
        }
        return result;
    }

    // Tabs available for the target-tab picker in the admin manager.
    @AuraEnabled(cacheable=true)
    public static List<TabOption> listAvailableTabs() {
        List<TabOption> options = new List<TabOption>();
        for (TabDefinition td : [SELECT Name, Label FROM TabDefinition ORDER BY Label]) {
            TabOption o = new TabOption();
            o.value = td.Name;
            o.label = td.Label + ' (' + td.Name + ')';
            options.add(o);
        }
        return options;
    }

    @AuraEnabled
    public static Id saveTile(String payloadJson) {
        assertManage();
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No tile data provided.');
        }
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        String label = (String) m.get('label');
        if (String.isBlank(label)) {
            throw new AuraHandledException('Tile label is required.');
        }
        CR_Launchpad_Tile__c tile = new CR_Launchpad_Tile__c();
        String idStr = (String) m.get('id');
        if (String.isNotBlank(idStr)) {
            tile.Id = (Id) idStr;
        }
        tile.Name = label.left(80);
        tile.Description__c = (String) m.get('description');
        tile.Icon_Name__c = (String) m.get('iconName');
        tile.Target_Tab_API_Name__c = (String) m.get('target');
        String audience = (String) m.get('audience');
        tile.Audience__c = String.isBlank(audience) ? 'Both' : audience;
        String color = (String) m.get('colorScheme');
        tile.Color_Scheme__c = String.isBlank(color) ? DEFAULT_COLOR : color;
        Object orderVal = m.get('displayOrder');
        tile.Display_Order__c = (orderVal == null || String.isBlank(String.valueOf(orderVal)))
            ? null
            : Decimal.valueOf(String.valueOf(orderVal));
        Object activeVal = m.get('isActive');
        tile.Is_Active__c = activeVal == null ? true : Boolean.valueOf(String.valueOf(activeVal));
        upsert tile;
        return tile.Id;
    }

    @AuraEnabled
    public static void deleteTile(Id tileId) {
        assertManage();
        if (tileId == null) {
            throw new AuraHandledException('Tile Id is required.');
        }
        delete [SELECT Id FROM CR_Launchpad_Tile__c WHERE Id = :tileId];
    }

    private static void assertManage() {
        if (!FeatureManagement.checkPermission(MANAGE_PERMISSION_API_NAME)) {
            throw new AuraHandledException('You do not have permission to manage Home tiles.');
        }
    }

    // Idempotent seed of the default tiles from the legacy CR_Home_Tile__mdt
    // catalog into CR_Launchpad_Tile__c, matched by label. Runs in system
    // context (deployed Apex), so it works regardless of the caller's FLS —
    // intentionally NOT @AuraEnabled so only Apex / anonymous Apex can invoke it.
    public static Integer seedFromCatalog() {
        Map<String, CR_Launchpad_Tile__c> existing = new Map<String, CR_Launchpad_Tile__c>();
        for (CR_Launchpad_Tile__c t : [SELECT Id, Name FROM CR_Launchpad_Tile__c]) {
            existing.put(t.Name, t);
        }
        List<CR_Launchpad_Tile__c> toUpsert = new List<CR_Launchpad_Tile__c>();
        for (CR_Home_Tile__mdt m : [
            SELECT MasterLabel, Description__c, Icon_Name__c, Target_Tab_API_Name__c,
                   Audience__c, Color_Scheme__c, Display_Order__c, Is_Active__c
            FROM CR_Home_Tile__mdt
        ]) {
            CR_Launchpad_Tile__c t = existing.containsKey(m.MasterLabel)
                ? existing.get(m.MasterLabel)
                : new CR_Launchpad_Tile__c();
            t.Name = m.MasterLabel;
            t.Description__c = m.Description__c;
            t.Icon_Name__c = m.Icon_Name__c;
            t.Target_Tab_API_Name__c = m.Target_Tab_API_Name__c;
            t.Audience__c = m.Audience__c;
            t.Color_Scheme__c = m.Color_Scheme__c;
            t.Display_Order__c = m.Display_Order__c;
            t.Is_Active__c = m.Is_Active__c;
            toUpsert.add(t);
        }
        if (!toUpsert.isEmpty()) {
            upsert toUpsert;
        }
        return toUpsert.size();
    }
}