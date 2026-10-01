/*
 * Pure-C regression coverage for the membership dispatcher used by
 * `purgeDeadThreads`.
 *
 * This `#include`s cbits/simd_search.c directly so it can access
 * `contains`, `contains_bsearch`, and `LINEAR_THRESHOLD`.
 */

#include "../../cbits/simd_search.c"

#include <stdio.h>

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

    if (g_failures == 0) {
        printf("PASS: %d checks, 0 failures\n", g_checks);
    } else {
        printf("FAILED: %d/%d checks failed\n", g_failures, g_checks);
    }
    return g_failures != 0;
}
