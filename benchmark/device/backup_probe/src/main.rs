//! What keeping a file's old version costs, on the device, before the write
//! in place overwrites it. Not part of the build.
//!
//! SPEC §7.2 writes a copy in place; an opt-in backup would keep what it
//! overwrites. On Android's FUSE storage creating a file costs ~20 ms where
//! overwriting one costs ~3, so where the old version goes decides whether
//! the feature is affordable there. Each rung below is one answer, timed with
//! the same overwrite behind it:
//!
//!   overwrite       the write in place alone: open with truncate, the bytes
//!                   in 64 KiB writes, the mtime, close, the closing stat
//!                   (`file_write.rs`'s calls; the mode step is left out, it
//!                   is settled once per root and skipped on FUSE). The
//!                   baseline.
//!   read            read the old file, nothing else. What a copy-based
//!                   backup pays before storing anything.
//!   read-overwrite  read, then overwrite. The control for the two below:
//!                   each adds only its store step.
//!   copy-aside      read, write the old bytes as a new file under the store
//!                   (laid out as `layout` says), then overwrite.
//!   sqlite          read, insert the old bytes as 64 KiB rows into one
//!                   SQLite database (WAL) at the store, then overwrite. One
//!                   thread owns the connection and commits whatever the
//!                   writers have queued in one transaction (at most 64), and
//!                   a writer overwrites only once its backup has committed.
//!   rename-aside    rename the old file into the store, then write the
//!                   target as a new file. No read. The store must be on the
//!                   same mount.
//!
//! `layout` is where a file-based rung puts a version under the store:
//! `mirror`, a tree shaped like the replica's (30 a directory), or `flat`,
//! every version in the store's one directory. SQLite ignores it.
//!
//! `sync` is `none` or `full`: whether a stored version is on disk before the
//! overwrite starts (`sync_data` for copy-aside, `synchronous=FULL` for
//! sqlite). It applies to those two only.
//!
//! The old file has to be read *cold*: the scan's fast path only stats it, so
//! nothing has read it recently. `evict` flushes and drops every file's page
//! cache (`posix_fadvise(DONTNEED)`), and the driver runs it before every
//! timed rung. On FUSE that drops the FUSE inode's cache only, so the driver
//! also times a warm `read` to show whether eviction did anything there.
//!
//! Workers pull the next file from one shared cursor, as the writer pool
//! takes the next queued file. One line of `key=value` output per command;
//! the table is the driver's job (`../run_backup_probe.sh`).

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

const CHUNK: usize = 64 * 1024;
/// SPEC §7.2's apply measurements put 30 files in a directory.
const FILES_PER_DIR: usize = 30;
/// The most backups one transaction carries, as a commit batch does.
const BATCH: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Rung {
    Overwrite,
    Read,
    ReadOverwrite,
    CopyAside,
    Sqlite,
    RenameAside,
}

impl Rung {
    fn parse(name: &str) -> Option<Rung> {
        Some(match name {
            "overwrite" => Rung::Overwrite,
            "read" => Rung::Read,
            "read-overwrite" => Rung::ReadOverwrite,
            "copy-aside" => Rung::CopyAside,
            "sqlite" => Rung::Sqlite,
            "rename-aside" => Rung::RenameAside,
            _ => return None,
        })
    }
}

struct Corpus {
    tree: PathBuf,
    sizes: Vec<usize>,
}

impl Corpus {
    fn load(tree: &str, sizes: &str) -> io::Result<Corpus> {
        let sizes = fs::read_to_string(sizes)?
            .lines()
            .filter_map(|line| line.trim().parse().ok())
            .collect();
        Ok(Corpus {
            tree: PathBuf::from(tree),
            sizes,
        })
    }

    fn relative(index: usize) -> PathBuf {
        PathBuf::from(format!("d{}/f{index}.bin", index / FILES_PER_DIR))
    }

    fn path(&self, index: usize) -> PathBuf {
        self.tree.join(Corpus::relative(index))
    }

    fn make_dirs(&self, root: &Path) -> io::Result<()> {
        for index in (0..self.sizes.len()).step_by(FILES_PER_DIR) {
            fs::create_dir_all(root.join(format!("d{}", index / FILES_PER_DIR)))?;
        }
        Ok(())
    }
}

/// Where the old versions go.
struct Store {
    root: PathBuf,
    flat: bool,
}

impl Store {
    fn version(&self, index: usize) -> PathBuf {
        if self.flat {
            self.root.join(format!("f{index}.bin"))
        } else {
            self.root.join(Corpus::relative(index))
        }
    }
}

/// What the timed region adds up, per step, across every worker.
#[derive(Default)]
struct Tally {
    bytes: AtomicU64,
    read_us: AtomicU64,
    store_us: AtomicU64,
    write_us: AtomicU64,
    failures: AtomicU64,
    first_error: Mutex<Option<String>>,
}

impl Tally {
    fn add(counter: &AtomicU64, since: Instant) -> Instant {
        let now = Instant::now();
        counter.fetch_add((now - since).as_micros() as u64, Ordering::Relaxed);
        now
    }

    fn fail(&self, index: usize, error: io::Error) {
        self.failures.fetch_add(1, Ordering::Relaxed);
        let mut first = self.first_error.lock().unwrap();
        if first.is_none() {
            *first = Some(format!("file {index}: {error}"));
        }
    }
}

/// A backup handed to the thread that owns the database.
struct Job {
    path: String,
    data: Vec<u8>,
    done: mpsc::SyncSender<io::Result<()>>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = match args.get(1).map(String::as_str) {
        Some("seed") if args.len() == 4 => seed(&args[2], &args[3]),
        Some("evict") if args.len() == 4 => evict(&args[2], &args[3]),
        Some("run") if args.len() == 9 => run(&args[2..]),
        _ => {
            eprintln!(
                "usage: backup-probe seed <tree> <sizes>\n\
                 \x20      backup-probe evict <tree> <sizes>\n\
                 \x20      backup-probe run <rung> <workers> <tree> <sizes> <store> <mirror|flat> <none|full>\n\
                 rungs: overwrite read read-overwrite copy-aside sqlite rename-aside"
            );
            std::process::exit(2);
        }
    };
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

/// Untimed: writes every file once, so every timed rung finds its target.
fn seed(tree: &str, sizes: &str) -> io::Result<()> {
    let corpus = Corpus::load(tree, sizes)?;
    corpus.make_dirs(&corpus.tree)?;
    let pattern = pattern(&corpus);
    for (index, &size) in corpus.sizes.iter().enumerate() {
        let mut file = File::create(corpus.path(index))?;
        for chunk in pattern[..size].chunks(CHUNK) {
            file.write_all(chunk)?;
        }
    }
    println!("seeded={}", corpus.sizes.len());
    Ok(())
}

/// Untimed: flushes and drops every file's cached pages, so the next read of
/// it is a cold one.
fn evict(tree: &str, sizes: &str) -> io::Result<()> {
    let corpus = Corpus::load(tree, sizes)?;
    for index in 0..corpus.sizes.len() {
        let file = File::open(corpus.path(index))?;
        file.sync_all()?;
        // SAFETY: a plain syscall on a descriptor this function owns.
        let refused = unsafe { libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED) };
        if refused != 0 {
            return Err(io::Error::from_raw_os_error(refused));
        }
    }
    println!("evicted={}", corpus.sizes.len());
    Ok(())
}

fn run(args: &[String]) -> io::Result<()> {
    let rung = Rung::parse(&args[0])
        .ok_or_else(|| io::Error::other(format!("unknown rung: {}", args[0])))?;
    let workers: usize = args[1].parse().map_err(io::Error::other)?;
    let corpus = Corpus::load(&args[2], &args[3])?;
    let store = Store {
        root: PathBuf::from(&args[4]),
        flat: match args[5].as_str() {
            "mirror" => false,
            "flat" => true,
            other => return Err(io::Error::other(format!("unknown layout: {other}"))),
        },
    };
    let full = match args[6].as_str() {
        "none" => false,
        "full" => true,
        other => return Err(io::Error::other(format!("unknown sync: {other}"))),
    };

    fs::create_dir_all(&store.root)?;
    if matches!(rung, Rung::CopyAside | Rung::RenameAside) && !store.flat {
        corpus.make_dirs(&store.root)?;
    }
    let pattern = pattern(&corpus);
    let cursor = AtomicUsize::new(0);
    let tally = Tally::default();
    let commits = AtomicU64::new(0);

    let (jobs, queue) = mpsc::channel::<Job>();
    let database = match rung {
        Rung::Sqlite => Some(open_database(&store.root.join("versions.db"), full)?),
        _ => None,
    };

    let started = Instant::now();
    thread::scope(|scope| {
        if let Some(connection) = database {
            let commits = &commits;
            scope.spawn(move || store_thread(connection, queue, commits));
        } else {
            drop(queue);
        }
        for _ in 0..workers.max(1) {
            let jobs = jobs.clone();
            let (corpus, store, pattern, cursor, tally) = (&corpus, &store, &pattern, &cursor, &tally);
            scope.spawn(move || {
                let (done, reply) = mpsc::sync_channel(1);
                loop {
                    let index = cursor.fetch_add(1, Ordering::Relaxed);
                    if index >= corpus.sizes.len() {
                        return;
                    }
                    let one = One {
                        rung,
                        index,
                        corpus,
                        store,
                        full,
                        pattern,
                        tally,
                        jobs: &jobs,
                        done: &done,
                        reply: &reply,
                    };
                    match one.go() {
                        Ok(()) => {
                            tally.bytes.fetch_add(corpus.sizes[index] as u64, Ordering::Relaxed);
                        }
                        Err(error) => tally.fail(index, error),
                    }
                }
            });
        }
        drop(jobs);
    });
    let elapsed = started.elapsed();

    if let Some(error) = tally.first_error.lock().unwrap().as_ref() {
        eprintln!("first failure: {error}");
    }
    println!(
        "rung={} workers={} files={} bytes={} ms={} read_us={} store_us={} write_us={} commits={} failures={}",
        args[0],
        workers,
        corpus.sizes.len(),
        tally.bytes.load(Ordering::Relaxed),
        elapsed.as_millis(),
        tally.read_us.load(Ordering::Relaxed),
        tally.store_us.load(Ordering::Relaxed),
        tally.write_us.load(Ordering::Relaxed),
        commits.load(Ordering::Relaxed),
        tally.failures.load(Ordering::Relaxed),
    );
    Ok(())
}

/// One file's work under one rung.
struct One<'a> {
    rung: Rung,
    index: usize,
    corpus: &'a Corpus,
    store: &'a Store,
    full: bool,
    pattern: &'a [u8],
    tally: &'a Tally,
    jobs: &'a mpsc::Sender<Job>,
    done: &'a mpsc::SyncSender<io::Result<()>>,
    reply: &'a mpsc::Receiver<io::Result<()>>,
}

impl One<'_> {
    fn go(&self) -> io::Result<()> {
        let target = self.corpus.path(self.index);
        let size = self.corpus.sizes[self.index];
        let tally = self.tally;
        let mut at = Instant::now();

        if self.rung == Rung::RenameAside {
            fs::rename(&target, self.store.version(self.index))?;
            at = Tally::add(&tally.store_us, at);
            write_in_place(&target, &self.pattern[..size], true)?;
            Tally::add(&tally.write_us, at);
            return Ok(());
        }

        let old = match self.rung {
            Rung::Overwrite => None,
            _ => {
                let old = read_whole(&target)?;
                at = Tally::add(&tally.read_us, at);
                Some(old)
            }
        };
        match (self.rung, old) {
            (Rung::CopyAside, Some(old)) => {
                let mut copy = File::create(self.store.version(self.index))?;
                for chunk in old.chunks(CHUNK) {
                    copy.write_all(chunk)?;
                }
                if self.full {
                    copy.sync_data()?;
                }
                drop(copy);
                at = Tally::add(&tally.store_us, at);
            }
            (Rung::Sqlite, Some(old)) => {
                let job = Job {
                    path: Corpus::relative(self.index).to_string_lossy().into_owned(),
                    data: old,
                    done: self.done.clone(),
                };
                self.jobs.send(job).map_err(io::Error::other)?;
                self.reply.recv().map_err(io::Error::other)??;
                at = Tally::add(&tally.store_us, at);
            }
            _ => {}
        }
        if self.rung != Rung::Read {
            write_in_place(&target, &self.pattern[..size], false)?;
            Tally::add(&tally.write_us, at);
        }
        Ok(())
    }
}

/// `file_write.rs`'s in-place write: truncate (or create, when nothing is
/// there), the bytes a chunk at a time, the mtime, close, stat.
fn write_in_place(target: &Path, bytes: &[u8], absent: bool) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).truncate(true);
    if absent {
        options.create(true);
    }
    let mut file = options.open(target)?;
    for chunk in bytes.chunks(CHUNK) {
        file.write_all(chunk)?;
    }
    let _ = file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    drop(file);
    fs::metadata(target)?;
    Ok(())
}

/// The old version, read in 64 KiB reads as the core's source reads are.
fn read_whole(path: &Path) -> io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let mut data = Vec::new();
    let mut chunk = vec![0u8; CHUNK];
    loop {
        let n = file.read(&mut chunk)?;
        if n == 0 {
            return Ok(data);
        }
        data.extend_from_slice(&chunk[..n]);
    }
}

fn open_database(path: &Path, full: bool) -> io::Result<rusqlite::Connection> {
    let connection = rusqlite::Connection::open(path).map_err(io::Error::other)?;
    connection
        .execute_batch(&format!(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous={};
             CREATE TABLE IF NOT EXISTS version(
               id INTEGER PRIMARY KEY, path TEXT NOT NULL, bytes INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS chunk(
               version INTEGER NOT NULL, seq INTEGER NOT NULL, data BLOB NOT NULL,
               PRIMARY KEY(version, seq));",
            if full { "FULL" } else { "NORMAL" }
        ))
        .map_err(io::Error::other)?;
    Ok(connection)
}

/// Owns the connection: takes whatever backups are queued (at most
/// [`BATCH`]), commits them in one transaction, then lets their writers go.
fn store_thread(mut connection: rusqlite::Connection, queue: mpsc::Receiver<Job>, commits: &AtomicU64) {
    while let Ok(first) = queue.recv() {
        let mut batch = vec![first];
        while batch.len() < BATCH {
            match queue.try_recv() {
                Ok(job) => batch.push(job),
                Err(_) => break,
            }
        }
        let outcome = commit(&mut connection, &batch).map_err(|error| error.to_string());
        commits.fetch_add(1, Ordering::Relaxed);
        for job in batch {
            let _ = job.done.send(outcome.clone().map_err(io::Error::other));
        }
    }
}

fn commit(connection: &mut rusqlite::Connection, batch: &[Job]) -> rusqlite::Result<()> {
    let transaction = connection.transaction()?;
    {
        let mut version = transaction.prepare_cached("INSERT INTO version(path, bytes) VALUES (?1, ?2)")?;
        let mut chunk = transaction.prepare_cached("INSERT INTO chunk(version, seq, data) VALUES (?1, ?2, ?3)")?;
        for job in batch {
            version.execute(rusqlite::params![job.path, job.data.len() as i64])?;
            let id = transaction.last_insert_rowid();
            for (seq, data) in job.data.chunks(CHUNK).enumerate() {
                chunk.execute(rusqlite::params![id, seq as i64, data])?;
            }
        }
    }
    transaction.commit()
}

/// Not zeros, so a compressing filesystem cannot make the bytes cheap; built
/// once, outside every timed region.
fn pattern(corpus: &Corpus) -> Vec<u8> {
    let longest = corpus.sizes.iter().copied().max().unwrap_or(0);
    (0..longest).map(|i| (i & 0xFF) as u8).collect()
}
