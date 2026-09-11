/**
 * Governed metric (measure) layer for Vital Reports. A CR_Metric__c is one reusable,
 * certifiable definition of a number — an aggregation over a field, an optional
 * metric-level filter, a display format — that reports and dashboards reference by
 * Developer Name instead of re-defining inline. This is what keeps "Won Revenue" the
 * same number everywhere.
 *
 * The query engine calls resolveIntoDefinition() to expand a {"metric":"Won_Revenue"}
 * reference into the concrete aggregation it already understands, so nothing downstream
 * in the engine changes. That method runs in async contexts (export/batch) too, so it
 * throws MetricException (a plain, catchable exception) rather than AuraHandledException,
 * which is illegal off the Aura stack.
 *
 * Editing is gated on object CRUD (admins have create/edit on CR_Metric__c via the admin
 * permission set; users are read-only) — reliably visible in tests, unlike a freshly
 * deployed custom permission.
 */
public with sharing class CR_MetricService {

    private static final Set<String> ALLOWED_AGGREGATIONS = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
    private static final Set<String> ALLOWED_FORMATS = new Set<String>{ 'Number', 'Currency', 'Percent' };

    public class MetricException extends Exception {}

    public class MetricDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String developerName;
        @AuraEnabled public String name;
        @AuraEnabled public String datasetKey;
        @AuraEnabled public String aggregation;
        @AuraEnabled public String fieldPath;
        @AuraEnabled public String filterJson;
        @AuraEnabled public String format;
        @AuraEnabled public Integer decimalPlaces;
        @AuraEnabled public String description;
        @AuraEnabled public String category;
        @AuraEnabled public Boolean isCertified;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public String stewardName;
    }

    // ---------- read ----------

    // Active metrics for one dataset — feeds the report builder's measure picker.
    @AuraEnabled(cacheable=true)
    public static List<MetricDto> getMetricsForDataset(String datasetKey) {
        List<MetricDto> out = new List<MetricDto>();
        if (String.isBlank(datasetKey)) {
            return out;
        }
        for (CR_Metric__c m : [
            SELECT Id, Developer_Name__c, Name, Dataset_Key__c, Aggregation__c, Field_Path__c,
                   Filter_JSON__c, Format__c, Decimal_Places__c, Description__c, Category__c,
                   Is_Certified__c, Is_Active__c, Steward__r.Name
            FROM CR_Metric__c
            WHERE Dataset_Key__c = :datasetKey AND Is_Active__c = true
            ORDER BY Is_Certified__c DESC, Name ASC
        ]) {
            out.add(toDto(m));
        }
        return out;
    }

    // Everything, for the admin console. Not cacheable so edits show immediately.
    @AuraEnabled
    public static List<MetricDto> listAllMetrics() {
        List<MetricDto> out = new List<MetricDto>();
        for (CR_Metric__c m : [
            SELECT Id, Developer_Name__c, Name, Dataset_Key__c, Aggregation__c, Field_Path__c,
                   Filter_JSON__c, Format__c, Decimal_Places__c, Description__c, Category__c,
                   Is_Certified__c, Is_Active__c, Steward__r.Name
            FROM CR_Metric__c
            ORDER BY Dataset_Key__c ASC, Name ASC
            LIMIT 1000
        ]) {
            out.add(toDto(m));
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean canManageMetrics() {
        return canManage();
    }

    // ---------- write ----------

    @AuraEnabled
    public static Id saveMetric(String payloadJson) {
        if (!canManage()) {
            throw new AuraHandledException('You do not have permission to manage metrics.');
        }
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('No metric data provided.');
        }
        Map<String, Object> p;
        try {
            p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        } catch (Exception e) {
            throw new AuraHandledException('The metric could not be read.');
        }

        String developerName = trim((String) p.get('developerName'));
        if (String.isBlank(developerName) || !Pattern.matches('^[A-Za-z][A-Za-z0-9_]*$', developerName)) {
            throw new AuraHandledException('Developer Name must start with a letter and contain only letters, numbers, and underscores (e.g. Won_Revenue).');
        }
        String name = trim((String) p.get('name'));
        if (String.isBlank(name)) {
            throw new AuraHandledException('Give the metric a name.');
        }
        String datasetKey = trim((String) p.get('datasetKey'));
        if (String.isBlank(datasetKey)) {
            throw new AuraHandledException('Pick the dataset this metric belongs to.');
        }
        String aggregation = trim((String) p.get('aggregation')).toUpperCase();
        if (!ALLOWED_AGGREGATIONS.contains(aggregation)) {
            throw new AuraHandledException('Unsupported aggregation: ' + aggregation);
        }
        String fieldPath = trim((String) p.get('fieldPath'));
        if (aggregation != 'COUNT' && String.isBlank(fieldPath)) {
            throw new AuraHandledException(aggregation + ' needs a field to summarize.');
        }
        String format = trim((String) p.get('format'));
        if (!ALLOWED_FORMATS.contains(format)) {
            format = 'Number';
        }
        String filterJson = (String) p.get('filterJson');
        if (String.isNotBlank(filterJson)) {
            List<String> filterErrors = CR_QueryEngine.validateOverrideFiltersStructural(filterJson);
            if (!filterErrors.isEmpty()) {
                throw new AuraHandledException('Metric filter problem: ' + String.join(filterErrors, ' '));
            }
        }

        CR_Metric__c metric;
        String idStr = p.get('id') == null ? null : String.valueOf(p.get('id'));
        if (String.isNotBlank(idStr)) {
            metric = [SELECT Id FROM CR_Metric__c WHERE Id = :idStr LIMIT 1];
        } else {
            metric = new CR_Metric__c();
        }
        metric.Developer_Name__c = developerName;
        metric.Name = name.left(80);
        metric.Dataset_Key__c = datasetKey;
        metric.Aggregation__c = aggregation;
        metric.Field_Path__c = aggregation == 'COUNT' && String.isBlank(fieldPath) ? null : fieldPath;
        metric.Filter_JSON__c = String.isBlank(filterJson) ? null : filterJson;
        metric.Format__c = format;
        metric.Decimal_Places__c = toDecimalPlaces(p.get('decimalPlaces'));
        metric.Description__c = (String) p.get('description');
        metric.Category__c = trim((String) p.get('category'));
        metric.Is_Certified__c = p.get('isCertified') != null && Boolean.valueOf(p.get('isCertified'));
        metric.Is_Active__c = p.get('isActive') == null ? true : Boolean.valueOf(p.get('isActive'));

        try {
            upsert metric;
        } catch (DmlException e) {
            // Most common: the unique Developer Name is already taken.
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return metric.Id;
    }

    @AuraEnabled
    public static void deleteMetric(Id metricId) {
        if (!canManage()) {
            throw new AuraHandledException('You do not have permission to manage metrics.');
        }
        if (metricId == null) {
            throw new AuraHandledException('No metric specified.');
        }
        try {
            delete [SELECT Id FROM CR_Metric__c WHERE Id = :metricId LIMIT 1];
        } catch (Exception e) {
            throw new AuraHandledException('Could not delete the metric: ' + e.getMessage());
        }
    }

    // ---------- engine integration ----------

    /**
     * Expands metric references in a report definition into the aggregation shape the
     * query engine already understands, in place. An aggregation entry of the form
     * {"metric":"Won_Revenue"} becomes {"function":"SUM","field":"Amount__c","label":"Won Revenue"},
     * and the metric's own filter (if any) is AND-ed into the report's filters.
     *
     * Only one filtered metric can be used per query — SOQL has no per-aggregate filter
     * (no conditional aggregates), so combining two differently-filtered metrics would
     * silently cross-contaminate. That case is rejected rather than answered wrongly.
     *
     * No-op when the definition references no metrics, so it is safe to call on every run.
     * Throws MetricException (catchable in async contexts) on any problem.
     */
    public static void resolveIntoDefinition(Map<String, Object> definition) {
        if (definition == null) {
            return;
        }
        Object aggsObj = definition.get('aggregations');
        if (!(aggsObj instanceof List<Object>)) {
            return;
        }
        List<Object> aggregations = (List<Object>) aggsObj;

        Set<String> referenced = new Set<String>();
        for (Object aggObj : aggregations) {
            if (aggObj instanceof Map<String, Object>) {
                String ref = trim((String) ((Map<String, Object>) aggObj).get('metric'));
                if (String.isNotBlank(ref)) {
                    referenced.add(ref);
                }
            }
        }
        if (referenced.isEmpty()) {
            return;
        }

        Map<String, CR_Metric__c> byName = new Map<String, CR_Metric__c>();
        for (CR_Metric__c m : [
            SELECT Developer_Name__c, Name, Aggregation__c, Field_Path__c, Filter_JSON__c, Is_Active__c
            FROM CR_Metric__c
            WHERE Developer_Name__c IN :referenced
        ]) {
            byName.put(m.Developer_Name__c, m);
        }

        List<Object> expanded = new List<Object>();
        String pendingFilterJson = null;
        String pendingFilterMetric = null;

        for (Object aggObj : aggregations) {
            if (!(aggObj instanceof Map<String, Object>)) {
                expanded.add(aggObj);
                continue;
            }
            Map<String, Object> agg = (Map<String, Object>) aggObj;
            String ref = trim((String) agg.get('metric'));
            if (String.isBlank(ref)) {
                expanded.add(aggObj); // a plain inline aggregation — leave it
                continue;
            }
            CR_Metric__c m = byName.get(ref);
            if (m == null) {
                throw new MetricException('Unknown metric: ' + ref);
            }
            if (m.Is_Active__c == false) {
                throw new MetricException('Metric "' + m.Name + '" is inactive and can no longer be used.');
            }
            expanded.add(new Map<String, Object>{
                'function' => m.Aggregation__c,
                'field' => m.Field_Path__c,
                'label' => m.Name
            });
            if (String.isNotBlank(m.Filter_JSON__c)) {
                if (pendingFilterJson != null) {
                    throw new MetricException(
                        'Metrics "' + pendingFilterMetric + '" and "' + m.Name + '" each carry their own filter and cannot be combined in one report yet.'
                    );
                }
                pendingFilterJson = m.Filter_JSON__c;
                pendingFilterMetric = m.Name;
            }
        }

        definition.put('aggregations', expanded);

        if (pendingFilterJson != null) {
            mergeFilterIntoDefinition(definition, pendingFilterJson);
        }
    }

    // AND the metric filter into the report's existing filters. The engine treats a
    // top-level list of filters as AND-ed, so we flatten both sides into one list.
    private static void mergeFilterIntoDefinition(Map<String, Object> definition, String metricFilterJson) {
        Object metricParsed;
        try {
            metricParsed = JSON.deserializeUntyped(metricFilterJson);
        } catch (Exception e) {
            throw new MetricException('A metric filter is not valid JSON.');
        }

        List<Object> combined = new List<Object>();
        Object existing = definition.get('filters');
        if (existing instanceof List<Object>) {
            combined.addAll((List<Object>) existing);
        } else if (existing != null) {
            combined.add(existing);
        }
        if (metricParsed instanceof List<Object>) {
            combined.addAll((List<Object>) metricParsed);
        } else if (metricParsed != null) {
            combined.add(metricParsed);
        }
        definition.put('filters', combined);
    }

    // ---------- helpers ----------

    private static Boolean canManage() {
        Schema.DescribeSObjectResult d = CR_Metric__c.SObjectType.getDescribe();
        return d.isCreateable() && d.isUpdateable();
    }

    private static MetricDto toDto(CR_Metric__c m) {
        MetricDto d = new MetricDto();
        d.id = m.Id;
        d.developerName = m.Developer_Name__c;
        d.name = m.Name;
        d.datasetKey = m.Dataset_Key__c;
        d.aggregation = m.Aggregation__c;
        d.fieldPath = m.Field_Path__c;
        d.filterJson = m.Filter_JSON__c;
        d.format = m.Format__c;
        d.decimalPlaces = m.Decimal_Places__c == null ? null : Integer.valueOf(m.Decimal_Places__c);
        d.description = m.Description__c;
        d.category = m.Category__c;
        d.isCertified = m.Is_Certified__c;
        d.isActive = m.Is_Active__c;
        d.stewardName = m.Steward__r == null ? null : m.Steward__r.Name;
        return d;
    }

    private static Decimal toDecimalPlaces(Object v) {
        if (v == null) return null;
        try {
            Integer n = Integer.valueOf(v);
            if (n < 0) n = 0;
            if (n > 6) n = 6;
            return n;
        } catch (Exception e) {
            return null;
        }
    }

    private static String trim(String v) {
        return v == null ? null : v.trim();
    }
}