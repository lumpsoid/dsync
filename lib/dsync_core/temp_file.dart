import 'dart:io';

/// Names the scratch file a write streams into before renaming it over the
/// target (SPEC §7.2), and recognises one again afterwards.
///
/// The name carries the writing process and a per-write sequence number
/// rather than being fixed. A fixed name would have two runs against the same
/// replica streaming into the same path and renaming over each other; the
/// replica lock (SPEC §4.3) rules that out today, but whether an atomic write
/// is atomic should not depend on a lock held elsewhere.
String tempPathFor(String targetPath, int sequence) =>
    '$targetPath$tempFileMarker$pid.$sequence';

/// The marker that identifies a scratch file, between the target's name and
/// the parts that make it unique.
const tempFileMarker = '.dsync-tmp.';

/// Whether [name] is a scratch file left by a write.
///
/// Needed because a crash leaves one behind, inside the replica, where the
/// next scan would otherwise report it as a new file and propagate dsync's
/// own half-written scratch data to the other replica. They are skipped
/// rather than deleted: removing files from a replica unasked is not
/// something a sync tool should do on a guess about a filename.
bool isTempFileName(String name) => _tempSuffix.hasMatch(name);

final _tempSuffix = RegExp(RegExp.escape(tempFileMarker) + r'\d+\.\d+$');
