public with sharing class CR_ObjectDescribeService {
    private static final Integer MAX_DEPTH = 2;
    private static final Integer DEFAULT_OBJECT_SEARCH_LIMIT = 75;
    private static final Integer MAX_OBJECT_SEARCH_LIMIT = 200;

    @TestVisible
    private static final Set<String> FALLBACK_STANDARD_OBJECTS = new Set<String>{
        'Account', 'Contact', 'Lead', 'Opportunity', 'OpportunityLineItem',
        'Case', 'CaseComment', 'Campaign', 'CampaignMember',
        'User', 'Activity', 'Task', 'Event', 'OpenActivity', 'ActivityHistory',
        'Product2', 'Pricebook2', 'PricebookEntry',
        'Order', 'OrderItem', 'Asset', 'Contract',
        'Quote', 'QuoteLineItem'
    };

    @TestVisible
    private static final Set<String> ACTIVITY_OBJECTS = new Set<String>{
        'Activity', 'Task', 'Event', 'OpenActivity', 'ActivityHistory'
    };

    @TestVisible
    private static final Set<String> FALLBACK_FRAMEWORK_OBJECTS = new Set<String>{
        'Fact_Opportunity__c', 'Fact_Case__c',
        'Dim_Account__c', 'Dim_User__c', 'Dim_Product__c'
    };

    @TestVisible
    private static final Set<String> FALLBACK_NOISY_SUFFIXES = new Set<String>{
        '__History', '__Share', '__ChangeEvent', '__Feed', '__Tag'
    };

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ObjectInfo> listObjects() {
        return resolveObjects(getAllowlistApiNames(), null, DEFAULT_OBJECT_SEARCH_LIMIT);
    }

    @AuraEnabled(cacheable=true)
    public static List<CR_Types.ObjectInfo> searchObjects(String searchTerm, Integer maxResults) {
        return resolveObjects(getAllowlistApiNames(), searchTerm, maxResults);
    }

    @TestVisible
    private static Set<String> getAllowlistApiNames() {
        // Phase 1 v2 — delegate to CR_AllowlistService.getActiveAllowlist(),
        // which returns the three-tier merge:
        //   (template defaults) ∪ (manual includes) − (manual excludes)
        // The previous implementation read ONLY CR_Reportable_Object__c, which
        // forced every new org to be data-seeded before reports would work.
        // The new model returns a sensible default for fresh orgs out of the box.
        return new Set<String>(CR_AllowlistService.getActiveAllowlist());
    }

    @TestVisible
    private static List<CR_Types.ObjectInfo> resolveObjects(Set<String> allowlist) {
        return resolveObjects(allowlist, null, null);
    }

    private static List<CR_Types.ObjectInfo> resolveObjects(Set<String> allowlist, String searchTerm, Integer maxResults) {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<CR_Types.ObjectInfo> results = new List<CR_Types.ObjectInfo>();
        String normalizedTerm = normalizeSearchTerm(searchTerm);
        Integer limitSize = boundObjectSearchLimit(maxResults);

        // Build the candidate set: explicit allowlist if any, else a compact
        // starter set. In large managed-package orgs, describing every custom
        // object on page load can make Lightning appear frozen.
        Set<String> candidates = new Set<String>();
        if (allowlist != null && !allowlist.isEmpty()) {
            candidates.addAll(allowlist);
        } else {
            candidates.addAll(FALLBACK_STANDARD_OBJECTS);
            candidates.addAll(FALLBACK_FRAMEWORK_OBJECTS);
            addMatchingCustomObjectApiNames(candidates, globalDescribe, normalizedTerm);
        }

        List<String> candidateNames = new List<String>(candidates);
        candidateNames.sort();

        for (String apiName : candidateNames) {
            if (results.size() >= limitSize) break;
            if (!globalDescribe.containsKey(apiName)) continue;
            Schema.DescribeSObjectResult describeResult = globalDescribe.get(apiName).getDescribe();
            if (!describeResult.isQueryable() || !describeResult.isAccessible()) continue;

            CR_Types.ObjectInfo info = new CR_Types.ObjectInfo();
            info.apiName = apiName;
            info.label = describeResult.getLabel();
            info.pluralLabel = describeResult.getLabelPlural();
            info.custom = describeResult.isCustom();
            info.queryable = describeResult.isQueryable();
            info.createable = describeResult.isCreateable();
            info.updateable = describeResult.isUpdateable();
            if (!matchesSearch(info, normalizedTerm)) continue;
            results.add(info);
        }

        return results;
    }

    private static void addMatchingCustomObjectApiNames(
        Set<String> candidates,
        Map<String, Schema.SObjectType> globalDescribe,
        String normalizedTerm
    ) {
        if (String.isBlank(normalizedTerm)) return;
        for (String apiName : globalDescribe.keySet()) {
            if (!apiName.endsWith('__c')) continue;
            if (hasNoisySuffix(apiName)) continue;
            if (!apiName.toLowerCase().contains(normalizedTerm)) continue;
            candidates.add(apiName);
        }
    }

    private static Boolean matchesSearch(CR_Types.ObjectInfo info, String normalizedTerm) {
        if (String.isBlank(normalizedTerm)) return true;
        if (normalizedTerm.contains('activity') && ACTIVITY_OBJECTS.contains(info.apiName)) return true;
        return containsIgnoreCase(info.apiName, normalizedTerm)
            || containsIgnoreCase(info.label, normalizedTerm)
            || containsIgnoreCase(info.pluralLabel, normalizedTerm);
    }

    private static Boolean containsIgnoreCase(String value, String normalizedTerm) {
        return value != null && value.toLowerCase().contains(normalizedTerm);
    }

    private static String normalizeSearchTerm(String searchTerm) {
        return String.isBlank(searchTerm) ? null : searchTerm.trim().toLowerCase();
    }

    private static Integer boundObjectSearchLimit(Integer maxResults) {
        if (maxResults == null || maxResults <= 0) {
            return DEFAULT_OBJECT_SEARCH_LIMIT;
        }
        return Math.min(maxResults, MAX_OBJECT_SEARCH_LIMIT);
    }

    @TestVisible
    private static Boolean hasNoisySuffix(String apiName) {
        for (String suffix : FALLBACK_NOISY_SUFFIXES) {
            if (apiName.endsWith(suffix)) return true;
        }
        return false;
    }

    @AuraEnabled(cacheable=true)
    public static CR_Types.DescribeResult describeObject(String objectApiName, Integer depth) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Select an object before loading fields.');
        }
        Integer boundedDepth = depth == null ? 1 : Math.min(Math.max(depth, 0), MAX_DEPTH);
        return buildDescribe(objectApiName, boundedDepth);
    }

    @AuraEnabled(cacheable=true)
    public static String buildDatasetDefinition(String primaryObject, List<String> relatedObjects, List<String> fieldPaths) {
        if (String.isBlank(primaryObject)) {
            throw new AuraHandledException('Primary object is required.');
        }
        CR_Types.DatasetDefinition definition = new CR_Types.DatasetDefinition();
        definition.datasetKey = primaryObject + '_AdHoc';
        definition.mode = 'live';
        definition.primaryObject = primaryObject;
        definition.relatedObjects = relatedObjects == null ? new List<String>() : relatedObjects;
        definition.fieldPaths = fieldPaths == null ? new List<String>() : fieldPaths;
        definition.relationshipGraphJson = buildRelationshipGraphJson(primaryObject, definition.relatedObjects);
        return JSON.serializePretty(definition);
    }

    private static String buildRelationshipGraphJson(String primaryObject, List<String> relatedObjects) {
        CR_Types.DescribeResult describe = buildDescribe(primaryObject, 1);
        Map<String, Object> graph = new Map<String, Object>{
            'objectInfo' => describe.objectInfo,
            'relatedObjects' => relatedObjects == null ? new List<String>() : relatedObjects,
            'parentRelationships' => describe.parentRelationships,
            'childRelationships' => describe.childRelationships
        };
        return JSON.serialize(graph);
    }

    private static CR_Types.DescribeResult buildDescribe(String objectApiName, Integer depth) {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        if (!globalDescribe.containsKey(objectApiName)) {
            throw new AuraHandledException('Object not found: ' + objectApiName);
        }

        Schema.DescribeSObjectResult describeResult = globalDescribe.get(objectApiName).getDescribe();
        if (!describeResult.isAccessible() || !describeResult.isQueryable()) {
            throw new AuraHandledException('You do not have access to query ' + describeResult.getLabel() + '.');
        }

        CR_Types.DescribeResult result = new CR_Types.DescribeResult();
        result.objectInfo = toObjectInfo(objectApiName, describeResult);
        result.fields = getFields(describeResult);
        result.parentRelationships = getParentRelationships(describeResult);
        result.childRelationships = depth > 0 ? getChildRelationships(describeResult) : new List<CR_Types.RelationshipInfo>();
        return result;
    }

    private static CR_Types.ObjectInfo toObjectInfo(String apiName, Schema.DescribeSObjectResult describeResult) {
        CR_Types.ObjectInfo info = new CR_Types.ObjectInfo();
        info.apiName = apiName;
        info.label = describeResult.getLabel();
        info.pluralLabel = describeResult.getLabelPlural();
        info.custom = describeResult.isCustom();
        info.queryable = describeResult.isQueryable();
        info.createable = describeResult.isCreateable();
        info.updateable = describeResult.isUpdateable();
        return info;
    }

    private static List<CR_Types.FieldInfo> getFields(Schema.DescribeSObjectResult describeResult) {
        List<CR_Types.FieldInfo> fields = new List<CR_Types.FieldInfo>();
        Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();

        for (String fieldName : fieldMap.keySet()) {
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(fieldName).getDescribe();
            if (!fieldDescribe.isAccessible()) {
                continue;
            }

            CR_Types.FieldInfo info = new CR_Types.FieldInfo();
            // Schema.DescribeSObjectResult.fields.getMap().keySet() returns field
            // names in lowercase (a well-known Apex quirk). Templates and saved
            // reports use canonical proper-case API names; surfacing the lowercase
            // form broke crObjectFieldSelector's path matching on Back-navigation
            // after a template apply (Phase 1 v17). fieldDescribe.getName() returns
            // the canonical case as defined in setup, so consumers see what the
            // user/template writer actually typed.
            info.apiName = fieldDescribe.getName();
            info.relationshipName = fieldDescribe.getRelationshipName();
            info.label = fieldDescribe.getLabel();
            info.dataType = String.valueOf(fieldDescribe.getType());
            info.accessible = fieldDescribe.isAccessible();
            info.filterable = fieldDescribe.isFilterable();
            info.groupable = fieldDescribe.isGroupable();
            info.sortable = fieldDescribe.isSortable();
            info.calculated = fieldDescribe.isCalculated();
            info.referenceTo = new List<String>();
            for (Schema.SObjectType referenceType : fieldDescribe.getReferenceTo()) {
                info.referenceTo.add(referenceType.getDescribe().getName());
            }
            Schema.DisplayType displayType = fieldDescribe.getType();
            if (displayType == Schema.DisplayType.Picklist || displayType == Schema.DisplayType.MultiPicklist) {
                info.picklistValues = new List<String>();
                for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                    if (entry.isActive()) {
                        info.picklistValues.add(entry.getValue());
                    }
                }
            }
            fields.add(info);
        }

        return fields;
    }

    private static List<CR_Types.RelationshipInfo> getParentRelationships(Schema.DescribeSObjectResult describeResult) {
        List<CR_Types.RelationshipInfo> relationships = new List<CR_Types.RelationshipInfo>();
        Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();

        for (String fieldName : fieldMap.keySet()) {
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(fieldName).getDescribe();
            if (!fieldDescribe.isAccessible()
                || fieldDescribe.getReferenceTo().isEmpty()
                || String.isBlank(fieldDescribe.getRelationshipName())) {
                continue;
            }
            for (Schema.SObjectType referenceType : fieldDescribe.getReferenceTo()) {
                Schema.DescribeSObjectResult referenceDescribe = referenceType.getDescribe();
                if (!referenceDescribe.isAccessible() || !referenceDescribe.isQueryable()) {
                    continue;
                }
                CR_Types.RelationshipInfo relationship = new CR_Types.RelationshipInfo();
                relationship.relationshipName = fieldDescribe.getRelationshipName();
                relationship.objectApiName = referenceDescribe.getName();
                relationship.fieldApiName = fieldName;
                relationship.label = referenceDescribe.getLabel();
                relationship.direction = 'parent';
                relationships.add(relationship);
            }
        }

        return relationships;
    }

    private static List<CR_Types.RelationshipInfo> getChildRelationships(Schema.DescribeSObjectResult describeResult) {
        List<CR_Types.RelationshipInfo> relationships = new List<CR_Types.RelationshipInfo>();

        for (Schema.ChildRelationship child : describeResult.getChildRelationships()) {
            if (String.isBlank(child.getRelationshipName()) || child.getChildSObject() == null || child.getField() == null) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = child.getChildSObject().getDescribe();
            if (!childDescribe.isAccessible() || !childDescribe.isQueryable()) {
                continue;
            }

            CR_Types.RelationshipInfo relationship = new CR_Types.RelationshipInfo();
            relationship.relationshipName = child.getRelationshipName();
            relationship.objectApiName = childDescribe.getName();
            relationship.fieldApiName = String.valueOf(child.getField());
            relationship.label = childDescribe.getLabelPlural();
            relationship.direction = 'child';
            relationships.add(relationship);
        }

        return relationships;
    }
}