// Every syscall of one file's write, timed on its own and as a whole, on a
// connected Android device (task 4759eb). Not part of the build.
//
// storage_probe.c's `create` rung timed a bare open/write/close/unlink, which
// is not the apply's write and so could not say what a pulled file costs. This
// issues exactly what `LocalAgent.writeFile` issues through dart:io, in the
// same order, and times each call:
//
//   mkdir   the parent, recursively, only for the first file in a directory
//           (the agent remembers the directories it created);
//   open    O_WRONLY|O_CREAT|O_TRUNC, 0666 — dart:io's FileMode.write;
//   write   the bytes in 64 KiB writes, as the stream's chunks arrive;
//   close;
//   mstat   the stat dart:io's setLastModified takes to keep atime;
//   utime   utimensat with that atime and the new mtime;
//   chmod   the source's mode;
//   stat    what the reply carries back.
//
// `total` is those summed for one file; `wall` is the run's elapsed time over
// the file count, which is what concurrency buys. A tree of `files` files, 30
// to a directory like the apply harness's, sizes drawn exponentially about
// `mean` bytes and seeded. `fresh` expects the tree gone (the runner removes it,
// untimed); `overwrite` expects it there.
//
// `spread` (the optional last argument) deals consecutive files to different
// directories rather than filling one directory at a time, so files being
// written at once sit in different directories.
//
//   write_ops_probe <threads> <root> <files> <fresh|overwrite> [mean] [spread]
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum op { MKDIR, OPEN, WRITE, CLOSE, MSTAT, UTIME, CHMOD, STAT, TOTAL, OPS };
static const char *op_names[OPS] = {"mkdir", "open",  "write", "close", "mstat",
                                    "utime", "chmod", "stat",  "total"};

#define PER_DIR 30
#define CHUNK 65536

static const char *root;
static long files;
static long *sizes;
static double *took; // files x OPS, µs; -1 where an op did not run
static atomic_long next_file;
static atomic_int *dir_made;
static atomic_long failures;
static char chunk[CHUNK];
static long dirs;
static int spread;

static double now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static long dir_index(long i) { return spread ? i % dirs : i / PER_DIR; }

static void dir_for(char *out, size_t n, long i) {
  i = dir_index(i) * PER_DIR;
  snprintf(out, n, "%s/d%ld/d%ld", root, i / (PER_DIR * PER_DIR),
           (i / PER_DIR) % PER_DIR);
}

static int mkdirs(const char *path) {
  char buf[512];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    if (mkdir(buf, 0777) && errno != EEXIST) return -1;
    *p = '/';
  }
  return (mkdir(buf, 0777) && errno != EEXIST) ? -1 : 0;
}

static int write_one(long i) {
  double *t = &took[i * OPS];
  for (int o = 0; o < OPS; o++) t[o] = -1;
  char dir[512], path[600];
  dir_for(dir, sizeof dir, i);
  snprintf(path, sizeof path, "%s/f%ld.bin", dir, i);

  double start = now_us(), at = start, then;
#define STEP(o) (then = now_us(), t[o] = then - at, at = then)
  long d = dir_index(i);
  if (atomic_load(&dir_made[d]) == 0) {
    if (mkdirs(dir)) return -1;
    atomic_store(&dir_made[d], 1);
    STEP(MKDIR);
  }
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
  if (fd < 0) return -1;
  STEP(OPEN);
  for (long left = sizes[i]; left > 0;) {
    long n = left < CHUNK ? left : CHUNK;
    if (write(fd, chunk, n) != n) { close(fd); return -1; }
    left -= n;
  }
  STEP(WRITE);
  if (close(fd)) return -1;
  STEP(CLOSE);
  struct stat st;
  if (stat(path, &st)) return -1;
  STEP(MSTAT);
  struct timespec times[2] = {st.st_atim, {.tv_sec = 1700000000, .tv_nsec = 0}};
  if (utimensat(AT_FDCWD, path, times, 0)) return -1;
  STEP(UTIME);
  if (chmod(path, 0644)) return -1;
  STEP(CHMOD);
  if (stat(path, &st)) return -1;
  STEP(STAT);
  t[TOTAL] = at - start;
  return 0;
}

static void *worker(void *unused) {
  (void)unused;
  for (long i; (i = atomic_fetch_add(&next_file, 1)) < files;) {
    if (write_one(i)) atomic_fetch_add(&failures, 1);
  }
  return NULL;
}

static int cmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: write_ops_probe <threads> <root> <files> "
                    "<fresh|overwrite> [mean] [spread]\n");
    return 2;
  }
  int threads = atoi(argv[1]);
  root = argv[2];
  files = atol(argv[3]);
  const char *pass = argv[4];
  double mean = argc > 5 ? atof(argv[5]) : 13007; // SPEC §5.3's mean
  spread = argc > 6 && strcmp(argv[6], "spread") == 0;

  sizes = malloc(files * sizeof *sizes);
  srand48(4759);
  for (long i = 0; i < files; i++) {
    long s = lround(-log(1 - drand48()) * mean);
    sizes[i] = s < 1 ? 1 : s;
  }
  memset(chunk, 0x5a, sizeof chunk);
  took = malloc(files * OPS * sizeof *took);
  dirs = (files + PER_DIR - 1) / PER_DIR;
  dir_made = calloc(dirs, sizeof *dir_made);
  if (strcmp(pass, "overwrite") == 0) {
    for (long d = 0; d < dirs; d++) dir_made[d] = 1; // already there
  }

  pthread_t pool[256];
  double start = now_us();
  for (int w = 0; w < threads; w++) pthread_create(&pool[w], NULL, worker, NULL);
  for (int w = 0; w < threads; w++) pthread_join(pool[w], NULL);
  double wall = now_us() - start;

  printf("RESULT layout=%s pass=%s threads=%d files=%ld failures=%ld wall_us_per_file=%.0f\n",
         spread ? "spread" : "grouped", pass, threads, files, (long)failures, wall / files);
  double *col = malloc(files * sizeof *col);
  for (int o = 0; o < OPS; o++) {
    long n = 0;
    double sum = 0;
    for (long i = 0; i < files; i++) {
      double v = took[i * OPS + o];
      if (v < 0) continue;
      col[n++] = v;
      sum += v;
    }
    if (n == 0) continue;
    qsort(col, n, sizeof *col, cmp);
    printf("OP pass=%s threads=%d op=%s n=%ld mean=%.0f p50=%.0f p99=%.0f "
           "per_file=%.0f\n",
           pass, threads, op_names[o], n, sum / n, col[n / 2],
           col[(long)(n * 0.99)], sum / files);
  }
  return failures ? 1 : 0;
}
