import 'dart:io';

/// Replaces [file]'s contents with [contents] so a reader sees either the
/// old document or the new one, never a torn one: write a sibling temp
/// file, flush it to disk, then rename it over [file].
///
/// The head's own helper (plan D10): the one file the head writes itself
/// is `settings.json`, and this is its whole persistence need, so it does
/// not borrow the core's `temp_file`. The temp name carries this process's
/// pid and a counter, so two writes - here or in another process - never
/// share a scratch file.
Future<void> writeFileAtomically(File file, String contents) async {
  await file.parent.create(recursive: true);
  final temp = File('${file.path}.tmp-$pid-${_sequence++}');
  try {
    // flush: true is fsync: the replacement has to be on disk before the
    // rename swaps it in, or a crash in that window loses the document.
    await temp.writeAsString(contents, flush: true);
    await temp.rename(file.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}

int _sequence = 0;
