// What the device's storage will do at all, at the syscall level (tasks 4c55fd,
// 203cfd). Not part of the build, and not Dart.
//
// WHY THIS IS C. Every figure in SPEC §7.2 is a desktop reading through
// `dart:io`, and the desktop ladder established that `dart:io`'s own overhead is
// a property of the VM and of our code — portable, and already measured. What is
// *not* portable is the storage: the pulling phone writes a file in 35.1 ms
// against a desktop destination's 5.0, and `/storage/emulated` on Android is a
// FUSE mount rather than a block device. This probe removes Dart from the
// question entirely and asks the kernel directly, so that the app's numbers have
// a floor to be read against instead of only each other.
//
// WHY IT RUNS AT ALL. Built static for aarch64, it needs no interpreter and so
// runs on bionic under `adb shell` — no APK, no install, no app state touched,
// output straight to the terminal. `dart compile exe --target-os android` is
// advertised by the SDK and unsupported by it; a `linux_arm64` Dart binary wants
// `/lib/ld-linux-aarch64.so.1`, which Android does not have.
//
//   aarch64-linux-gnu-gcc -static -O2 -o storage_probe storage_probe.c -lpthread
//
// See `run_storage_probe.sh`, which builds it, pushes it, sweeps it and cleans up.
//
// THE RUNGS mirror `LocalAgent.writeFile`'s steps (SPEC §7.2, §7.4) so each one
// is the same shape the Dart ladder measures, minus Dart:
//
//   bare      open, one write() of the whole file, close, **over a file that is
//             already there**. The floor.
//   chunked   the same bytes in 64 KiB write() calls — what an `IOSink` fed a
//             64 KiB-capped stream actually issues. Against `bare` this is the
//             per-syscall tax.
//   create    the same write to a path that does **not** exist yet, then unlink.
//             On Android's emulated storage a new file is not a cheaper version
//             of an existing one — MediaProvider has bookkeeping to do — and
//             without this rung that cost hides inside whichever rung ran first.
//   temp      chunked into a temp file, then rename onto the target. Against
//             `create`, this is what the rename costs.
//   temp-reuse  the same sequence, except the temp path is **one per worker**,
//             reused for every file, so it is a new file once rather than once
//             per file. §7.2 names its temp after the target, which makes every
//             copy pay the create this rung pays once. It keeps the rename and
//             so keeps the atomicity; if the create is the cost, this is the fix,
//             and if it is not, this rung says so before anyone writes it.
//   mtime     plus utimensat.
//   mode      plus fchmod.
//   full      plus a stat of the target afterwards. §7.2's whole sequence.
//   fsync     `full` with an fsync before close. Not what §7.2 does — reported
//             because the archive commit does fsync (SPEC §8.2) and the cost of
//             one on this storage is worth knowing next to the rest.
//   statonly  stat() every file and nothing else. Task 203cfd's question: what a
//             lookup costs here, and whether threads make lookups overlap.
//
// DEPTH is worker threads pulling from one shared cursor, which is how `Applier`
// has its writes outstanding — N in flight, each taking the next path when its
// own finishes, rather than N fixed shards where one worker idles early.
//
// EVERY TIMED RUNG OVERWRITES, and the `seed` command is what makes that true.
// The first version of this probe ran the rungs in order against an empty tree,
// so the first rung paid for creating 850 files and every rung after it merely
// truncated — and `bare` read as 16.2 ms a file against `chunked`'s 2.9 when the
// two issue an identical syscall for any file under one chunk. That difference
// was the probe, not the storage. `seed` writes the tree once, untimed, so no
// rung is the one that creates it; `bare` and `chunked` agreeing under
// `--cap 65536` is the control that says so.
//
// ONE LINE OF OUTPUT, `key=value`, because the sweep and the formatting belong in
// the driver: this binary is run dozens of times and should not each time decide
// what a table looks like.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define PATH_MAX_LEN 4096
#define CHUNK_BYTES (64 * 1024)
#define FILES_PER_DIR 100

enum rung {
  R_BARE, R_CHUNKED, R_CREATE, R_TEMP, R_MTIME, R_MODE, R_FULL, R_FSYNC,
  R_TEMP_REUSE, R_STATONLY
};

static const char *rung_names[] = {
  "bare", "chunked", "create", "temp", "mtime", "mode", "full", "fsync",
  "temp-reuse", "statonly"
};

static enum rung rung;
static const char *dir;
static uint64_t *sizes;
static long file_count;
static unsigned char *buffer;   /* as long as the longest file, filled once */
static volatile long cursor;    /* the shared cursor every worker pulls from */
static volatile long failures;
static uint64_t bytes_done;
static pthread_mutex_t tally = PTHREAD_MUTEX_INITIALIZER;

static void path_for(char *out, long index, const char *suffix) {
  snprintf(out, PATH_MAX_LEN, "%s/d%ld/f%ld.bin%s",
           dir, index / FILES_PER_DIR, index, suffix);
}

static long now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* One write() of everything, which is the floor: the fewest syscalls the bytes
   can be delivered in. */
static int write_whole(int fd, uint64_t size) {
  uint64_t off = 0;
  while (off < size) {
    ssize_t n = write(fd, buffer + off, size - off);
    if (n <= 0) return -1;
    off += (uint64_t)n;
  }
  return 0;
}

/* The same bytes in CHUNK_BYTES calls. Separate from write_whole rather than
   parameterised, because the difference between them is the measurement. */
static int write_chunked(int fd, uint64_t size) {
  uint64_t off = 0;
  while (off < size) {
    uint64_t want = size - off;
    if (want > CHUNK_BYTES) want = CHUNK_BYTES;
    ssize_t n = write(fd, buffer + off, want);
    if (n <= 0) return -1;
    off += (uint64_t)n;
  }
  return 0;
}

static int do_one(long index, long worker_id) {
  char target[PATH_MAX_LEN];
  char temp[PATH_MAX_LEN];
  uint64_t size = sizes[index];
  path_for(target, index, "");

  (void)worker_id;
  if (rung == R_STATONLY) {
    struct stat st;
    if (stat(target, &st) != 0) return -1;
    /* Read the fields back, so this is a lookup somebody wanted. */
    return (st.st_size | st.st_mode | (unsigned)st.st_mtime) == 0xFFFFFFFF
        ? -1 : 0;
  }

  int staged = (rung >= R_TEMP);
  const char *open_path = target;
  if (staged) { path_for(temp, index, ".tmp"); open_path = temp; }
  if (rung == R_TEMP_REUSE) {
    /* One path per worker, in the tree root: the same mount, so the rename is
       still atomic, and after the first file it is not a new file. */
    snprintf(temp, PATH_MAX_LEN, "%s/.probe-reuse-%ld", dir, worker_id);
    open_path = temp;
  }
  /* A path nothing has written before, so the cost of a *new* file is this
     rung's and not hidden in whichever rung happened to run first. */
  if (rung == R_CREATE) { path_for(temp, index, ".new"); open_path = temp; }

  int fd = open(open_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;

  int bad = (rung == R_BARE) ? write_whole(fd, size) : write_chunked(fd, size);

  if (!bad && rung >= R_MTIME && rung != R_TEMP_REUSE) {
    /* A fixed timestamp: what is measured is the call, and a per-file value
       would mean reading one first. */
    struct timespec times[2];
    times[0].tv_sec = 1700000000; times[0].tv_nsec = 0;
    times[1] = times[0];
    if (futimens(fd, times) != 0) bad = -1;
  }
  if (!bad && rung >= R_MODE && rung != R_TEMP_REUSE) {
    if (fchmod(fd, 0644) != 0) bad = -1;
  }
  if (!bad && rung == R_FSYNC) {
    if (fsync(fd) != 0) bad = -1;
  }
  if (close(fd) != 0) bad = -1;

  if (!bad && staged) {
    if (rename(temp, target) != 0) bad = -1;
  }
  /* Removed again, so the rung can be run twice and still be measuring a
     create. The unlink is inside the timed region and is the one call this rung
     has that `temp` does not — `temp` consumes its path with the rename. */
  if (rung == R_CREATE) {
    if (unlink(open_path) != 0) bad = -1;
  }
  if (!bad && rung >= R_FULL && rung != R_TEMP_REUSE) {
    struct stat st;
    if (stat(target, &st) != 0) bad = -1;
  }
  if (bad) { unlink(open_path); return -1; }

  pthread_mutex_lock(&tally);
  bytes_done += size;
  pthread_mutex_unlock(&tally);
  return 0;
}

static void *worker(void *id) {
  long worker_id = (long)id;
  for (;;) {
    long index = __atomic_fetch_add(&cursor, 1, __ATOMIC_RELAXED);
    if (index >= file_count) return NULL;
    if (do_one(index, worker_id) != 0) {
      __atomic_fetch_add(&failures, 1, __ATOMIC_RELAXED);
    }
  }
}

/* Reads one decimal size per line. Text rather than a packed struct so the
   driver can produce it with `find -printf` and nothing has to agree on a
   layout. */
static int load_sizes(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  long cap = 1024;
  sizes = malloc((size_t)cap * sizeof *sizes);
  char line[64];
  while (fgets(line, sizeof line, f)) {
    if (file_count == cap) {
      cap *= 2;
      sizes = realloc(sizes, (size_t)cap * sizeof *sizes);
    }
    sizes[file_count++] = strtoull(line, NULL, 10);
  }
  fclose(f);
  return 0;
}

/* Creates every directory the tree needs. Its own command so that no rung pays
   for it: a mkdir per hundred files is small, but it is not the write path. */
static int make_dirs(void) {
  char path[PATH_MAX_LEN];
  mkdir(dir, 0755);
  for (long i = 0; i < file_count; i += FILES_PER_DIR) {
    snprintf(path, sizeof path, "%s/d%ld", dir, i / FILES_PER_DIR);
    if (mkdir(path, 0755) != 0 && errno != EEXIST) return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr,
      "usage: storage_probe <rung|mkdirs|seed> <depth> <dir> <sizes-file>\n"
      "rungs: bare chunked create temp mtime mode full fsync statonly\n");
    return 2;
  }
  const char *want = argv[1];
  long depth = strtol(argv[2], NULL, 10);
  dir = argv[3];
  if (load_sizes(argv[4]) != 0) {
    fprintf(stderr, "cannot read %s\n", argv[4]);
    return 2;
  }
  if (depth < 1) depth = 1;

  if (strcmp(want, "seed") == 0) {
    /* Not timed and not threaded: this is setup, and the point of it is only
       that every timed rung afterwards finds its target already there. */
    char path[PATH_MAX_LEN];
    uint64_t longest_seed = 1;
    for (long i = 0; i < file_count; i++) {
      if (sizes[i] > longest_seed) longest_seed = sizes[i];
    }
    buffer = calloc(1, longest_seed);
    if (!buffer) { fprintf(stderr, "cannot allocate seed buffer\n"); return 1; }
    long made = 0;
    for (long i = 0; i < file_count; i++) {
      path_for(path, i, "");
      int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd < 0) continue;
      if (write_chunked(fd, sizes[i]) == 0) made++;
      close(fd);
    }
    printf("seeded=%ld of=%ld\n", made, file_count);
    return made == file_count ? 0 : 1;
  }

  if (strcmp(want, "mkdirs") == 0) {
    if (make_dirs() != 0) { perror("mkdir"); return 1; }
    printf("dirs=%ld files=%ld\n",
           (file_count + FILES_PER_DIR - 1) / FILES_PER_DIR, file_count);
    return 0;
  }

  rung = (enum rung)-1;
  for (unsigned i = 0; i < sizeof rung_names / sizeof *rung_names; i++) {
    if (strcmp(want, rung_names[i]) == 0) rung = (enum rung)i;
  }
  if ((int)rung < 0) { fprintf(stderr, "unknown rung: %s\n", want); return 2; }

  uint64_t longest = 1;
  for (long i = 0; i < file_count; i++) {
    if (sizes[i] > longest) longest = sizes[i];
  }
  buffer = malloc(longest);
  if (!buffer) { fprintf(stderr, "cannot allocate %llu B\n",
                         (unsigned long long)longest); return 1; }
  /* Not zeros and not random: a filesystem that compresses would make a
     low-entropy buffer cheap, and generating randomness per file would land
     inside the measurement. */
  for (uint64_t i = 0; i < longest; i++) buffer[i] = (unsigned char)(i & 0xFF);

  pthread_t *threads = malloc((size_t)depth * sizeof *threads);
  long started = now_ms();
  for (long i = 0; i < depth; i++) {
    if (pthread_create(&threads[i], NULL, worker, (void *)i) != 0) {
      fprintf(stderr, "pthread_create failed at %ld\n", i);
      depth = i;
      break;
    }
  }
  for (long i = 0; i < depth; i++) pthread_join(threads[i], NULL);
  long elapsed = now_ms() - started;

  printf("rung=%s depth=%ld files=%ld bytes=%llu ms=%ld failures=%ld\n",
         rung_names[rung], depth, file_count,
         (unsigned long long)bytes_done, elapsed, failures);
  return failures > 0 && (long)bytes_done == 0 ? 1 : 0;
}
