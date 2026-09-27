//! Saved profiles (plan OQ1): the core's TOML store, which the head edits
//! through these commands. The head's shape is entries that each pair a
//! root on this device (side A) with one on a paired device (side B);
//! every change answers with the list as it now stands.

use dsync_core::{
    PairedDeviceStore, PairedDevices, ProfileStore, RunMarker, StateDir, check_root_access,
};
use dsync_domain::{
    Entry, EntryId, HostFacts, Jobs, Location, Profile, ProfileName, ReplicaLocation, Side,
};

use crate::devices::device;
use crate::diagnostics::ignore_rules;
use crate::dispatch::{Handled, Hub, blocking, text};
use crate::run::run_flags;
use crate::signals::{ProfileDraft, ReplyResult};
use crate::views::{EntryView, OtherEntryView, ProfileEntry, ProfileView};

impl Hub {
    pub(crate) async fn list_profiles(&self) -> Handled {
        let listing = self.listing();
        blocking(move || listing.entries())
            .await
            .map(ReplyResult::Profiles)
    }

    /// Creates or overwrites `name` with the draft's entries, refused
    /// before it is written when its options would be (two roots overlap,
    /// say: the refusal names both entries).
    pub(crate) async fn save_profile(&self, name: &str, draft: ProfileDraft) -> Handled {
        let name = ProfileName::parse(name).map_err(text)?;
        let profile = self.draft_profile(&draft)?;
        let flags = run_flags(false, Vec::new(), None)?;
        profile.options(&name, &flags, &self.facts).map_err(text)?;
        let listing = self.listing();
        blocking(move || {
            listing.profiles.save(&name, &profile).map_err(text)?;
            listing.entries()
        })
        .await
        .map(ReplyResult::Profiles)
    }

    pub(crate) async fn rename_profile(&self, from: &str, to: &str) -> Handled {
        let from = ProfileName::parse(from).map_err(text)?;
        let to = ProfileName::parse(to).map_err(text)?;
        let listing = self.listing();
        blocking(move || {
            listing.profiles.rename(&from, &to).map_err(text)?;
            listing.entries()
        })
        .await
        .map(ReplyResult::Profiles)
    }

    pub(crate) async fn delete_profile(&self, name: &str) -> Handled {
        let name = ProfileName::parse(name).map_err(text)?;
        let listing = self.listing();
        blocking(move || {
            listing.profiles.delete(&name).map_err(text)?;
            listing.entries()
        })
        .await
        .map(ReplyResult::Profiles)
    }

    /// The draft as a profile: one entry per draft entry, its local root
    /// as A and its remote root on the paired device as B, under the name
    /// that device is paired as now; the draft's ignore patterns as the
    /// profile's rules. What saving writes and what a draft run syncs.
    pub(crate) fn draft_profile(&self, draft: &ProfileDraft) -> Result<Profile, String> {
        let platform = self.facts.platform();
        let id = device(&draft.peer_device_id)?;
        let paired = self.paired().load().map_err(text)?;
        let name = paired
            .get(&id)
            .ok_or_else(|| format!("no device with id {id} is paired with this host"))?
            .name()
            .clone();
        let entries = draft
            .entries
            .iter()
            .map(|entry| {
                let local = Location::local(&entry.local_root, platform).map_err(text)?;
                let local = ReplicaLocation::new(local, None).map_err(text)?;
                let peer = Location::peer(name.clone(), &entry.remote_root).map_err(text)?;
                let peer = ReplicaLocation::new(peer, Some(id)).map_err(text)?;
                Entry::new(entry.kind.into(), local, peer).map_err(text)
            })
            .collect::<Result<Vec<_>, String>>()?;
        let mut profile = Profile::new(entries)
            .map_err(text)?
            .with_rules(ignore_rules(&draft.ignore)?);
        if let Some(jobs) = draft.jobs {
            profile = profile.with_jobs(Jobs::new(i64::from(jobs)).map_err(text)?);
        }
        Ok(profile)
    }

    fn listing(&self) -> Listing {
        Listing {
            profiles: self.profiles.clone(),
            state: self.state.clone(),
            facts: self.facts.clone(),
        }
    }
}

/// What listing the profiles reads, owned so it can run off the runtime.
struct Listing {
    profiles: ProfileStore,
    state: StateDir,
    facts: HostFacts,
}

impl Listing {
    /// Every saved profile. One that will not load is listed as such, not
    /// failed on: the others are still runnable.
    fn entries(&self) -> Result<Vec<ProfileEntry>, String> {
        let paired = PairedDeviceStore::new(&self.state).load().map_err(text)?;
        let names = self.profiles.list().map_err(text)?;
        Ok(names
            .into_iter()
            .map(
                |name| match self.profiles.load(&name, self.facts.platform()) {
                    Ok(profile) => self.entry(name, &profile, &paired),
                    Err(error) => ProfileEntry::Unreadable {
                        name: name.to_string(),
                        message: error.to_string(),
                    },
                },
            )
            .collect())
    }

    /// A profile whose every entry pairs a root on this device with one
    /// on a paired device is the head's own shape (one device: a profile
    /// has one endpoint per side); any other, or one whose options are
    /// refused on this host, lists its entries as typed.
    fn entry(&self, name: ProfileName, profile: &Profile, paired: &PairedDevices) -> ProfileEntry {
        let ids = self.entry_ids(&name, profile);
        let device = match profile.entries()[0].replica(Side::B) {
            ReplicaLocation::Peer(_, device) => Some(*device),
            _ => None,
        };
        let head = profile.entries().iter().all(|entry| {
            matches!(
                (entry.replica(Side::A), entry.replica(Side::B)),
                (ReplicaLocation::Local(_), ReplicaLocation::Peer(..))
            )
        });
        match (head, device, ids) {
            (true, Some(device), Some(ids)) => {
                let entries: Vec<EntryView> = profile
                    .entries()
                    .iter()
                    .zip(&ids)
                    .map(|(entry, id)| self.entry_view(entry, id))
                    .collect();
                // Unreadable reads as absent: a warning, not a reason to
                // hide the profile.
                let last_run_unfinished = ids.iter().any(|id| {
                    RunMarker::new(self.state.run_marker(id))
                        .is_present()
                        .unwrap_or(false)
                });
                ProfileEntry::Head(ProfileView {
                    name: name.to_string(),
                    peer_device_id: device.to_string(),
                    peer_name: paired.get(&device).map(|paired| paired.name().to_string()),
                    jobs: profile
                        .jobs()
                        .map(|jobs| u32::try_from(jobs.get()).unwrap_or(u32::MAX)),
                    ignore: profile
                        .rules()
                        .ignore()
                        .iter()
                        .map(|glob| glob.as_str().to_owned())
                        .collect(),
                    last_run_unfinished,
                    entries,
                })
            }
            _ => ProfileEntry::Other {
                name: name.to_string(),
                entries: profile
                    .entries()
                    .iter()
                    .map(|entry| OtherEntryView {
                        a: entry.replica(Side::A).to_string(),
                        b: entry.replica(Side::B).to_string(),
                    })
                    .collect(),
            },
        }
    }

    /// A head entry: its local root, expanded and checked as a root of
    /// the entry's kind, and its remote root as typed.
    fn entry_view(&self, entry: &Entry, id: &EntryId) -> EntryView {
        let local = entry.replica(Side::A).to_location();
        let expanded = local.expanded_path(self.facts.home());
        let refusal = match &expanded {
            Ok(root) => check_root_access(entry.kind(), root.as_ref())
                .err()
                .map(text),
            Err(error) => Some(error.to_string()),
        };
        EntryView {
            entry_id: id.as_str().to_owned(),
            kind: entry.kind().into(),
            local_root: local.path().to_owned(),
            local_root_expanded: expanded.unwrap_or_else(|_| local.path().to_owned()),
            local_root_refusal: refusal,
            remote_root: entry.replica(Side::B).to_location().path().to_owned(),
        }
    }

    /// Every entry's id, in entry order, or `None` when the profile's
    /// options are refused on this host.
    fn entry_ids(&self, name: &ProfileName, profile: &Profile) -> Option<Vec<EntryId>> {
        let flags = run_flags(false, Vec::new(), None).ok()?;
        let options = profile.options(name, &flags, &self.facts).ok()?;
        Some(
            options
                .into_iter()
                .map(|options| options.entry_id)
                .collect(),
        )
    }
}
