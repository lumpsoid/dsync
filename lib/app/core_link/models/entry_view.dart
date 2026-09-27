import 'root_kind.dart';

/// One entry of a head-shaped profile, as the core listed it: a root on
/// this device and one on the profile's paired device.
final class EntryView {
  const EntryView({
    required this.entryId,
    required this.kind,
    required this.localRoot,
    required this.localRootExpanded,
    required this.localRootRefusal,
    required this.remoteRoot,
  });

  /// What the entry's archive logs are filed under.
  final String entryId;
  final RootKind kind;
  final String localRoot;
  final String localRootExpanded;

  /// Why the local root cannot be a replica root now, if it cannot.
  final String? localRootRefusal;
  final String remoteRoot;
}
