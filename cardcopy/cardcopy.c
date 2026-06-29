/*
 * cardcopy — native macOS copy engine for CardRunner
 *
 * Copies file data with Apple's fcopyfile() — the same overlapped/pipelined
 * engine cp and Finder use — so the source reader never stalls between blocks.
 * (An earlier hand-rolled read-then-write loop serialized I/O and collapsed a
 * ~1900 MB/s CFexpress reader to ~70 MB/s; fcopyfile restores full speed.)
 * Progress is driven by copyfile's own status callback (COPYFILE_STATE_COPIED),
 * which reports real bytes moved — not page-cache st_size — so reported speed is
 * accurate. SHA-256 verification runs on a serial GCD queue, overlapping with
 * the NEXT file's copy so verification is effectively free.
 *
 * Output (stdout) — matches CardRunner's existing progress parser exactly:
 *   PROGRESS_FILE size=<bytes> <filename>   — before each file starts
 *   <bytes> <pct>%  <speed>  <eta>          — live progress (250ms cadence)
 *   VERIFY_OK <filename> <sha256>           — after successful verify
 *
 * Output (stderr) — matches strings CardRunner.sh already greps for:
 *   No space left on device
 *   Permission denied writing to <dest>
 *   VERIFY_FAIL <filename>                  — integrity mismatch
 *
 * Exit codes: 0 = all files copied and verified, 1 = any failure.
 *
 * Usage:
 *   cardcopy [--ignore-existing] [--partial-dir=NAME] [--concurrency=N] SRC... DEST/
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/time.h>
#include <sys/clonefile.h>
#include <copyfile.h>
#include <dispatch/dispatch.h>
#include <libgen.h>
#include <time.h>
#include <CommonCrypto/CommonDigest.h>

// ── Constants ─────────────────────────────────────────────────────────────────

#define CARDCOPY_VERSION    "1.2.0"
#define PARTIAL_DIR_DEFAULT ".cardrunner_partial"
#define HASH_BUF_SIZE       (4 * 1024 * 1024)  // 4MB chunks for SHA-256
#define SHA256_HEX_LEN      65              // 64 hex chars + NUL

// ── Globals ───────────────────────────────────────────────────────────────────

static bool           g_ignore_existing = false;
static bool           g_no_verify       = false;  // --no-verify: skip SHA-256 (default: verify on)
static char           g_partial_dir_name[256] = PARTIAL_DIR_DEFAULT;
static _Atomic int    g_failures = 0;
static pthread_mutex_t g_out_lock = PTHREAD_MUTEX_INITIALIZER;
static int            g_concurrency     = 1;      // --concurrency=N: parallel file copies (default 1 = sequential)
static pthread_mutex_t g_name_lock = PTHREAD_MUTEX_INITIALIZER;  // serializes final-name reservation

// ── Final-name reservation hash set ───────────────────────────────────────────
// Open-addressing hash set (FNV-1a, linear probing, ≤0.5 load factor).
// Replaces a linear-scan array that was O(N²) for N files into one folder.
// Guarded by g_name_lock so two concurrent workers never claim the same name.
#define CLAIMED_INIT_CAP 256u

static char   **g_claimed_keys = NULL;
static size_t   g_claimed_n    = 0;
static size_t   g_claimed_cap  = 0;

static uint32_t fnv1a32(const char *s) {
    uint32_t h = 2166136261u;
    while (*s) { h ^= (uint8_t)*s++; h *= 16777619u; }
    return h;
}

static bool claimed_contains(const char *p) {
    if (!g_claimed_cap) return false;
    size_t mask = g_claimed_cap - 1;
    size_t i = fnv1a32(p) & mask;
    while (g_claimed_keys[i]) {
        if (strcmp(g_claimed_keys[i], p) == 0) return true;
        i = (i + 1) & mask;
    }
    return false;
}

static void claimed_add(const char *p) {
    // Grow at 50% load to keep average probe length near 1.
    if (!g_claimed_cap || g_claimed_n * 2 >= g_claimed_cap) {
        size_t new_cap = g_claimed_cap ? g_claimed_cap * 2 : CLAIMED_INIT_CAP;
        char **new_keys = calloc(new_cap, sizeof(char *));
        if (!new_keys) return;
        if (g_claimed_keys) {
            size_t mask = new_cap - 1;
            for (size_t j = 0; j < g_claimed_cap; j++) {
                if (!g_claimed_keys[j]) continue;
                size_t k = fnv1a32(g_claimed_keys[j]) & mask;
                while (new_keys[k]) k = (k + 1) & mask;
                new_keys[k] = g_claimed_keys[j];
            }
            free(g_claimed_keys);
        }
        g_claimed_keys = new_keys;
        g_claimed_cap  = new_cap;
    }
    char *dup = strdup(p);
    if (!dup) return;
    size_t mask = g_claimed_cap - 1;
    size_t i = fnv1a32(p) & mask;
    while (g_claimed_keys[i]) i = (i + 1) & mask;
    g_claimed_keys[i] = dup;
    g_claimed_n++;
}

// ── Safe basename (no static buffer) ─────────────────────────────────────────

static const char *file_name(const char *path) {
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

// ── Thread-safe stdout line emit ─────────────────────────────────────────────

static void emit_line(const char *line) {
    pthread_mutex_lock(&g_out_lock);
    puts(line);
    fflush(stdout);
    pthread_mutex_unlock(&g_out_lock);
}

static void emit_err(const char *line) {
    pthread_mutex_lock(&g_out_lock);
    fputs(line, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    pthread_mutex_unlock(&g_out_lock);
}

// ── Speed / ETA formatters ────────────────────────────────────────────────────

static void fmt_speed(double bps, char *buf, size_t sz) {
    if      (bps >= 1073741824.0) snprintf(buf, sz, "%.2fGB/s", bps / 1073741824.0);
    else if (bps >= 1048576.0)    snprintf(buf, sz, "%.2fMB/s", bps / 1048576.0);
    else if (bps >= 1024.0)       snprintf(buf, sz, "%.2fkB/s", bps / 1024.0);
    else                          snprintf(buf, sz, "%.0fB/s",  bps);
}

static void fmt_eta(double remaining_bytes, double bps, char *buf, size_t sz) {
    if (bps <= 0) { snprintf(buf, sz, "--:--"); return; }
    int secs = (int)(remaining_bytes / bps);
    if (secs < 0 || secs > 86400) { snprintf(buf, sz, "--:--"); return; }
    int h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60;
    if (h > 0) snprintf(buf, sz, "%d:%02d:%02d", h, m, s);
    else       snprintf(buf, sz, "%d:%02d", m, s);
}

// Emit a progress line in the exact format parseProgress() expects:
//   "  12345678 45%  234.56MB/s  0:00:03"
static void emit_progress(int id, bool tagged, off_t copied, off_t total, double bps) {
    char speed[32], eta[16], line[160];
    fmt_speed(bps, speed, sizeof(speed));
    fmt_eta((double)(total - copied), bps, eta, sizeof(eta));
    int pct = (total > 0) ? (int)((copied * 100LL) / total) : 0;
    if (tagged)
        snprintf(line, sizeof(line), "id=%d %15lld %3d%%  %s  %s",
                 id, (long long)copied, pct, speed, eta);
    else
        snprintf(line, sizeof(line), "%15lld %3d%%  %s  %s",
                 (long long)copied, pct, speed, eta);
    emit_line(line);
}

// ── copyfile progress callback ──────────────────────────────────────────────
//
// The byte-moving work is done by Apple's fcopyfile() — the same engine cp and
// Finder use. It performs overlapped/pipelined reads and writes so the source
// reader never stalls between blocks (a hand-rolled read-then-write loop stalls
// the reader on every block; on a CFexpress reader that drops ~1900 MB/s to
// ~70 MB/s — that was the bug this rewrite fixes).
//
// Progress is driven by copyfile's own status callback, which reports the REAL
// number of bytes copied (COPYFILE_STATE_COPIED). The old design polled st_size
// on the dest temp file, which reflects bytes accepted into the page cache (not
// bytes actually moved) and overstated the live speed. The callback is the
// authoritative count, so the speed CardRunner shows is now trustworthy.

static double mono_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

typedef struct {
    off_t  total_bytes;
    double last_t;
    off_t  last_bytes;
    double smoothed;
    int    id;
    bool   tagged;
} ProgressCtx;

static int copy_status_cb(int what, int stage, copyfile_state_t state,
                          const char *src, const char *dst, void *ctx) {
    (void)src; (void)dst;
    if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        ProgressCtx *p = (ProgressCtx *)ctx;
        off_t copied = 0;
        if (copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied) != 0)
            return COPYFILE_CONTINUE;

        double now = mono_now();
        double dt  = now - p->last_t;
        // Throttle emission to ~4 Hz, matching the old poller's cadence so the
        // Swift parser and sparkline behave identically.
        if (dt >= 0.25) {
            if (copied > p->last_bytes && dt > 0) {
                double instant = (double)(copied - p->last_bytes) / dt;
                p->smoothed = (p->smoothed == 0.0) ? instant
                                                   : (0.3 * instant + 0.7 * p->smoothed);
            }
            if (copied > 0 && p->smoothed > 0)
                emit_progress(p->id, p->tagged, copied, p->total_bytes, p->smoothed);
            p->last_t     = now;
            p->last_bytes = copied;
        }
    }
    return COPYFILE_CONTINUE;
}

// ── APFS detection ────────────────────────────────────────────────────────────

static bool path_is_apfs(const char *path) {
    struct statfs sfs;
    return (statfs(path, &sfs) == 0 && strcmp(sfs.f_fstypename, "apfs") == 0);
}

// ── SHA-256 of a file ─────────────────────────────────────────────────────────

static bool sha256_file(const char *path, char hex[SHA256_HEX_LEN]) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return false;
    fcntl(fd, F_NOCACHE, 1);   // verify pass must not pollute the page cache

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    uint8_t *buf = malloc(HASH_BUF_SIZE);
    if (!buf) { close(fd); return false; }

    ssize_t n;
    bool ok = true;
    while ((n = read(fd, buf, HASH_BUF_SIZE)) > 0)
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    if (n < 0) ok = false;

    free(buf);
    close(fd);
    if (!ok) return false;

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        sprintf(hex + i * 2, "%02x", digest[i]);
    hex[64] = '\0';
    return true;
}

// ── Core copy function ────────────────────────────────────────────────────────

typedef struct {
    char src[PATH_MAX];
    char dest_dir[PATH_MAX];
    char partial_dir[PATH_MAX];  // full path: dest_dir/.cardrunner_partial
    dispatch_queue_t verify_q;   // serial queue for async verification
    int  id;                     // file index — emitted as id=<n> when tagged
    bool tagged;                 // true at concurrency>1: prefix lines with id=<n>
} CopyJob;

// ── Final-name reservation (thread-safe) ──────────────────────────────────────
// Resolves the destination name for one source file and reserves it atomically
// under g_name_lock. Folds together the three cases the engine must handle:
//   • identical file already present  → SKIP_EXISTING (only when --ignore-existing)
//   • a DIFFERENT file owns the name   → auto-rename _001/_002 + COLLISION_RENAMED
//     (GoPro 100GOPRO/101GOPRO chapters, Canon multi-folder, Sony dual-slot, two
//      operators on the same camera model)
//   • name free + unclaimed            → take it
// Because the check-and-claim is one locked critical section, two concurrent
// workers can never commit two distinct files to the same name. At concurrency==1
// the lock is uncontended and the decisions are identical to the sequential
// engine that shipped.
//
// Returns 1 = skip (file already complete; SKIP line already emitted),
//         0 = proceed (out_dest / out_temp filled in).
static int reserve_final_name(const CopyJob *job, const struct stat *src_stat,
                              const char *orig_fname,
                              char out_dest[PATH_MAX], char out_temp[PATH_MAX]) {
    const char *dot = strrchr(orig_fname, '.');
    char base[PATH_MAX], ext[PATH_MAX] = "";
    if (dot && dot != orig_fname) {
        snprintf(base, sizeof(base), "%.*s", (int)(dot - orig_fname), orig_fname);
        snprintf(ext,  sizeof(ext),  "%s", dot);
    } else {
        snprintf(base, sizeof(base), "%s", orig_fname);
    }

    int result = 0;
    pthread_mutex_lock(&g_name_lock);
    for (int n = 0; n < 1000; n++) {
        char cand[PATH_MAX], cdest[PATH_MAX], ctemp[PATH_MAX];
        if (n == 0) snprintf(cand, sizeof(cand), "%s", orig_fname);
        else        snprintf(cand, sizeof(cand), "%s_%03d%s", base, n, ext);
        snprintf(cdest, sizeof(cdest), "%s/%s", job->dest_dir,    cand);
        snprintf(ctemp, sizeof(ctemp), "%s/%s", job->partial_dir, cand);

        if (claimed_contains(cdest)) continue;   // another in-flight job owns it

        struct stat ex;
        if (stat(cdest, &ex) == 0) {
            bool same = (ex.st_size == src_stat->st_size &&
                         ex.st_mtimespec.tv_sec == src_stat->st_mtimespec.tv_sec);
            if (same) {
                if (g_ignore_existing) {
                    char line[PATH_MAX + 32];
                    if (job->tagged) snprintf(line, sizeof(line), "SKIP_EXISTING id=%d %s", job->id, cand);
                    else             snprintf(line, sizeof(line), "SKIP_EXISTING %s", cand);
                    emit_line(line);
                    result = 1;
                } else {
                    claimed_add(cdest);
                    snprintf(out_dest, PATH_MAX, "%s", cdest);
                    snprintf(out_temp, PATH_MAX, "%s", ctemp);
                    result = 0;
                }
                goto done;
            }
            continue;   // different file owns this name → try the next suffix
        }

        // Name is free on disk and unclaimed → take it.
        claimed_add(cdest);
        snprintf(out_dest, PATH_MAX, "%s", cdest);
        snprintf(out_temp, PATH_MAX, "%s", ctemp);
        if (n > 0) {
            char note[PATH_MAX * 2 + 48];
            if (job->tagged) snprintf(note, sizeof(note), "COLLISION_RENAMED id=%d %s %s", job->id, orig_fname, cand);
            else             snprintf(note, sizeof(note), "COLLISION_RENAMED %s %s", orig_fname, cand);
            emit_line(note);   // stdout → Swift progress parser
            emit_err(note);    // stderr → shell captures for log file
        }
        result = 0;
        goto done;
    }
    // All 999 suffixes taken (astronomically unlikely) → fall back to original.
    snprintf(out_dest, PATH_MAX, "%s/%s", job->dest_dir,    orig_fname);
    snprintf(out_temp, PATH_MAX, "%s/%s", job->partial_dir, orig_fname);
    claimed_add(out_dest);
done:
    pthread_mutex_unlock(&g_name_lock);
    return result;
}

static int copy_one(const CopyJob *job) {
    const char *fname = file_name(job->src);

    // ── Source stat ───────────────────────────────────────────────────
    struct stat src_stat;
    if (stat(job->src, &src_stat) != 0) {
        char err[PATH_MAX + 64];
        snprintf(err, sizeof(err), "cardcopy: cannot stat %s: %s", job->src, strerror(errno));
        emit_err(err);
        return -1;
    }
    off_t file_size = src_stat.st_size;

    // ── Reserve a unique final name (thread-safe; see reserve_final_name) ──
    char dest_path[PATH_MAX], temp_path[PATH_MAX];
    if (reserve_final_name(job, &src_stat, fname, dest_path, temp_path) == 1)
        return 0;   // identical file already present — skip line already emitted
    fname = file_name(dest_path);   // may have been suffixed by collision rename

    // ── Announce file to Swift progress parser ────────────────────────
    {
        char ann[PATH_MAX + 64];
        if (job->tagged)
            snprintf(ann, sizeof(ann), "PROGRESS_FILE id=%d size=%lld %s", job->id, (long long)file_size, fname);
        else
            snprintf(ann, sizeof(ann), "PROGRESS_FILE size=%lld %s", (long long)file_size, fname);
        emit_line(ann);
    }

    // ── APFS → APFS: instant copy-on-write clone ──────────────────────
    // Apple's clonefile() makes an instant copy-on-write clone when source and
    // destination are on the same APFS volume (the same fast path Finder uses
    // for same-volume copies). For card ingest the source is exFAT and the dest
    // is APFS, so this never triggers and we go straight to fcopyfile below.
    bool used_clone = false;
    if (path_is_apfs(job->src) && path_is_apfs(job->dest_dir)) {
        // F10: clone into temp_path then rename — same atomic invariant as the
        // fcopyfile path. Never unlink dest_path before we have a complete copy:
        // if the clone fails after an unlink the file would simply be gone.
        unlink(temp_path);  // temp slot must be clear for clonefile
        if (clonefile(job->src, temp_path, 0) == 0) {
            // Preserve source timestamps on the temp file before rename
            struct timeval _tv[2];
            _tv[0].tv_sec  = (long)src_stat.st_atimespec.tv_sec;
            _tv[0].tv_usec = (int)(src_stat.st_atimespec.tv_nsec / 1000);
            _tv[1].tv_sec  = (long)src_stat.st_mtimespec.tv_sec;
            _tv[1].tv_usec = (int)(src_stat.st_mtimespec.tv_nsec / 1000);
            utimes(temp_path, _tv);
            // Atomic rename temp → final (same invariant as the fcopyfile path)
            if (rename(temp_path, dest_path) == 0) {
                // Emit a synthetic 100% line so the Swift parser sees completion
                char done[160];
                if (job->tagged) snprintf(done, sizeof(done), "id=%d %15lld 100%%  instant  0:00", job->id, (long long)file_size);
                else             snprintf(done, sizeof(done), "%15lld 100%%  instant  0:00", (long long)file_size);
                emit_line(done);
                used_clone = true;
            } else {
                unlink(temp_path);  // rename failed — clean up staging file
            }
        }
        // If clonefile or rename fails, fall through to the fcopyfile path below
    }

    if (!used_clone) {
        // ── Open source ───────────────────────────────────────────────
        int src_fd = open(job->src, O_RDONLY | O_NOFOLLOW);
        if (src_fd < 0) {
            char err[PATH_MAX + 64];
            snprintf(err, sizeof(err), "cardcopy: open %s: %s", job->src, strerror(errno));
            emit_err(err);
            return -1;
        }

        // ── Open temp destination ─────────────────────────────────────
        int dest_fd = open(temp_path,
                           O_WRONLY | O_CREAT | O_TRUNC,
                           src_stat.st_mode & 0777);
        if (dest_fd < 0) {
            int err_no = errno;
            if (err_no == ENOSPC)
                emit_err("No space left on device");
            else if (err_no == EACCES || err_no == EPERM) {
                char err[PATH_MAX + 32];
                snprintf(err, sizeof(err), "Permission denied writing to %s", job->dest_dir);
                emit_err(err);
            } else {
                char err[PATH_MAX + 64];
                snprintf(err, sizeof(err), "cardcopy: open temp %s: %s", temp_path, strerror(err_no));
                emit_err(err);
            }
            close(src_fd);
            return -1;
        }

        // ── THE COPY — Apple's fcopyfile() ────────────────────────────
        // fcopyfile performs overlapped/pipelined I/O: it streams reads from the
        // source while writes drain to the destination concurrently, so the card
        // reader never stalls between blocks. This is the same engine cp and
        // Finder use. The previous hand-rolled read(16MB)→write(16MB) loop ran
        // serially — every write stalled the reader's pipeline, collapsing a
        // ~1900 MB/s reader to ~70 MB/s. Measured on the same hardware:
        // manual loop 73 MB/s vs fcopyfile/cp 1872 MB/s.
        //
        // Progress comes from copy_status_cb (driven by copyfile's own COPIED
        // counter) — no st_size polling, so reported speed reflects real bytes
        // moved, not page-cache acceptance. COPYFILE_DATA copies only file data;
        // we set timestamps/mode explicitly below (as before) so skip-existing
        // detection (size + mtime) keeps working identically.
        ProgressCtx pctx = {
            .total_bytes = file_size,
            .last_t      = mono_now(),
            .last_bytes  = 0,
            .smoothed    = 0.0,
            .id          = job->id,
            .tagged      = job->tagged,
        };
        copyfile_state_t cstate = copyfile_state_alloc();
        copyfile_state_set(cstate, COPYFILE_STATE_STATUS_CB,  (const void *)copy_status_cb);
        copyfile_state_set(cstate, COPYFILE_STATE_STATUS_CTX, &pctx);

        int copy_result = 0;
        int copy_errno  = 0;
        if (fcopyfile(src_fd, dest_fd, cstate, COPYFILE_DATA) != 0) {
            copy_result = -1;
            copy_errno  = errno;
        }
        copyfile_state_free(cstate);

        // Preserve source timestamps — required for skip-existing detection
        // (CardRunner compares st_size AND st_mtimespec to decide whether a
        // destination file is already complete).
        if (copy_result == 0) {
            struct timeval tv[2];
            tv[0].tv_sec  = (long)src_stat.st_atimespec.tv_sec;
            tv[0].tv_usec = (int)(src_stat.st_atimespec.tv_nsec / 1000);
            tv[1].tv_sec  = (long)src_stat.st_mtimespec.tv_sec;
            tv[1].tv_usec = (int)(src_stat.st_mtimespec.tv_nsec / 1000);
            futimes(dest_fd, tv);
            fchmod(dest_fd, src_stat.st_mode & 0777);
            // Flush dirty pages to the device before rename. This guarantees
            // that any file at its final path reflects durable bytes — so a
            // SHA-256 verify after rename cannot silently pass on cache-only
            // data. Per-file fsync is cheap (~0–2 ms on NVMe). The one-time
            // F_FULLFSYNC in main() forces the NAND/platter commit barrier.
            if (fsync(dest_fd) != 0) {
                emit_err("cardcopy: fsync failed before rename");
                close(src_fd); close(dest_fd); unlink(temp_path);
                return -1;
            }
        }

        close(src_fd);
        close(dest_fd);

        if (copy_result != 0) {
            unlink(temp_path);
            if (copy_errno == ENOSPC)
                emit_err("No space left on device");
            else if (copy_errno == EACCES || copy_errno == EPERM) {
                char err[PATH_MAX + 32];
                snprintf(err, sizeof(err), "Permission denied writing to %s", job->dest_dir);
                emit_err(err);
            } else {
                char err[128];
                snprintf(err, sizeof(err), "cardcopy: write failed: %s", strerror(copy_errno));
                emit_err(err);
            }
            return -1;
        }

        // Emit final 100% line
        {
            char done[160];
            if (job->tagged) snprintf(done, sizeof(done), "id=%d %15lld 100%%  done  0:00", job->id, (long long)file_size);
            else             snprintf(done, sizeof(done), "%15lld 100%%  done  0:00", (long long)file_size);
            emit_line(done);
        }

        // Atomic rename: temp → final path.
        // At no point does a partial file exist at the destination path.
        //
        // Retry up to 3 times on ENOENT with a 150ms pause between attempts.
        // External drives (USB/Thunderbolt HDD) can have a brief dropout or
        // spin-down just as the rename fires — the write completes into the OS
        // buffer, macOS reports success, the drive reconnects, but the partial
        // file's directory entry is momentarily gone.  A short wait lets the
        // filesystem settle before we declare a permanent failure.
        // F7: exponential backoff on ENOENT — external drives (USB/Thunderbolt)
        // can have a brief dropout between the write completing and the directory
        // being addressable. 6 retries × doubling from 150 ms caps at ~9.6 s total.
        {
            int       _rename_tries = 0;
            useconds_t _backoff     = 150000;   // 150 ms, doubles each retry
            while (rename(temp_path, dest_path) != 0) {
                if (errno != ENOENT || ++_rename_tries >= 6) {
                    char err[PATH_MAX * 2 + 64];
                    snprintf(err, sizeof(err),
                             "cardcopy: rename failed %s → %s: %s (after %d attempt%s)",
                             temp_path, dest_path, strerror(errno),
                             _rename_tries, _rename_tries == 1 ? "" : "s");
                    emit_err(err);
                    unlink(temp_path);
                    return -1;
                }
                usleep(_backoff);
                _backoff = (_backoff < 2400000) ? _backoff * 2 : 2400000; // cap at 2.4 s
            }
        }
    }

    // ── Async SHA-256 verification ────────────────────────────────────
    // Dispatched to a serial queue — runs concurrently with the NEXT
    // file's copy so verification costs no wall-clock time.
    // Skipped entirely when --no-verify is passed (default for normal ingests).
    if (g_no_verify) {
        return 0;
    }

    char *src_dup  = strdup(job->src);
    char *dest_dup = strdup(dest_path);
    char *name_dup = strdup(fname);
    int   v_id     = job->id;
    bool  v_tagged = job->tagged;

    if (!src_dup || !dest_dup || !name_dup) {
        free(src_dup); free(dest_dup); free(name_dup);
        emit_err("cardcopy: out of memory during verify setup");
        return -1;
    }

    dispatch_async(job->verify_q, ^{
        char src_hash[SHA256_HEX_LEN], dst_hash[SHA256_HEX_LEN];
        bool src_ok  = sha256_file(src_dup,  src_hash);
        bool dest_ok = sha256_file(dest_dup, dst_hash);
        char msg[PATH_MAX + 80];

        if (src_ok && dest_ok && strcmp(src_hash, dst_hash) == 0) {
            if (v_tagged) snprintf(msg, sizeof(msg), "VERIFY_OK id=%d %s %s", v_id, name_dup, dst_hash);
            else          snprintf(msg, sizeof(msg), "VERIFY_OK %s %s", name_dup, dst_hash);
            emit_line(msg);
        } else {
            if (v_tagged) snprintf(msg, sizeof(msg), "VERIFY_FAIL id=%d %s", v_id, name_dup);
            else          snprintf(msg, sizeof(msg), "VERIFY_FAIL %s", name_dup);
            emit_err(msg);
            atomic_fetch_add(&g_failures, 1);
        }

        free(src_dup);
        free(dest_dup);
        free(name_dup);
    });

    return 0;
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(int argc, char **argv) {
    // ── Quick-exit flags (no file args required) ──────────────────────
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("cardcopy %s\n", CARDCOPY_VERSION);
        return 0;
    }

    if (argc < 3) {
        fprintf(stderr,
            "cardcopy %s — CardRunner native copy engine\n"
            "Usage: cardcopy [--ignore-existing] [--no-verify] [--partial-dir=NAME] [--concurrency=N] SRC... DEST/\n",
            CARDCOPY_VERSION);
        return 1;
    }

    // ── Parse flags ───────────────────────────────────────────────────
    int first_file = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--ignore-existing") == 0) {
            g_ignore_existing = true;
            first_file = i + 1;
        } else if (strcmp(argv[i], "--no-verify") == 0) {
            g_no_verify = true;
            first_file = i + 1;
        } else if (strncmp(argv[i], "--partial-dir=", 14) == 0) {
            strncpy(g_partial_dir_name, argv[i] + 14, sizeof(g_partial_dir_name) - 1);
            first_file = i + 1;
        } else if (strncmp(argv[i], "--concurrency=", 14) == 0) {
            int _c = atoi(argv[i] + 14);
            if (_c < 1) _c = 1;
            if (_c > 8) _c = 8;   // destination write bus saturates well before this
            g_concurrency = _c;
            first_file = i + 1;
        } else {
            // First non-flag argument — files start here
            first_file = i;
            break;
        }
    }

    if (argc - first_file < 2) {
        fprintf(stderr, "cardcopy: need at least one source file and a destination\n");
        return 1;
    }

    // Last argument is the destination directory.
    // Strip ALL trailing slashes (F7: shell sometimes passes "dest//") so
    // snprintf("%s/%s", dest_dir, name) never produces doubled slashes.
    char dest_dir_buf[PATH_MAX];
    strncpy(dest_dir_buf, argv[argc - 1], PATH_MAX - 1);
    dest_dir_buf[PATH_MAX - 1] = '\0';
    size_t _dlen = strlen(dest_dir_buf);
    while (_dlen > 1 && dest_dir_buf[_dlen - 1] == '/')
        dest_dir_buf[--_dlen] = '\0';
    const char *dest_dir = dest_dir_buf;

    int src_count = argc - first_file - 1;
    char **src_files = &argv[first_file];

    // ── Validate destination ──────────────────────────────────────────
    struct stat dst_st;
    if (stat(dest_dir, &dst_st) != 0 || !S_ISDIR(dst_st.st_mode)) {
        fprintf(stderr, "cardcopy: destination is not a directory: %s\n", dest_dir);
        return 1;
    }

    // ── Create partial directory ──────────────────────────────────────
    char partial_dir[PATH_MAX];
    snprintf(partial_dir, PATH_MAX, "%s/%s", dest_dir, g_partial_dir_name);
    if (mkdir(partial_dir, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "cardcopy: cannot create partial dir %s: %s\n",
                partial_dir, strerror(errno));
        return 1;
    }

    // ── Verification queue (serial — one verify at a time, overlaps copies) ─
    dispatch_queue_t verify_q =
        dispatch_queue_create("com.cardrunner.cardcopy.verify", DISPATCH_QUEUE_SERIAL);

    // ── Copy files ────────────────────────────────────────────────────
    // Default (concurrency == 1): sequential — byte-for-byte identical output
    // to the engine that shipped, so the current Swift parser and UI are
    // unaffected. The verify of file N overlaps the copy of file N+1, so
    // verification still costs no wall-clock time.
    //
    // concurrency > 1: dispatch up to N copies in parallel across a GCD pool,
    // bounded by a semaphore so at most N are in flight. Progress/verify/skip/
    // collision lines are id=<n>-tagged (see reserve_final_name + emit sites)
    // so a future UI can attribute interleaved output to the right file. This
    // path is DORMANT until something passes --concurrency=N>1; the shipping
    // shell never does, so nothing changes in production today.
    if (g_concurrency <= 1) {
        for (int i = 0; i < src_count; i++) {
            CopyJob job;
            // F9: explicitly NUL-terminate — strncpy leaves the last byte
            // uninitialised if the source is exactly PATH_MAX-1 chars long.
            strncpy(job.src,         src_files[i], PATH_MAX - 1); job.src[PATH_MAX-1]         = '\0';
            strncpy(job.dest_dir,    dest_dir,     PATH_MAX - 1); job.dest_dir[PATH_MAX-1]    = '\0';
            strncpy(job.partial_dir, partial_dir,  PATH_MAX - 1); job.partial_dir[PATH_MAX-1] = '\0';
            job.verify_q = verify_q;
            job.id       = i;
            job.tagged   = false;

            if (copy_one(&job) != 0)
                atomic_fetch_add(&g_failures, 1);
        }
    } else {
        dispatch_queue_t   cq  = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_group_t   grp = dispatch_group_create();
        dispatch_semaphore_t sem = dispatch_semaphore_create(g_concurrency);

        for (int i = 0; i < src_count; i++) {
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

            CopyJob *job = malloc(sizeof *job);
            if (!job) {
                emit_err("cardcopy: out of memory dispatching copy");
                atomic_fetch_add(&g_failures, 1);
                dispatch_semaphore_signal(sem);
                continue;
            }
            strncpy(job->src,         src_files[i], PATH_MAX - 1); job->src[PATH_MAX-1]         = '\0';
            strncpy(job->dest_dir,    dest_dir,     PATH_MAX - 1); job->dest_dir[PATH_MAX-1]    = '\0';
            strncpy(job->partial_dir, partial_dir,  PATH_MAX - 1); job->partial_dir[PATH_MAX-1] = '\0';
            job->verify_q = verify_q;
            job->id       = i;
            job->tagged   = true;

            dispatch_group_async(grp, cq, ^{
                if (copy_one(job) != 0)
                    atomic_fetch_add(&g_failures, 1);
                free(job);
                dispatch_semaphore_signal(sem);
            });
        }

        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
        dispatch_release(grp);
        dispatch_release(sem);
    }

    // ── One-time full barrier ─────────────────────────────────────────────
    // Per-file fsync() above pushes data to the device driver's queue.
    // F_FULLFSYNC forces the device to flush its write-back cache to
    // persistent storage — the only guarantee against power-loss corruption
    // between the OS buffer and the NAND/platter. Runs once per cardcopy
    // invocation (one dest dir), not per file. Ignored on filesystems that
    // don't support it (non-Apple, some network mounts) — best-effort.
    {
        int _dfd = open(dest_dir, O_RDONLY);
        if (_dfd >= 0) {
            fcntl(_dfd, F_FULLFSYNC);
            close(_dfd);
        }
    }

    // Wait for all pending verifications to complete before exiting
    dispatch_sync(verify_q, ^{});
    dispatch_release(verify_q);

    return (atomic_load(&g_failures) > 0) ? 1 : 0;
}
