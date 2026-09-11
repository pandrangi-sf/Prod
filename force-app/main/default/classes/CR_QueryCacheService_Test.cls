@IsTest
private class CR_QueryCacheService_Test {

    @IsTest
    static void buildKey_is_deterministic_for_same_inputs() {
        Id fakeId = '001000000000001AAA';
        String filters = '[{"field":"Region__c","operator":"=","value":"AL"}]';

        String k1 = CR_QueryCacheService.buildKey(fakeId, filters);
        String k2 = CR_QueryCacheService.buildKey(fakeId, filters);

        System.assertEquals(k1, k2, 'Same inputs must produce same key');
        System.assert(k1 != null && k1.length() <= 50, 'Key must fit Platform Cache 50-char limit');
    }

    @IsTest
    static void buildKey_differs_when_filters_change() {
        Id fakeId = '001000000000001AAA';
        String k1 = CR_QueryCacheService.buildKey(fakeId, '[]');
        String k2 = CR_QueryCacheService.buildKey(fakeId, '[{"field":"X","operator":"=","value":"Y"}]');
        System.assertNotEquals(k1, k2, 'Different filter JSON must produce different key');
    }

    @IsTest
    static void buildKey_differs_when_reportId_changes() {
        String k1 = CR_QueryCacheService.buildKey('001000000000001AAA', '[]');
        String k2 = CR_QueryCacheService.buildKey('001000000000002AAA', '[]');
        System.assertNotEquals(k1, k2);
    }

    @IsTest
    static void buildKey_returns_null_for_null_reportId() {
        System.assertEquals(null, CR_QueryCacheService.buildKey(null, '[]'));
    }

    @IsTest
    static void get_returns_null_on_blank_key() {
        System.assertEquals(null, CR_QueryCacheService.get(null));
        System.assertEquals(null, CR_QueryCacheService.get(''));
    }

    @IsTest
    static void get_returns_null_when_partition_is_missing() {
        // The CRF partition isn't deployed in default test orgs. get() must
        // swallow the resulting null/exception and return null silently —
        // never throw to the caller.
        CR_Types.QueryResult result = CR_QueryCacheService.get('any-key');
        System.assertEquals(null, result);
    }

    @IsTest
    static void put_is_no_op_when_partition_is_missing() {
        // Same reasoning as above — must not throw.
        CR_Types.QueryResult sample = new CR_Types.QueryResult();
        sample.rowCount = 42;
        Test.startTest();
        CR_QueryCacheService.put('test-key', sample, 60);
        Test.stopTest();
        // No assertion needed — just that the call didn't throw.
        System.assert(true, 'put() must not throw on missing partition');
    }

    @IsTest
    static void put_handles_null_result() {
        Test.startTest();
        CR_QueryCacheService.put('test-key', null, 60);
        Test.stopTest();
        System.assert(true, 'put(null) must not throw');
    }

    @IsTest
    static void invalidate_is_no_op_when_partition_is_missing() {
        Test.startTest();
        CR_QueryCacheService.invalidate('any-key');
        Test.stopTest();
        System.assert(true, 'invalidate() must not throw on missing partition');
    }

    @IsTest
    static void ttl_constants_have_sensible_values() {
        System.assert(CR_QueryCacheService.DEFAULT_TTL_SECONDS > 0);
        System.assert(CR_QueryCacheService.MAX_TTL_SECONDS >= CR_QueryCacheService.DEFAULT_TTL_SECONDS);
        System.assert(CR_QueryCacheService.DEFAULT_TTL_SECONDS <= 600, 'Default TTL should be under 10 min');
        System.assert(CR_QueryCacheService.MAX_TTL_SECONDS >= 3600, 'Max TTL should permit at least 1h');
    }

    @IsTest
    static void normalizeTtl_clamps_correctly() {
        // null / 0 / negative → default
        System.assertEquals(CR_QueryCacheService.DEFAULT_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(null));
        System.assertEquals(CR_QueryCacheService.DEFAULT_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(0));
        System.assertEquals(CR_QueryCacheService.DEFAULT_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(-99));
        // Reasonable values pass through
        System.assertEquals(60, CR_QueryCacheService.normalizeTtl(60));
        System.assertEquals(3600, CR_QueryCacheService.normalizeTtl(3600));
        // Over-large values clamped to max
        System.assertEquals(CR_QueryCacheService.MAX_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(99999));
        System.assertEquals(CR_QueryCacheService.MAX_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(CR_QueryCacheService.MAX_TTL_SECONDS + 1));
        // Exactly at max stays at max
        System.assertEquals(CR_QueryCacheService.MAX_TTL_SECONDS, CR_QueryCacheService.normalizeTtl(CR_QueryCacheService.MAX_TTL_SECONDS));
    }

    @IsTest
    static void buildKey_includes_filters_in_hash() {
        // Edge case: null filters → empty string in composite
        Id id1 = '001000000000001AAA';
        String withNull = CR_QueryCacheService.buildKey(id1, null);
        String withEmpty = CR_QueryCacheService.buildKey(id1, '');
        System.assertEquals(withNull, withEmpty, 'null and empty filters should hash identically');
    }
}