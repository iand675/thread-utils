/*
 * Pure-C regression coverage for the membership dispatcher and the
 * purge scan used by `purgeDeadThreads`.
 *
 * This `#include`s cbits/simd_search.c directly so it can access
 * `contains`, `contains_bsearch`, and `LINEAR_THRESHOLD`.
 */

#include "../../cbits/simd_search.c"

#include <stdio.h>
#include <string.h>

/* -------------------------------------------------------------------
 * Tiny hand-rolled harness: the process exits non-zero iff at least
 * one check failed.
 * ------------------------------------------------------------------- */
static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, ...)                \
    do {                                 \
        g_checks++;                      \
        if (!(cond)) {                   \
            g_failures++;                \
            printf("FAIL: " __VA_ARGS__); \
            printf("\n");                 \
        }                                 \
    } while (0)

/* -------------------------------------------------------------------
 * Array generators.
 * ------------------------------------------------------------------- */

/* 1, 2, 3, ..., n */
static void contiguous(HsInt n, HsInt *out) {
    for (HsInt i = 0; i < n; i++) out[i] = i + 1;
}

/* 7, 14, 21, ..., 7n -- exercises non-contiguous gaps */
static void strided(HsInt n, HsInt *out) {
    for (HsInt i = 0; i < n; i++) out[i] = (i + 1) * 7;
}

/* 1, 1, 1, 2, 2, 2, ... -- exercises repeated values */
static void with_duplicates(HsInt n, HsInt *out) {
    for (HsInt i = 0; i < n; i++) out[i] = (i / 3) + 1;
}

/* -------------------------------------------------------------------
 * check_array: probe every element, its immediate neighbours, and a
 * few out-of-range sentinels; assert the dispatcher agrees with a
 * reference membership check (correct by construction, since it's
 * just a linear scan over the array the caller built).
 * ------------------------------------------------------------------- */
static int hsint_in_array(HsInt v, const HsInt *xs, HsInt n) {
    for (HsInt i = 0; i < n; i++)
        if (xs[i] == v) return 1;
    return 0;
}

static void check_needle(const char *label, HsInt needle, const HsInt *xs, HsInt n) {
    int expected = hsint_in_array(needle, xs, n);
    int actual = contains(needle, xs, n) != 0;
    CHECK(actual == expected,
          "%s: contains(%lld, xs, n=%lld) = %d, expected %d",
          label, (long long)needle, (long long)n, actual, expected);
}

static void check_array(const char *label, const HsInt *xs, HsInt n) {
    for (HsInt i = 0; i < n; i++) {
        check_needle(label, xs[i] - 1, xs, n);
        check_needle(label, xs[i], xs, n);
        check_needle(label, xs[i] + 1, xs, n);
    }
    check_needle(label, HS_INT_MIN, xs, n);
    check_needle(label, HS_INT_MAX, xs, n);
    check_needle(label, 0, xs, n);
    check_needle(label, -1, xs, n);
    check_needle(label, 1, xs, n);
}

/* Sizes straddling LINEAR_THRESHOLD on both sides, derived from the
 * constant so the boundary stays covered if it is ever tuned. */
static const HsInt SIZES[] = {
    0, 1, 2, 3,
    LINEAR_THRESHOLD - 1, LINEAR_THRESHOLD, LINEAR_THRESHOLD + 1,
    2 * LINEAR_THRESHOLD, 8 * LINEAR_THRESHOLD,
};

/* -------------------------------------------------------------------
 * purge_find_dead / purge_filter_live: exercise the dead_out layout,
 * empty/tombstone skipping, flag-bit masking, and the second-snapshot
 * rescue. Mirrors the constants in Storage.hs.
 * ------------------------------------------------------------------- */
#define TOMBSTONE     ((HsInt)1 << 63)
#define DETACHED_BIT  ((HsInt)1 << 32)
#define CLAIMING_BIT  ((HsInt)1 << 33)
#define KEY_MASK      (DETACHED_BIT - 1)
#define VERSION(n)    ((HsInt)(n) << 34)
#define TOMB_MASK     (~(VERSION(0x1FFFFFFF)))   /* everything but bits 34..62 */

static void check_purge_scan(void) {
    enum { CAP = 16 };
    HsInt keys[CAP];
    memset(keys, 0, sizeof keys);
    keys[1]  = 10 | VERSION(3);           /* live, attached, versioned   */
    keys[2]  = 11 | DETACHED_BIT;         /* live, detached              */
    keys[3]  = 20;                        /* dead                        */
    keys[4]  = 21 | DETACHED_BIT;         /* dead, detached              */
    keys[5]  = TOMBSTONE | VERSION(7);    /* skipped despite its version */
    keys[6]  = 22 | CLAIMING_BIT;         /* dead, mid-claim (reported)  */
    keys[7]  = 30 | VERSION(1);           /* born after snapshot 1       */
    keys[8]  = TOMBSTONE;                 /* skipped                     */
    keys[9]  = 12;                        /* live                        */

    HsInt live1[] = { 12, 10, 11 };       /* unsorted on purpose         */
    HsInt dead_out[2 * CAP + 1];
    memset(dead_out, 0x55, sizeof dead_out);

    HsInt n = purge_find_dead(keys, CAP, live1, 3, TOMBSTONE, TOMB_MASK, KEY_MASK, dead_out);
    CHECK(n == 4, "purge_find_dead: count = %lld, expected 4", (long long)n);
    CHECK(dead_out[0] == 7, "purge_find_dead: occupied = %lld, expected 7", (long long)dead_out[0]);
    CHECK(live1[0] == 10 && live1[1] == 11 && live1[2] == 12, "purge_find_dead: live set not sorted");

    /* Entries are in slot order with the observed key word, flags intact. */
    const HsInt exp_slots[] = { 3, 4, 6, 7 };
    const HsInt exp_keys[]  = { 20, 21 | DETACHED_BIT, 22 | CLAIMING_BIT, 30 | VERSION(1) };
    for (HsInt i = 0; i < n && i < 4; i++) {
        CHECK(dead_out[1 + 2 * i] == exp_slots[i],
              "purge_find_dead: entry %lld slot = %lld, expected %lld",
              (long long)i, (long long)dead_out[1 + 2 * i], (long long)exp_slots[i]);
        CHECK(dead_out[2 + 2 * i] == exp_keys[i],
              "purge_find_dead: entry %lld key = %#llx, expected %#llx",
              (long long)i, (unsigned long long)dead_out[2 + 2 * i], (unsigned long long)exp_keys[i]);
    }

    /* Second snapshot: 30 has appeared. It must be rescued; the rest stay. */
    HsInt live2[] = { 30, 12, 11, 10 };
    HsInt kept = purge_filter_live(dead_out, n, live2, 4, KEY_MASK);
    CHECK(kept == 3, "purge_filter_live: kept = %lld, expected 3", (long long)kept);
    CHECK(dead_out[0] == 7, "purge_filter_live: clobbered dead_out[0]");
    const HsInt exp_slots2[] = { 3, 4, 6 };
    for (HsInt i = 0; i < kept && i < 3; i++) {
        CHECK(dead_out[1 + 2 * i] == exp_slots2[i],
              "purge_filter_live: entry %lld slot = %lld, expected %lld",
              (long long)i, (long long)dead_out[1 + 2 * i], (long long)exp_slots2[i]);
        CHECK(dead_out[2 + 2 * i] == exp_keys[i],
              "purge_filter_live: entry %lld key changed", (long long)i);
    }

    /* Empty live set: everything occupied is dead. */
    HsInt n0 = purge_find_dead(keys, CAP, live1, 0, TOMBSTONE, TOMB_MASK, KEY_MASK, dead_out);
    CHECK(n0 == 7, "purge_find_dead(n_live=0): count = %lld, expected 7", (long long)n0);
    HsInt kept0 = purge_filter_live(dead_out, n0, live1, 0, KEY_MASK);
    CHECK(kept0 == 7, "purge_filter_live(n_live=0): kept = %lld, expected 7", (long long)kept0);
}

int main(void) {
    static HsInt buf[8 * LINEAR_THRESHOLD];
    char label[64];

    for (size_t i = 0; i < sizeof(SIZES) / sizeof(SIZES[0]); i++) {
        HsInt n = SIZES[i];

        contiguous(n, buf);
        snprintf(label, sizeof(label), "contiguous n=%lld", (long long)n);
        check_array(label, buf, n);

        strided(n, buf);
        snprintf(label, sizeof(label), "strided n=%lld", (long long)n);
        check_array(label, buf, n);

        with_duplicates(n, buf);
        snprintf(label, sizeof(label), "with-duplicates n=%lld", (long long)n);
        check_array(label, buf, n);
    }

    check_purge_scan();

    if (g_failures == 0) {
        printf("PASS: %d checks, 0 failures\n", g_checks);
    } else {
        printf("FAILED: %d/%d checks failed\n", g_failures, g_checks);
    }
    return g_failures != 0;
}
