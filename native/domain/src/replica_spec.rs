//! What a remote replica's `hello` asks the far side to open (SPEC §4.2).

use crate::jobs::Jobs;
use crate::profile_id::ProfileId;
use crate::side::Side;

/// The replica an initiator wants served: which root, as which side of
/// which profile, scanned with how many threads.
///
/// `root` is **unexpanded**, exactly as the location spelled it: a leading
/// `~` or `$HOME` belongs to the far side's environment, not the
/// initiator's, so the far side expands it before it opens anything.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct ReplicaSpec {
    pub root: String,
    pub profile: ProfileId,
    pub side: Side,
    pub jobs: Jobs,
}
