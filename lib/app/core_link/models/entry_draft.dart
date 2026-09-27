import 'root_kind.dart';

/// One entry of a [ProfileDraft] as entered: this device's [localRoot]
/// synced with [remoteRoot] on the draft's paired device.
final class EntryDraft {
  const EntryDraft({
    this.kind = RootKind.folder,
    required this.localRoot,
    required this.remoteRoot,
  });

  final RootKind kind;
  final String localRoot;
  final String remoteRoot;
}
