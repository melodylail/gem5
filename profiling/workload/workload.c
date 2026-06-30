/* profiling/workload/workload.c
 * Synthetic SPEC-style compute kernel for gem5 SE mode profiling.
 * 4 phases: FP matrix multiply, integer hash, branch-heavy sort, memory streaming.
 * Target: ~200M-500M instructions, ~10-30s wall clock in gem5 SE mode.
 *
 * Compile: gcc -O2 -static -o workload workload.c -lm
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define N 256
#define HASH_ITERS 200000
#define SORT_SIZE 10000
#define STREAM_SIZE (32 * 1024 * 1024)  /* 32 MiB */

/* --- Phase 1: Matrix Multiply (FMA, cache pressure) --- */
static void
phase1_matrix_multiply(void)
{
    double *a = aligned_alloc(64, N * N * sizeof(double));
    double *b = aligned_alloc(64, N * N * sizeof(double));
    double *c = aligned_alloc(64, N * N * sizeof(double));
    if (!a || !b || !c) {
        fprintf(stderr, "phase1: alloc failed\n");
        exit(1);
    }

    for (int i = 0; i < N * N; i++) {
        a[i] = (double)(i % 997) / 1000.0;
        b[i] = (double)((i * 3) % 997) / 1000.0;
        c[i] = 0.0;
    }

    for (int i = 0; i < N; i++) {
        for (int k = 0; k < N; k++) {
            double aik = a[i * N + k];
            for (int j = 0; j < N; j++) {
                c[i * N + j] += aik * b[k * N + j];
            }
        }
    }

    double checksum = 0.0;
    for (int i = 0; i < N * N; i++) {
        checksum += c[i];
    }
    printf("  phase1: matrix %dx%d checksum=%.2f\n", N, N, checksum);

    free(a);
    free(b);
    free(c);
}

/* --- Phase 2: Hash computation (integer ALU, bit ops) --- */
static uint32_t
rotl32(uint32_t x, int n)
{
    return (x << n) | (x >> (32 - n));
}

static void
phase2_hash_compute(void)
{
    /* Simplified SHA-256-like mixing */
    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    uint32_t data[16];

    for (int iter = 0; iter < HASH_ITERS; iter++) {
        for (int i = 0; i < 16; i++) {
            data[i] = state[i % 8] ^ (iter * 0x9e3779b9 + i);
        }

        for (int round = 0; round < 64; round++) {
            uint32_t s1 = rotl32(state[4], 6) ^ rotl32(state[4], 11)
                          ^ rotl32(state[4], 25);
            uint32_t ch = (state[4] & state[5]) ^ (~state[4] & state[6]);
            uint32_t temp1 = state[7] + s1 + ch
                             + data[round % 16] + round * 0x428a2f98;

            uint32_t s0 = rotl32(state[0], 2) ^ rotl32(state[0], 13)
                          ^ rotl32(state[0], 22);
            uint32_t maj = (state[0] & state[1])
                           ^ (state[0] & state[2])
                           ^ (state[1] & state[2]);
            uint32_t temp2 = s0 + maj;

            state[7] = state[6];
            state[6] = state[5];
            state[5] = state[4];
            state[4] = state[3] + temp1;
            state[3] = state[2];
            state[2] = state[1];
            state[1] = state[0];
            state[0] = temp1 + temp2;
        }
    }

    printf("  phase2: hash %d iters final state[0]=0x%08x\n",
           HASH_ITERS, state[0]);
}

/* --- Phase 3: Branch-heavy sort (branch predictor stress) --- */
static int
cmp_int(const void *a, const void *b)
{
    int ia = *(const int *)a;
    int ib = *(const int *)b;
    return (ia > ib) - (ia < ib);
}

static void
phase3_branch_sort(void)
{
    int *arr = malloc(SORT_SIZE * sizeof(int));
    if (!arr) {
        fprintf(stderr, "phase3: malloc failed\n");
        exit(1);
    }

    srand(42);
    for (int i = 0; i < SORT_SIZE; i++) {
        arr[i] = rand() % SORT_SIZE;
    }

    qsort(arr, SORT_SIZE, sizeof(int), cmp_int);

    int sorted = 1;
    for (int i = 1; i < SORT_SIZE; i++) {
        if (arr[i] < arr[i - 1]) {
            sorted = 0;
            break;
        }
    }
    printf("  phase3: sorted %d elements, sorted=%d\n", SORT_SIZE, sorted);

    free(arr);
}

/* --- Phase 4: Memory streaming (prefetcher / bandwidth) --- */
static void
phase4_memory_stream(void)
{
    size_t size = STREAM_SIZE;
    char *src = aligned_alloc(64, size);
    char *dst = aligned_alloc(64, size);
    if (!src || !dst) {
        fprintf(stderr, "phase4: alloc failed\n");
        exit(1);
    }

    memset(src, 0xAB, size);

    /* Forward copy */
    memcpy(dst, src, size);
    /* Backward copy */
    for (size_t i = 0; i < size; i++) {
        src[i] = dst[size - 1 - i];
    }
    /* Forward copy again */
    memcpy(dst, src, size);

    size_t checksum = 0;
    for (size_t i = 0; i < size; i++) {
        checksum += (unsigned char)dst[i];
    }
    printf("  phase4: stream %zu MiB checksum=%zu\n",
           size / (1024 * 1024), checksum);

    free(src);
    free(dst);
}

/* --- Main --- */
int
main(void)
{
    printf("=== gem5 SE profiling workload ===\n");

    phase1_matrix_multiply();
    phase2_hash_compute();
    phase3_branch_sort();
    phase4_memory_stream();

    printf("=== done ===\n");
    return 0;
}
