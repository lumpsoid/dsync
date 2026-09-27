//! Saved profiles (plan OQ1): the core's TOML store, which the head edits
//! through these commands. The head's shape is this device's folder as
//! side A and a folder on a paired device as side B; every change answers
//! with the list as it now stands.

use dsync_core::{
    PairedDeviceStore, PairedDevices, ProfileStore, RunMarker, StateDir, check_root_access,
};
use dsync_domain::{
    Entry, EntryId, HostFacts, Jobs, Location, Profile, ProfileName, ReplicaLocation, RootKind,
    Side,
};

use crate::devices::device;
use crate::diagnostics::ignore_rules;
use crate::dispatch::{Handled, Hub, blocking, text};
use crate::run::run_flags;
use crate::signals::{ProfileDraft, ReplyResult};
use crate::views::{ProfileEntry, ProfileView};

impl Hub {
    pub(crate) async fn list_profiles(&self) -> Handled {
        let listing = self.listing();
        blocking(move || listing.entries())
            .await
            .map(ReplyResult::Profiles)
    }

    /// Creates or overwrites `name`: a one-entry profile of the draft's
    /// pair, refused before it is written when its options would be (the
    /// two roots overlap, say).
    pub(crate) async fn save_profile(&self, name: &str, draft: ProfileDraft) -> Handled {
        let name = ProfileName::parse(name).map_err(text)?;
        let (local, peer) = self.draft_locations(&draft)?;
        let entry = Entry::folder(local, peer).map_err(text)?;
        let mut profile = Profile::new(vec![entry])
            .map_err(text)?
            .with_rules(ignore_rules(&draft.ignore)?);
        if let Some(jobs) = draft.jobs {
            profile = profile.with_jobs(Jobs::new(i64::from(jobs)).map_err(text)?);
        }
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

    /// The draft's two sides: its local root as A, its remote root on the
    /// paired device as B, under the name that device is paired as now.
    pub(crate) fn draft_locations(
        &self,
        draft: &ProfileDraft,
    ) -> Result<(ReplicaLocation, ReplicaLocation), String> {
        let platform = self.facts.platform();
        let local = Location::local(&draft.local_root, platform).map_err(text)?;
        let local = ReplicaLocation::new(local, None).map_err(text)?;
        let id = device(&draft.peer_device_id)?;
        let paired = self.paired().load().map_err(text)?;
        let name = paired
            .get(&id)
            .ok_or_else(|| format!("no device with id {id} is paired with this host"))?
            .name()
            .clone();
        let peer = Location::peer(name, &draft.remote_root).map_err(text)?;
        let peer = ReplicaLocation::new(peer, Some(id)).map_err(text)?;
        Ok((local, peer))
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

    /// A one-entry profile of this device's folder and a paired device's
    /// is the head's own shape; any other lists by its first entry.
    fn entry(&self, name: ProfileName, profile: &Profile, paired: &PairedDevices) -> ProfileEntry {
        let first = &profile.entries()[0];
        let id = self.first_entry_id(&name, profile);
        match (
            profile.entries().len(),
            first.replica(Side::A),
            first.replica(Side::B),
            id,
        ) {
            (1, ReplicaLocation::Local(_), ReplicaLocation::Peer(peer, device), Some(id)) => {
                let local = first.replica(Side::A).to_location();
                let expanded = local.expanded_path(self.facts.home());
                let refusal = match &expanded {
                    Ok(root) => check_root_access(RootKind::Folder, root.as_ref())
                        .err()
                        .map(text),
                    Err(error) => Some(error.to_string()),
                };
                let marker = RunMarker::new(self.state.run_marker(&id));
                ProfileEntry::Head(ProfileView {
                    name: name.to_string(),
                    profile_id: id.as_str().to_owned(),
                    local_root: local.path().to_owned(),
                    local_root_expanded: expanded.unwrap_or_else(|_| local.path().to_owned()),
                    local_root_refusal: refusal,
                    peer_device_id: device.to_string(),
                    peer_name: paired.get(device).map(|paired| paired.name().to_string()),
                    remote_root: peer.path().to_owned(),
                    jobs: profile
                        .jobs()
                        .map(|jobs| u32::try_from(jobs.get()).unwrap_or(u32::MAX)),
                    ignore: profile
                        .rules()
                        .ignore()
                        .iter()
                        .map(|glob| glob.as_str().to_owned())
                        .collect(),
                    // Unreadable reads as absent: a warning, not a reason
                    // to hide the profile.
                    last_run_unfinished: marker.is_present().unwrap_or(false),
                })
            }
            (_, a, b, id) => ProfileEntry::Other {
                name: name.to_string(),
                profile_id: id.map(|id| id.as_str().to_owned()),
                a: a.to_string(),
                b: b.to_string(),
            },
        }
    }

    /// The first entry's id, or `None` when the profile's options are
    /// refused on this host.
    fn first_entry_id(&self, name: &ProfileName, profile: &Profile) -> Option<EntryId> {
        let flags = run_flags(false, Vec::new(), None).ok()?;
        let options = profile.options(name, &flags, &self.facts).ok()?;
        options.into_iter().next().map(|options| options.entry_id)
    }
}
