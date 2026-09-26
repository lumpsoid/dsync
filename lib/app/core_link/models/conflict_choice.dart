/// What the review chose for one conflict: left open, settled toward side
/// [keepA] (this device) or [keepB] (the peer), or both versions kept —
/// the peer's saved beside this device's.
enum ConflictChoice { unresolved, keepA, keepB, keepBoth }
