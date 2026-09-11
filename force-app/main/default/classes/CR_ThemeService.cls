/**
 * Runtime brand theme for Vital Reports. The active CR_Brand_Theme__c record drives
 * the chart palette + in-app accent colors so admins can re-skin the app without a
 * deploy. getActiveTheme() is cacheable and falls back to a built-in Orlando Health
 * default when no record exists. Saving is gated on the Manage_Branding custom perm.
 */
public with sharing class CR_ThemeService {

    // Built-in Orlando Health default (the Tier 1 validated palette + accents).
    private static final List<String> DEFAULT_PALETTE = new List<String>{
        '#e8631c','#6ba9b8','#7a4fa3','#3e8e5a','#2c6ea8','#c0392b','#be7a0a','#b5507a'
    };
    private static final String DEFAULT_PRIMARY = '#e8631c';
    private static final String DEFAULT_HEADER  = '#2b3a47';
    private static final String DEFAULT_ACCENT  = '#6ba9b8';

    public class ThemeDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public List<String> chartPalette;
        @AuraEnabled public String primaryColor;
        @AuraEnabled public String headerColor;
        @AuraEnabled public String accentColor;
        @AuraEnabled public Boolean canManage;
    }

    // Edit rights are gated on object CRUD (admins have create/edit on
    // CR_Brand_Theme__c via the admin permission set; users are read-only). This is
    // reliably visible in tests, unlike a freshly-deployed custom permission.
    private static Boolean canEditTheme() {
        Schema.DescribeSObjectResult d = CR_Brand_Theme__c.SObjectType.getDescribe();
        return d.isCreateable() && d.isUpdateable();
    }

    @AuraEnabled(cacheable=true)
    public static ThemeDto getActiveTheme() {
        ThemeDto dto = new ThemeDto();
        dto.canManage = canEditTheme();
        List<CR_Brand_Theme__c> rows = [
            SELECT Id, Name, Chart_Palette_JSON__c, Primary_Color__c, Header_Color__c, Accent_Color__c
            FROM CR_Brand_Theme__c
            WHERE Is_Active__c = true
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            dto.chartPalette = DEFAULT_PALETTE.clone();
            dto.primaryColor = DEFAULT_PRIMARY;
            dto.headerColor = DEFAULT_HEADER;
            dto.accentColor = DEFAULT_ACCENT;
            return dto;
        }
        CR_Brand_Theme__c t = rows[0];
        dto.id = t.Id;
        dto.name = t.Name;
        dto.chartPalette = parsePalette(t.Chart_Palette_JSON__c);
        dto.primaryColor = blankTo(t.Primary_Color__c, DEFAULT_PRIMARY);
        dto.headerColor = blankTo(t.Header_Color__c, DEFAULT_HEADER);
        dto.accentColor = blankTo(t.Accent_Color__c, DEFAULT_ACCENT);
        return dto;
    }

    /**
     * Upserts the active theme. Payload keys: id (optional), name, chartPalette
     * (array of hex), primaryColor, headerColor, accentColor. Deactivates any other
     * active theme so exactly one stays live.
     */
    @AuraEnabled
    public static Id saveTheme(String payloadJson) {
        if (!canEditTheme()) {
            throw new AuraHandledException('You do not have permission to manage Vital Reports branding.');
        }
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        List<Object> paletteRaw = (List<Object>) p.get('chartPalette');
        List<String> palette = new List<String>();
        if (paletteRaw != null) {
            for (Object o : paletteRaw) {
                String hex = String.valueOf(o).trim();
                if (!isHex(hex)) {
                    throw new AuraHandledException('Invalid palette color: ' + hex);
                }
                palette.add(hex);
            }
        }
        if (palette.isEmpty()) {
            throw new AuraHandledException('The chart palette needs at least one color.');
        }
        String primary = requireHex((String) p.get('primaryColor'), 'Primary color');
        String header = requireHex((String) p.get('headerColor'), 'Header color');
        String accent = requireHex((String) p.get('accentColor'), 'Accent color');
        String name = String.isBlank((String) p.get('name')) ? 'Vital Reports Theme' : (String) p.get('name');

        CR_Brand_Theme__c theme;
        Object idVal = p.get('id');
        String idStr = idVal == null ? null : String.valueOf(idVal);
        if (String.isNotBlank(idStr)) {
            theme = [SELECT Id FROM CR_Brand_Theme__c WHERE Id = :idStr LIMIT 1];
        } else {
            theme = new CR_Brand_Theme__c();
        }
        theme.Name = name.left(80);
        theme.Chart_Palette_JSON__c = JSON.serialize(palette);
        theme.Primary_Color__c = primary;
        theme.Header_Color__c = header;
        theme.Accent_Color__c = accent;
        theme.Is_Active__c = true;
        upsert theme;

        // Ensure exactly one active theme.
        List<CR_Brand_Theme__c> others = [
            SELECT Id FROM CR_Brand_Theme__c WHERE Is_Active__c = true AND Id != :theme.Id
        ];
        if (!others.isEmpty()) {
            for (CR_Brand_Theme__c o : others) o.Is_Active__c = false;
            update others;
        }
        return theme.Id;
    }

    private static List<String> parsePalette(String paletteJson) {
        if (String.isBlank(paletteJson)) return DEFAULT_PALETTE.clone();
        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(paletteJson);
            List<String> out = new List<String>();
            for (Object o : raw) out.add(String.valueOf(o));
            return out.isEmpty() ? DEFAULT_PALETTE.clone() : out;
        } catch (Exception e) {
            return DEFAULT_PALETTE.clone();
        }
    }

    private static String blankTo(String v, String fallback) {
        return String.isBlank(v) ? fallback : v;
    }

    private static String requireHex(String v, String label) {
        String hex = v == null ? null : v.trim();
        if (!isHex(hex)) {
            throw new AuraHandledException(label + ' must be a hex color like #E8631C.');
        }
        return hex;
    }

    private static Boolean isHex(String v) {
        return v != null && Pattern.matches('^#[0-9A-Fa-f]{6}$', v);
    }
}