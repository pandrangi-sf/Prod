// Org-level Platform Cache facade for saved-report query results.
//
// SECURITY: cache key MUST include UserInfo.getUserId(). Salesforce FLS and
// sharing mean the same SOQL can return different rows for different users.
// A shared cache key would leak data across users. Per-user keys are slightly
// less hit-rate-efficient but safe by construction.
//
// FAIL-SOFT: every public method swallows exceptions. Cache is observability/
// performance, not correctness — a partition that doesn't exist, is full, or
// throws under load must never break the underlying report. On any failure
// the caller falls back to its non-cached path.
//
// PARTITION SETUP (one-time per org, manual): Setup → Platform Cache → New
// Partition → Name 'CRF' → Org-Level 5MB (start small, grow on measured need)
// → Session-Level 0MB → Save. Without this step every get() returns null and
// every put() is a no-op — the framework still runs, just without caching.
public with sharing class CR_QueryCacheService {

    private static final String PARTITION_NAME = 'local.CRF';
    @TestVisible private static final Integer DEFAULT_TTL_SECONDS = 300;     // 5 min
    @TestVisible private static final Integer MAX_TTL_SECONDS = 28800;       // 8 h cap

    public static CR_Types.QueryResult get(String cacheKey) {
        if (String.isBlank(cacheKey)) return null;
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(PARTITION_NAME);
            return p == null ? null : (CR_Types.QueryResult) p.get(cacheKey);
        } catch (Exception ex) { return null; }
    }

    public static void put(String cacheKey, CR_Types.QueryResult result, Integer ttlSeconds) {
        if (String.isBlank(cacheKey) || result == null) return;
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(PARTITION_NAME);
            if (p != null) p.put(cacheKey, result, normalizeTtl(ttlSeconds));
        } catch (Exception ex) { /* fail-soft */ }
    }

    public static void invalidate(String cacheKey) {
        if (String.isBlank(cacheKey)) return;
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(PARTITION_NAME);
            if (p != null) p.remove(cacheKey);
        } catch (Exception ex) { /* fail-soft */ }
    }

    // Cache key: SHA-256 of (reportId + userId + filters), truncated to 50 chars
    // to fit Platform Cache's partition-key length limit. Per-user by construction
    // so FLS-driven row differences don't leak across users.
    public static String buildKey(Id reportDefinitionId, String dashboardFiltersJson) {
        if (reportDefinitionId == null) return null;
        String composite = String.valueOf(reportDefinitionId)
            + ':' + UserInfo.getUserId()
            + ':' + (dashboardFiltersJson == null ? '' : dashboardFiltersJson);
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(composite));
        return EncodingUtil.convertToHex(hash).substring(0, 50);
    }

    @TestVisible
    private static Integer normalizeTtl(Integer ttl) {
        return ttl == null || ttl <= 0 ? DEFAULT_TTL_SECONDS : Math.min(ttl, MAX_TTL_SECONDS);
    }
}