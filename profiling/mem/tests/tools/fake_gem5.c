/* profiling/mem/tests/tools/fake_gem5.c
 * Deterministic fake gem5 process for sampler integration tests.
 *
 * Usage: fake_gem5 <alloc_mb_per_sec> <duration_s> [--stats-out <path>]
 *
 * Allocates <alloc_mb_per_sec> MB per second (touches pages so RSS grows),
 * prints "Beginning simulation!" after 1 s, and optionally writes a
 * gem5-shaped stats.txt on exit.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t keep_running = 1;

static void
handle_signal(int sig)
{
    (void)sig;
    keep_running = 0;
}

int
main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(
            stderr,
            "Usage: %s <alloc_mb_per_sec> <duration_s> [--stats-out <path>]\n",
            argv[0]);
        return 1;
    }

    double alloc_mb_per_sec = atof(argv[1]);
    double duration_s = atof(argv[2]);
    const char *stats_out = NULL;

    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--stats-out") == 0 && i + 1 < argc) {
            stats_out = argv[++i];
        }
    }

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    double elapsed = 0.0;
    double total_allocated_mb = 0.0;
    int ticks_per_sec = 10;
    double tick_s = 1.0 / ticks_per_sec;
    double alloc_per_tick_mb = alloc_mb_per_sec / ticks_per_sec;
    long page_size = sysconf(_SC_PAGESIZE);

    usleep(999000);

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    printf("Beginning simulation!\n");
    fflush(stdout);

    while (keep_running && elapsed < duration_s) {
        size_t bytes = (size_t)(alloc_per_tick_mb * 1024.0 * 1024.0);
        if (bytes > 0) {
            char *buf = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (buf != MAP_FAILED) {
                for (size_t off = 0; off < bytes; off += page_size) {
                    buf[off] = (char)(off & 0xff);
                }
                total_allocated_mb += (double)bytes / (1024.0 * 1024.0);
            }
        }

        usleep((useconds_t)(tick_s * 1e6));

        clock_gettime(CLOCK_MONOTONIC, &now);
        elapsed =
            (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
    }

    if (stats_out) {
        FILE *f = fopen(stats_out, "w");
        if (f) {
            fprintf(f, "---------- Begin Simulation Statistics ----------\n");
            fprintf(f, "sim_insts                     %d\n",
                    (int)(elapsed * 50000000));
            fprintf(f, "sim_seconds                   %.6f\n",
                    elapsed / 1000.0);
            fprintf(f, "host_seconds                  %.6f\n", elapsed);
            fprintf(f, "---------- End Simulation Statistics ----------\n");
            fclose(f);
        }
    }

    printf("Simulation complete. Allocated %.1f MB over %.1f s\n",
           total_allocated_mb, elapsed);
    return 0;
}
