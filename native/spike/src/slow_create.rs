//! TEST ONLY: a simulation of Android's FUSE storage for local runs. With
//! the `simulate-slow-create` feature and a delay [set], every file create
//! sleeps that long while holding a lock on its parent folder, so creates in
//! one folder serialise and creates in different folders overlap, which is
//! how `/storage/emulated/0` behaves (SPEC §7.2, task 5d8c28). Without the
//! feature, or with no delay set, [around_create] only runs the create.
//!
//! The CLI's hidden `--simulate-create-ms` sets it; the hub never builds
//! the feature.

use std::path::Path;

/// Runs [create] for a file in [folder], behind the simulated delay if one
/// is set.
pub(crate) fn around_create<R>(folder: &Path, create: impl FnOnce() -> R) -> R {
    #[cfg(feature = "simulate-slow-create")]
    if let Some(delay) = simulation::delay() {
        let lock = simulation::folder_lock(folder);
        let _held = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        std::thread::sleep(delay);
        return create();
    }
    let _ = folder;
    create()
}

#[cfg(feature = "simulate-slow-create")]
pub use simulation::set;

#[cfg(feature = "simulate-slow-create")]
mod simulation {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, LazyLock, Mutex};
    use std::time::Duration;

    static DELAY_MICROS: AtomicU64 = AtomicU64::new(0);
    static FOLDERS: LazyLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> =
        LazyLock::new(Default::default);

    /// Every create from now on sleeps [delay], one at a time per folder.
    /// Zero turns the simulation off.
    pub fn set(delay: Duration) {
        DELAY_MICROS.store(delay.as_micros() as u64, Ordering::Relaxed);
    }

    pub(super) fn delay() -> Option<Duration> {
        let micros = DELAY_MICROS.load(Ordering::Relaxed);
        (micros > 0).then(|| Duration::from_micros(micros))
    }

    pub(super) fn folder_lock(folder: &Path) -> Arc<Mutex<()>> {
        let mut folders = FOLDERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        folders.entry(folder.to_path_buf()).or_default().clone()
    }
}
