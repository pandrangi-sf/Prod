@IsTest
private class CR_ThemeService_Test {

    @IsTest
    static void defaultThemeWhenNoRecord() {
        Test.startTest();
        CR_ThemeService.ThemeDto dto = CR_ThemeService.getActiveTheme();
        Test.stopTest();
        System.assert(dto.chartPalette != null && !dto.chartPalette.isEmpty(), 'A default palette should be returned.');
        System.assertEquals('#e8631c', dto.chartPalette[0], 'Default palette leads with OH orange.');
        System.assertEquals('#2b3a47', dto.headerColor, 'Default header is OH navy.');
    }

    @IsTest
    static void saveAndReadThemeAsAdmin() {
        User admin = sysAdmin();
        Id themeId;
        System.runAs(admin) {
            String payload = JSON.serialize(new Map<String, Object>{
                'name' => 'OH Test',
                'chartPalette' => new List<String>{ '#E8631C', '#6BA9B8', '#7A4FA3' },
                'primaryColor' => '#E8631C',
                'headerColor' => '#2B3A47',
                'accentColor' => '#6BA9B8'
            });
            themeId = CR_ThemeService.saveTheme(payload);
            System.assertNotEquals(null, themeId, 'Save should return the theme id.');
        }
        CR_ThemeService.ThemeDto dto = CR_ThemeService.getActiveTheme();
        System.assertEquals(3, dto.chartPalette.size(), 'Saved palette should be read back.');
        System.assertEquals('#E8631C', dto.chartPalette[0]);
        System.assertEquals('#2B3A47', dto.headerColor);
    }

    @IsTest
    static void saveDeactivatesPriorActiveTheme() {
        User admin = sysAdmin();
        System.runAs(admin) {
            CR_ThemeService.saveTheme(JSON.serialize(new Map<String, Object>{
                'name' => 'First', 'chartPalette' => new List<String>{ '#E8631C' },
                'primaryColor' => '#E8631C', 'headerColor' => '#2B3A47', 'accentColor' => '#6BA9B8'
            }));
            CR_ThemeService.saveTheme(JSON.serialize(new Map<String, Object>{
                'name' => 'Second', 'chartPalette' => new List<String>{ '#6BA9B8' },
                'primaryColor' => '#6BA9B8', 'headerColor' => '#2B3A47', 'accentColor' => '#E8631C'
            }));
        }
        System.assertEquals(1,
            [SELECT COUNT() FROM CR_Brand_Theme__c WHERE Is_Active__c = true],
            'Exactly one theme should remain active.');
    }

    @IsTest
    static void saveRejectsBadHex() {
        User admin = sysAdmin();
        Boolean threw = false;
        System.runAs(admin) {
            try {
                CR_ThemeService.saveTheme(JSON.serialize(new Map<String, Object>{
                    'chartPalette' => new List<String>{ 'not-a-color' },
                    'primaryColor' => '#E8631C', 'headerColor' => '#2B3A47', 'accentColor' => '#6BA9B8'
                }));
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'An invalid hex must be rejected.');
    }

    @IsTest
    static void saveRequiresManageBrandingPermission() {
        User noPerm = makeStandardUser();
        Boolean threw = false;
        System.runAs(noPerm) {
            try {
                CR_ThemeService.saveTheme('{"chartPalette":["#E8631C"],"primaryColor":"#E8631C","headerColor":"#2B3A47","accentColor":"#6BA9B8"}');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'A user without Manage_Branding must be blocked from saving.');
    }

    // System Administrator (Modify All Data) so CR_Brand_Theme__c CRUD is available
    // without depending on a freshly-deployed permission-set object grant, which is
    // not reliably visible during the same deploy's test run.
    private static User sysAdmin() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crta',
                Email = 'crthadmin@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'ThemeAdmin',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crthadmin' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }

    private static User makeStandardUser() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Integer rand = Math.abs(Crypto.getRandomInteger());
            u = new User(
                Alias = 'crth',
                Email = 'crtheme@example.com.invalid',
                EmailEncodingKey = 'UTF-8',
                LastName = 'ThemeNoPerm',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/New_York',
                Username = 'crtheme' + rand + '@example.com.invalid'
            );
            insert u;
        }
        return u;
    }
}