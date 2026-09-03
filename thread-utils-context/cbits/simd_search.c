#include "HsFFI.h"
#include <stdlib.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#if defined(__x86_64__) || defined(_M_X64)
#include <emmintrin.h>
#endif

/*
 * SIMD linear scan beats branchless binary search up to ~128 elements
 * at 2 lanes per compare (NEON int64x2 / SSE2 __m128i).  Beyond that,
 * binary search's O(log n) wins despite branch overhead (which is
 * mostly eliminated by CMOV).
 */
#define LINEAR_THRESHOLD 128

/* -------------------------------------------------------------------
 * Branchless binary search (Khuong / Lemire style)
 *
 * `sorted` must be in ascending order.  The comparison `base[half] <
 * needle` compiles to CMOV on both x86-64 and AArch64 at -O2, so no
 * branch mispredictions.
 *
 * The loop narrows to a lower-bound *candidate*, not to the answer: on
 * exit the lower bound is either `base` or `base + 1`.  Lemire's original
 * returns the index `(*base < target) + (base - source)` precisely to
 * account for that.  Both slots must therefore be compared here --
 * testing only `*base` reports "absent" for almost every element that is
 * actually present (e.g. 199 of 200 for a contiguous run), because the
 * loop most often stops one short.
 * ------------------------------------------------------------------- */
static inline int contains_bsearch(HsInt needle,
                                   const HsInt *sorted, HsInt n) {
    if (n <= 0)
        return 0;
    const HsInt *base = sorted;
    HsInt len = n;
    while (len > 1) {
        HsInt half = len >> 1;
        base += (base[half] < needle) ? half : 0;
        len -= half;
    }
    if (*base == needle)
        return 1;
    const HsInt *next = base + 1;
    return (next < sorted + n) && (*next == needle);
}

/* -------------------------------------------------------------------
 * Architecture-dispatched SIMD linear scan
 *
 * Processes 4 elements per main-loop iteration (two 128-bit loads).
 * The scalar tail handles up to 3 leftover elements.
 * ------------------------------------------------------------------- */

#if defined(__aarch64__)

static inline int contains_linear(HsInt needle,
                                  const HsInt *hay, HsInt n) {
    int64x2_t vn = vdupq_n_s64(needle);
    HsInt i = 0;
    for (; i + 4 <= n; i += 4) {
        int64x2_t a = vld1q_s64(&hay[i]);
        int64x2_t b = vld1q_s64(&hay[i + 2]);
        uint64x2_t ea = vceqq_s64(a, vn);
        uint64x2_t eb = vceqq_s64(b, vn);
        uint64x2_t any = vorrq_u64(ea, eb);
        if (vmaxvq_u32(vreinterpretq_u32_u64(any)))
            return 1;
    }
    for (; i + 2 <= n; i += 2) {
        uint64x2_t eq = vceqq_s64(vld1q_s64(&hay[i]), vn);
        if (vmaxvq_u32(vreinterpretq_u32_u64(eq)))
            return 1;
    }
    for (; i < n; i++)
        if (hay[i] == needle) return 1;
    return 0;
}

#elif defined(__x86_64__) || defined(_M_X64)

/*
 * SSE2-only 64-bit equality (no _mm_cmpeq_epi64 without SSE4.1):
 *   1. XOR each lane with needle (zero iff equal)
 *   2. cmpeq_epi32 against zero (flags 32-bit halves that are zero)
 *   3. Shuffle to swap 32-bit halves within each 64-bit lane
 *   4. AND (both halves must be zero for 64-bit equality)
 *   5. movemask to scalar
 */
static inline int contains_linear(HsInt needle,
                                  const HsInt *hay, HsInt n) {
    __m128i vn   = _mm_set1_epi64x(needle);
    __m128i zero = _mm_setzero_si128();
    HsInt i = 0;
    for (; i + 4 <= n; i += 4) {
        __m128i xa = _mm_xor_si128(
                       _mm_loadu_si128((const __m128i *)&hay[i]), vn);
        __m128i xb = _mm_xor_si128(
                       _mm_loadu_si128((const __m128i *)&hay[i + 2]), vn);
        __m128i ea  = _mm_cmpeq_epi32(xa, zero);
        __m128i eb  = _mm_cmpeq_epi32(xb, zero);
        __m128i sa  = _mm_shuffle_epi32(ea, _MM_SHUFFLE(2,3,0,1));
        __m128i sb  = _mm_shuffle_epi32(eb, _MM_SHUFFLE(2,3,0,1));
        __m128i any = _mm_or_si128(_mm_and_si128(ea, sa),
                                   _mm_and_si128(eb, sb));
        if (_mm_movemask_epi8(any))
            return 1;
    }
    for (; i + 2 <= n; i += 2) {
        __m128i x  = _mm_xor_si128(
                       _mm_loadu_si128((const __m128i *)&hay[i]), vn);
        __m128i eq = _mm_cmpeq_epi32(x, zero);
        __m128i sh = _mm_shuffle_epi32(eq, _MM_SHUFFLE(2,3,0,1));
        if (_mm_movemask_epi8(_mm_and_si128(eq, sh)))
            return 1;
    }
    for (; i < n; i++)
        if (hay[i] == needle) return 1;
    return 0;
}

#else /* scalar fallback for s390x, riscv64, powerpc64, etc. */

static inline int contains_linear(HsInt needle,
                                  const HsInt *hay, HsInt n) {
    for (HsInt i = 0; i < n; i++)
        if (hay[i] == needle) return 1;
    return 0;
}

#endif

/* -------------------------------------------------------------------
 * Dispatch: SIMD linear for small sets, branchless bsearch for large
 * ------------------------------------------------------------------- */
static inline int contains(HsInt needle, const HsInt *sorted, HsInt n) {
    return (n <= LINEAR_THRESHOLD)
        ? contains_linear(needle, sorted, n)
        : contains_bsearch(needle, sorted, n);
}

/* -------------------------------------------------------------------
 * qsort comparator for HsInt. Branchless: (x > y) - (x < y)
 * ------------------------------------------------------------------- */
static int cmp_hsint(const void *a, const void *b) {
    HsInt x = *(const HsInt *)a;
    HsInt y = *(const HsInt *)b;
    return (x > y) - (x < y);
}

/* -------------------------------------------------------------------
 * purge_find_dead
 *
 * Batch membership test for purgeDeadThreads.  Called once via unsafe
 * ccall to amortise FFI overhead across the full table scan.
 *
 * Sorts live[] in place (needed for the binary search fallback when
 * n_live > LINEAR_THRESHOLD), then scans keys[0..cap).
 *
 * Output layout in dead_out (must have room for cap + 1 elements):
 *   dead_out[0]          = total occupied slots (for shrink decisions)
 *   dead_out[1 .. count] = indices of dead slots
 *
 * Returns the count of dead slots found.
 *
 * keys / live / dead_out are pointers to MutableByteArray# payloads
 * (GHC passes payload pointer with UnliftedFFITypes).
 * ------------------------------------------------------------------- */
HsInt purge_find_dead(
    const HsInt *keys,
    HsInt cap,
    HsInt *live,
    HsInt n_live,
    HsInt tombstone_val,
    HsInt key_mask,
    HsInt *dead_out)
{
    if (n_live > 1)
        qsort(live, (size_t)n_live, sizeof(HsInt), cmp_hsint);

    HsInt dead_count = 0;
    HsInt occupied = 0;
    for (HsInt i = 0; i < cap; i++) {
        HsInt k = keys[i];
        if (k != 0 && k != tombstone_val) {
            occupied++;
            HsInt raw_k = k & key_mask;
            if (!contains(raw_k, live, n_live))
                dead_out[1 + dead_count++] = i;
        }
    }
    dead_out[0] = occupied;
    return dead_count;
}
