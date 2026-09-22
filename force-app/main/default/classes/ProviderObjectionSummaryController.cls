/**
 * Read-only aggregation of the objections raised against a single Provider (Contact).
 *
 * There is no direct relationship between a Provider and a Visit Report, so the
 * path is walked in three steps:
 *
 *   Contact <- TaskWhoRelation.RelationId -> Task.Visit_Report__c
 *           -> Visit_Objection__c.Visit_Report__c -> Objection__c
 *
 * Two capture mechanisms are unioned. The current one writes a Visit_Objection__c
 * junction row per objection. The legacy one stored objections directly on the
 * Activity as a multi-select, which is why tasks are re-read for Objections_Raised__c
 * when their visit report produced no junction row.
 *
 * Reads live data on purpose: Fact_VisitActivityObjection__c is a nightly batch table
 * and would show a provider's objections up to a day stale.
 */
public with sharing class ProviderObjectionSummaryController {

    private static final Integer DEFAULT_ROW_LIMIT = 500;
    private static final Integer MAX_ROW_LIMIT = 2000;
    private static final String SOURCE_JUNCTION = 'Objection record';
    private static final String SOURCE_LEGACY = 'Legacy activity';
    private static final String MULTISELECT_DELIMITER = ';';

    /**
     * @param providerId  Contact id of the provider.
     * @param monthsBack  Rolling window in months. Null or 0 means all time.
     * @param rowLimit    Max junction rows to read. Null defaults to 500, capped at 2000.
     */
    @AuraEnabled(cacheable=true)
    public static ObjectionSummaryResult getObjectionSummary(Id providerId, Integer monthsBack, Integer rowLimit) {
        if (providerId == null || providerId.getSObjectType() != Contact.SObjectType) {
            throw buildException('A valid Provider (Contact) record id is required.');
        }
        try {
            return build(providerId, resolveCutoff(monthsBack), resolveLimit(rowLimit));
        } catch (Exception e) {
            // Surface something readable in the UI instead of a raw stack trace.
            throw buildException('Unable to load the objection summary: ' + e.getMessage());
        }
    }

    private static ObjectionSummaryResult build(Id providerId, Date cutoff, Integer effectiveLimit) {
        ObjectionSummaryResult result = new ObjectionSummaryResult();

        // ---- Step 1: every task this provider is an attendee on. ----------------
        // TaskWhoRelation covers Shared Activities; Task.WhoId covers the primary
        // contact and orgs where Shared Activities is off. Set dedupes the overlap.
        Set<Id> taskIds = new Set<Id>();
        for (TaskWhoRelation twr : [
            SELECT TaskId FROM TaskWhoRelation WHERE RelationId = :providerId
        ]) {
            taskIds.add(twr.TaskId);
        }
        for (Task t : [SELECT Id FROM Task WHERE WhoId = :providerId]) {
            taskIds.add(t.Id);
        }
        if (taskIds.isEmpty()) {
            return result;
        }

        // ---- Step 2: the tasks themselves, inside the date window. ---------------
        // Two static queries rather than one built by string concatenation.
        List<Task> tasks;
        if (cutoff == null) {
            tasks = [
                SELECT Id, CreatedDate, CreatedById, Visit_Report__c, Visit_Report__r.Name, Visit_Date__c, Date_Meeting_Call__c,
                       OwnerId, RecordType.Name, Objections_Raised__c,
                       ObjectionsRaised__c, Objection_Notes__c, Facility_of_Objection__c
                FROM Task
                WHERE Id IN :taskIds
            ];
        } else {
            tasks = [
                SELECT Id, CreatedDate, CreatedById, Visit_Report__c, Visit_Report__r.Name, Visit_Date__c, Date_Meeting_Call__c,
                       OwnerId, RecordType.Name, Objections_Raised__c,
                       ObjectionsRaised__c, Objection_Notes__c, Facility_of_Objection__c
                FROM Task
                WHERE Id IN :taskIds
                  AND (Visit_Date__c >= :cutoff OR Date_Meeting_Call__c >= :cutoff)
            ];
        }
        if (tasks.isEmpty()) {
            return result;
        }

        Set<Id> visitReportIds = new Set<Id>();
        for (Task t : tasks) {
            if (t.Visit_Report__c != null) {
                visitReportIds.add(t.Visit_Report__c);
            }
        }

        // ---- Step 3: current-mechanism objections via the junction. --------------
        Boolean canReadJunction = Schema.SObjectType.Visit_Objection__c.isAccessible();
        Boolean canReadNotes = Schema.SObjectType.Visit_Objection__c.fields.Notes__c.isAccessible();
        Boolean canReadComments = Schema.SObjectType.Visit_Objection__c.fields.Comments__c.isAccessible();

        // Owner is polymorphic (User or Group) and its relationship comes back null
        // in Apex test context even when OwnerId is set, which silently blanked the
        // name column. Resolving both owner and creator through one User query is
        // reliable in every context; queue ids simply will not match.
        Map<Id, String> ownerNames = new Map<Id, String>();

        List<ObjectionRow> rows = new List<ObjectionRow>();
        // Keyed visit report + objection name, so a legacy multi-select value that
        // was later migrated to a junction row is not counted twice.
        Set<String> seenKeys = new Set<String>();
        // Visit reports that produced at least one junction row; their tasks are not
        // re-read for legacy values.
        Set<Id> visitReportsWithJunction = new Set<Id>();

        List<Visit_Objection__c> junctions = new List<Visit_Objection__c>();
        if (canReadJunction && !visitReportIds.isEmpty()) {
            junctions = [
                SELECT Id, CreatedDate, CreatedById, Objection__r.Name, Notes__c, Comments__c, Facility__r.Name,
                       OwnerId, Visit_Report__c, Visit_Report__r.Name,
                       Visit_Report__r.Visit_Date__c, Visit_Report__r.Visit_Type__c,
                       Visit_Report__r.RecordType.Name
                FROM Visit_Objection__c
                WHERE Visit_Report__c IN :visitReportIds
                ORDER BY Visit_Report__r.Visit_Date__c DESC NULLS LAST
                LIMIT :effectiveLimit
            ];
            // Reading exactly the cap almost certainly means more were left behind.
            result.truncated = (junctions.size() == effectiveLimit);
        }

        // One User query covering owners from BOTH sources, so a legacy-only
        // provider still gets "logged by" populated.
        Set<Id> ownerIds = new Set<Id>();
        for (Visit_Objection__c vo : junctions) {
            if (vo.OwnerId != null) { ownerIds.add(vo.OwnerId); }
            if (vo.CreatedById != null) { ownerIds.add(vo.CreatedById); }
        }
        for (Task t : tasks) {
            if (t.OwnerId != null) { ownerIds.add(t.OwnerId); }
            if (t.CreatedById != null) { ownerIds.add(t.CreatedById); }
        }
        if (!ownerIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :ownerIds]) {
                ownerNames.put(u.Id, u.Name);
            }
        }

        {
            for (Visit_Objection__c vo : junctions) {
                visitReportsWithJunction.add(vo.Visit_Report__c);

                ObjectionRow row = new ObjectionRow();
                row.id = vo.Id;
                row.objection = vo.Objection__r == null ? null : vo.Objection__r.Name;
                row.facility = vo.Facility__r == null ? null : vo.Facility__r.Name;
                // Notes is the primary field; Comments is the fallback. Either can be
                // hidden by FLS, in which case the row is kept and the text omitted.
                if (canReadNotes && String.isNotBlank(vo.Notes__c)) {
                    row.notes = vo.Notes__c;
                } else if (canReadComments && String.isNotBlank(vo.Comments__c)) {
                    row.notes = vo.Comments__c;
                }
                row.visitReportId = vo.Visit_Report__c;
                row.visitDate = vo.Visit_Report__r == null ? null : vo.Visit_Report__r.Visit_Date__c;
                row.visitReportName = vo.Visit_Report__r == null ? null : vo.Visit_Report__r.Name;
                row.recordType = (vo.Visit_Report__r == null || vo.Visit_Report__r.RecordType == null)
                    ? null : vo.Visit_Report__r.RecordType.Name;
                row.createdDate = vo.CreatedDate;
                row.createdByName = ownerNames.get(vo.CreatedById);
                row.loggedBy = ownerNames.get(vo.OwnerId);
                row.source = SOURCE_JUNCTION;

                rows.add(row);
                seenKeys.add(dedupeKey(row.visitReportId, row.objection));
            }
        }

        // ---- Legacy union: objections captured on the Activity itself. -----------
        for (Task t : tasks) {
            // A visit report already represented by junction rows is authoritative.
            if (t.Visit_Report__c != null && visitReportsWithJunction.contains(t.Visit_Report__c)) {
                continue;
            }
            for (String name : legacyObjectionNames(t)) {
                String key = dedupeKey(t.Visit_Report__c, name);
                if (seenKeys.contains(key)) {
                    continue;
                }
                seenKeys.add(key);

                ObjectionRow row = new ObjectionRow();
                row.id = t.Id + ':' + name;
                row.objection = name;
                row.facility = t.Facility_of_Objection__c;
                row.notes = t.Objection_Notes__c;
                row.visitReportId = t.Visit_Report__c;
                row.visitReportName = t.Visit_Report__r == null ? null : t.Visit_Report__r.Name;
                row.visitDate = t.Visit_Date__c != null ? t.Visit_Date__c : t.Date_Meeting_Call__c;
                row.recordType = t.RecordType == null ? null : t.RecordType.Name;
                row.createdDate = t.CreatedDate;
                row.createdByName = ownerNames.get(t.CreatedById);
                row.loggedBy = ownerNames.get(t.OwnerId);
                row.source = SOURCE_LEGACY;

                rows.add(row);
            }
        }

        if (rows.isEmpty()) {
            return result;
        }

        // Newest first, undated rows last.
        rows.sort();

        // The junction LIMIT bounds step 3 only; the legacy union can push the
        // combined list past the caller's limit, so trim and say so.
        if (rows.size() > effectiveLimit) {
            List<ObjectionRow> trimmed = new List<ObjectionRow>();
            for (Integer i = 0; i < effectiveLimit; i++) {
                trimmed.add(rows[i]);
            }
            rows = trimmed;
            result.truncated = true;
        }

        result.rows = rows;
        result.totalCount = rows.size();

        Date twelveMonthsAgo = Date.today().addMonths(-12);
        Map<String, Integer> countsByName = new Map<String, Integer>();
        for (ObjectionRow row : rows) {
            if (row.visitDate != null && row.visitDate >= twelveMonthsAgo) {
                result.last12Count++;
            }
            String name = String.isBlank(row.objection) ? '(Unspecified)' : row.objection;
            Integer current = countsByName.get(name);
            countsByName.put(name, current == null ? 1 : current + 1);
        }

        // Rows are already sorted, so the first dated row is the most recent.
        for (ObjectionRow row : rows) {
            if (row.visitDate != null) {
                result.mostRecentDate = row.visitDate;
                result.mostRecentBy = row.loggedBy;
                break;
            }
        }

        List<CategoryCount> categories = new List<CategoryCount>();
        for (String name : countsByName.keySet()) {
            CategoryCount cc = new CategoryCount();
            cc.name = name;
            cc.count = countsByName.get(name);
            cc.percent = result.totalCount == 0
                ? 0
                : ((Decimal) cc.count / result.totalCount * 100).setScale(1);
            categories.add(cc);
        }
        categories.sort();
        result.categories = categories;
        result.categoryCount = categories.size();

        return result;
    }

    /** Splits both legacy capture fields, tolerating either being blank. */
    private static List<String> legacyObjectionNames(Task t) {
        List<String> names = new List<String>();
        Set<String> seen = new Set<String>();
        for (String raw : new List<String>{ t.Objections_Raised__c, t.ObjectionsRaised__c }) {
            if (String.isBlank(raw)) {
                continue;
            }
            for (String part : raw.split(MULTISELECT_DELIMITER)) {
                String trimmed = part == null ? '' : part.trim();
                if (String.isBlank(trimmed)) {
                    continue;
                }
                String key = trimmed.toLowerCase();
                if (seen.add(key)) {
                    names.add(trimmed);
                }
            }
        }
        return names;
    }

    private static String dedupeKey(Id visitReportId, String objectionName) {
        return String.valueOf(visitReportId) + '|' +
            (objectionName == null ? '' : objectionName.trim().toLowerCase());
    }

    private static Integer resolveLimit(Integer rowLimit) {
        if (rowLimit == null || rowLimit <= 0) {
            return DEFAULT_ROW_LIMIT;
        }
        return Math.min(rowLimit, MAX_ROW_LIMIT);
    }

    private static Date resolveCutoff(Integer monthsBack) {
        if (monthsBack == null || monthsBack <= 0) {
            return null;
        }
        return Date.today().addMonths(-monthsBack);
    }

    private static AuraHandledException buildException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        // Without this the client only ever sees "Script-thrown exception".
        e.setMessage(message);
        return e;
    }

    // ---------------------------------------------------------------- wrappers

    public class ObjectionSummaryResult {
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer last12Count = 0;
        @AuraEnabled public Integer categoryCount = 0;
        @AuraEnabled public Date mostRecentDate;
        @AuraEnabled public String mostRecentBy;
        @AuraEnabled public List<CategoryCount> categories = new List<CategoryCount>();
        @AuraEnabled public List<ObjectionRow> rows = new List<ObjectionRow>();
        @AuraEnabled public Boolean truncated = false;
    }

    /** Sorts by count descending so the breakdown leads with the loudest objection. */
    public class CategoryCount implements Comparable {
        @AuraEnabled public String name;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal percent;

        public Integer compareTo(Object other) {
            CategoryCount that = (CategoryCount) other;
            if (this.count == that.count) {
                return this.name == null ? 0 : this.name.compareTo(that.name);
            }
            return that.count - this.count;
        }
    }

    /** Sorts by visit date descending, undated rows last. */
    public class ObjectionRow implements Comparable {
        @AuraEnabled public String id;
        @AuraEnabled public Date visitDate;
        /** When the objection was logged, as opposed to when the visit happened. */
        @AuraEnabled public Datetime createdDate;
        /** Who created the record, which can differ from its current owner. */
        @AuraEnabled public String createdByName;
        @AuraEnabled public String objection;
        @AuraEnabled public String facility;
        @AuraEnabled public String notes;
        @AuraEnabled public Id visitReportId;
        @AuraEnabled public String visitReportName;
        @AuraEnabled public String loggedBy;
        @AuraEnabled public String source;
        @AuraEnabled public String recordType;

        public Integer compareTo(Object other) {
            ObjectionRow that = (ObjectionRow) other;
            if (this.visitDate == null && that.visitDate == null) {
                return 0;
            }
            if (this.visitDate == null) {
                return 1;
            }
            if (that.visitDate == null) {
                return -1;
            }
            if (this.visitDate == that.visitDate) {
                return 0;
            }
            return this.visitDate > that.visitDate ? -1 : 1;
        }
    }
}
