@isTest
private class CR_Allowlist_Test {

    // ---- Phase 1 v2 — three-tier model ----

    @isTest
    static void computeDefaultAllowlistReturnsTemplateUnionTraversed() {
        Test.startTest();
        List<String> defaults = CR_AllowlistService.computeDefaultAllowlist();
        Test.stopTest();

        Set<String> apiNames = new Set<String>(defaults);
        // Spot-check a primary (from a template's primaryObject):
        System.assert(apiNames.contains('Task'), 'Task is a template primary');
        System.assert(apiNames.contains('Fact_Opportunity__c'), 'Fact_Opportunity__c is a template primary');
        // Spot-check a traversed (from Task.Account.Name):
        System.assert(apiNames.contains('Account'), 'Account is reached via Task.Account.Name');
        System.assert(apiNames.contains('User'), 'User is reached via Task.CreatedBy.Name');
        System.assert(apiNames.contains('Visit_Report__c'), 'Visit_Report__c is reached via Task.Visit_Report__r.Name');
        // Spot-check a dataset addition:
        System.assert(apiNames.contains('Case'), 'Case comes from CR_Dataset.Case_Hybrid');
        // Defaults must be unique:
        System.assertEquals(apiNames.size(), defaults.size(), 'No duplicate entries');
    }

    @isTest
    static void getActiveAllowlistReturnsTemplateDefaultsWhenNoOverrides() {
        // Greenfield: zero CR_Reportable_Object__c rows. Effective allowlist
        // must still contain the template defaults — fresh orgs "just work".
        Test.startTest();
        List<String> active = CR_AllowlistService.getActiveAllowlist();
        Test.stopTest();

        Set<String> apiNames = new Set<String>(active);
        System.assert(apiNames.contains('Task'), 'Template default present without any DB seed');
        System.assert(apiNames.contains('Account'), 'Traversed default present without any DB seed');
        System.assert(apiNames.contains('Fact_Opportunity__c'), 'Custom Fact default present without seed');
    }

    @isTest
    static void manualIncludeAddsOrgSpecificObject() {
        // Add an object that is NOT in the template defaults.
        insert new CR_Reportable_Object__c(
            Name = 'Asset', SObject_API_Name__c = 'Asset',
            Category__c = 'Standard', Is_Active__c = true,
            Action__c = 'Include', Source__c = 'Manual'
        );

        Test.startTest();
        List<String> active = CR_AllowlistService.getActiveAllowlist();
        Test.stopTest();

        System.assert(new Set<String>(active).contains('Asset'),
            'Manual Action=Include row should add the org-specific object');
    }

    @isTest
    static void manualExcludeSuppressesTemplateDefault() {
        // Account is a template default. Insert an Exclude row to suppress it.
        insert new CR_Reportable_Object__c(
            Name = 'Account', SObject_API_Name__c = 'Account',
            Category__c = 'Standard', Is_Active__c = true,
            Action__c = 'Exclude', Source__c = 'Manual'
        );

        Test.startTest();
        List<String> active = CR_AllowlistService.getActiveAllowlist();
        Test.stopTest();

        System.assert(!new Set<String>(active).contains('Account'),
            'Action=Exclude row should remove a template default from the effective list');
    }

    @isTest
    static void manualIncludeInactiveDoesNotAppear() {
        // Manual Include but Is_Active = false → no effect.
        insert new CR_Reportable_Object__c(
            Name = 'Lead', SObject_API_Name__c = 'Lead',
            Category__c = 'Standard', Is_Active__c = false,
            Action__c = 'Include', Source__c = 'Manual'
        );

        Test.startTest();
        List<String> active = CR_AllowlistService.getActiveAllowlist();
        Test.stopTest();

        // Lead IS still in the effective list because it's a template default
        // (Task.Who.LastName → Lead). Inactivity of a parallel manual row does
        // not suppress the template default — only Action=Exclude does that.
        System.assert(new Set<String>(active).contains('Lead'),
            'Inactive manual Include row should NOT suppress an unrelated template default');
    }

    // ---- listAllCandidates with three-tier source attribution ----

    @isTest
    static void listAllCandidatesMarksTemplateSourceOnImplicitRows() {
        // No DB rows. Candidates should still mark template defaults as
        // source='Template' and inAllowlist=true.
        Test.startTest();
        List<CR_AllowlistService.CandidateObject> candidates = CR_AllowlistService.listAllCandidates();
        Test.stopTest();

        Boolean foundTask = false;
        for (CR_AllowlistService.CandidateObject c : candidates) {
            if (c.apiName == 'Task') {
                foundTask = true;
                System.assertEquals('Template', c.source, 'Task is sourced from a template');
                System.assertEquals(true, c.inAllowlist);
                System.assertEquals('Include', c.action);
            }
        }
        System.assert(foundTask, 'Task should appear among candidates');
    }

    // ---- saveAllowlist with Action/Source ----

    @isTest
    static void saveAllowlistDefaultsActionToInclude() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            new Map<String, Object>{ 'apiName' => 'Contract', 'active' => true }
        };

        Test.startTest();
        Integer written = CR_AllowlistService.saveAllowlist(JSON.serialize(entries));
        Test.stopTest();

        System.assertEquals(1, written);
        CR_Reportable_Object__c row = [
            SELECT Action__c, Source__c FROM CR_Reportable_Object__c
            WHERE SObject_API_Name__c = 'Contract' LIMIT 1
        ];
        System.assertEquals('Include', row.Action__c);
        System.assertEquals('Manual', row.Source__c);
    }

    @isTest
    static void saveAllowlistAcceptsExplicitExclude() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            new Map<String, Object>{
                'apiName' => 'Account', 'active' => true, 'action' => 'Exclude'
            }
        };

        Test.startTest();
        Integer written = CR_AllowlistService.saveAllowlist(JSON.serialize(entries));
        Test.stopTest();

        System.assertEquals(1, written);
        CR_Reportable_Object__c row = [
            SELECT Action__c FROM CR_Reportable_Object__c
            WHERE SObject_API_Name__c = 'Account' LIMIT 1
        ];
        System.assertEquals('Exclude', row.Action__c);
    }

    // ---- Existing legacy tests ----

    @isTest
    static void listAllCandidatesReturnsObjects() {
        Test.startTest();
        List<CR_AllowlistService.CandidateObject> candidates = CR_AllowlistService.listAllCandidates();
        Test.stopTest();

        System.assertNotEquals(null, candidates);
        System.assert(candidates.size() > 0, 'Expected at least one queryable object in describe');
    }

    @isTest
    static void autoPopulateDefaultsIsIdempotent() {
        Test.startTest();
        Integer firstRun = CR_AllowlistService.autoPopulateDefaults();
        Integer secondRun = CR_AllowlistService.autoPopulateDefaults();
        Test.stopTest();

        System.assert(firstRun > 0, 'Expected first run to insert at least one record');
        System.assertEquals(0, secondRun, 'Expected second run to be a no-op');
    }

    @isTest
    static void saveAllowlistDeduplicatesEntries() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            new Map<String, Object>{ 'apiName' => 'Lead', 'active' => true },
            new Map<String, Object>{ 'apiName' => 'Lead', 'active' => true }  // duplicate
        };

        Test.startTest();
        Integer written = CR_AllowlistService.saveAllowlist(JSON.serialize(entries));
        Test.stopTest();

        System.assertEquals(1, written, 'Duplicates should be skipped');
        Integer count = [SELECT COUNT() FROM CR_Reportable_Object__c WHERE SObject_API_Name__c = 'Lead'];
        System.assertEquals(1, count);
    }

    @isTest
    static void clearAllowlistDeactivatesAllRecords() {
        CR_AllowlistService.autoPopulateDefaults();
        Integer before = [SELECT COUNT() FROM CR_Reportable_Object__c WHERE Is_Active__c = true];
        System.assert(before > 0);

        Test.startTest();
        Integer cleared = CR_AllowlistService.clearAllowlist();
        Test.stopTest();

        System.assertEquals(before, cleared);
        Integer after = [SELECT COUNT() FROM CR_Reportable_Object__c WHERE Is_Active__c = true];
        System.assertEquals(0, after, 'Expected zero active records after clear');
    }

    @isTest
    static void deriveCategoryHandlesPrefixesAndSuffixes() {
        System.assertEquals('Fact', CR_AllowlistService.deriveCategory('Fact_Opportunity__c'));
        System.assertEquals('Dimension', CR_AllowlistService.deriveCategory('Dim_Account__c'));
        System.assertEquals('Custom', CR_AllowlistService.deriveCategory('My_Custom_Object__c'));
        System.assertEquals('Standard', CR_AllowlistService.deriveCategory('Account'));
        System.assertEquals('Other', CR_AllowlistService.deriveCategory(null));
        System.assertEquals('Other', CR_AllowlistService.deriveCategory(''));
    }

    @isTest
    static void hasNoisySuffixDetectsCustomShadowObjects() {
        System.assertEquals(true, CR_AllowlistService.hasNoisySuffix('Fact_Opportunity__History'));
        System.assertEquals(true, CR_AllowlistService.hasNoisySuffix('Fact_Opportunity__Share'));
        System.assertEquals(true, CR_AllowlistService.hasNoisySuffix('Fact_Opportunity__Feed'));
        System.assertEquals(true, CR_AllowlistService.hasNoisySuffix('Fact_Opportunity__ChangeEvent'));
        System.assertEquals(false, CR_AllowlistService.hasNoisySuffix('Account'));
        System.assertEquals(false, CR_AllowlistService.hasNoisySuffix('Fact_Opportunity__c'));
    }

    // ---- CR_ObjectDescribeService — now delegates to the three-tier merge ----

    @isTest
    static void listObjectsReturnsTemplateDefaultsWhenNoDbRows() {
        // Greenfield: zero DB rows. listObjects must still return the
        // template-derived defaults — the framework should work out of the box.
        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.listObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (CR_Types.ObjectInfo o : objects) apiNames.add(o.apiName);
        System.assert(apiNames.contains('Account'), 'Account is a template-traversed default');
        System.assert(apiNames.contains('Task'), 'Task is a template primary');
    }

    @isTest
    static void listObjectsExcludesTemplateDefaultWhenSuppressed() {
        // Suppress Account via Action=Exclude.
        insert new CR_Reportable_Object__c(
            Name = 'Account', SObject_API_Name__c = 'Account',
            Is_Active__c = true, Action__c = 'Exclude', Source__c = 'Manual'
        );

        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.listObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (CR_Types.ObjectInfo o : objects) apiNames.add(o.apiName);
        System.assert(!apiNames.contains('Account'),
            'Action=Exclude row should suppress the template default from listObjects');
    }

    @isTest
    static void listObjectsIncludesOrgSpecificManualAdd() {
        // Use CR_Reportable_Object__c (our own custom object — guaranteed
        // queryable in every CRF-installed org). It is intentionally NOT in
        // the template defaults, so a Manual Include is the only way it
        // appears in listObjects().
        insert new CR_Reportable_Object__c(
            Name = 'CR_Reportable_Object__c', SObject_API_Name__c = 'CR_Reportable_Object__c',
            Is_Active__c = true, Action__c = 'Include', Source__c = 'Manual'
        );

        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.listObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (CR_Types.ObjectInfo o : objects) apiNames.add(o.apiName);
        System.assert(apiNames.contains('CR_Reportable_Object__c'),
            'Manual Action=Include should add an org-specific object on top of defaults');
    }

    @isTest
    static void listObjectsSkipsAllowlistEntriesForUnknownObjects() {
        insert new CR_Reportable_Object__c(
            Name = 'Imaginary__c', SObject_API_Name__c = 'Imaginary__c',
            Is_Active__c = true, Action__c = 'Include', Source__c = 'Manual'
        );

        Test.startTest();
        List<CR_Types.ObjectInfo> objects = CR_ObjectDescribeService.listObjects();
        Test.stopTest();

        System.assertNotEquals(null, objects);
        for (CR_Types.ObjectInfo o : objects) {
            System.assertNotEquals('Imaginary__c', o.apiName);
        }
    }
}