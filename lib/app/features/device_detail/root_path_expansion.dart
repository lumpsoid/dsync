import 'package:dsync/dsync_core/models/location.dart';

/// Expands a root path a user typed into the form the store holds, exactly
/// as `dsync pair grant` expands one at the CLI edge: `Location.parse`,
/// then `expandedPath` against [environment].
///
/// The expansion is the whole reason this is a rule rather than a trim. A
/// grant is compared byte for byte against the root a peer asks for in its
/// `hello` (SPEC §4.4), so `~/Sync` typed here and `~/Sync` typed at the
/// CLI must land as the same string or the two grants are different
/// folders that look identical on screen.
///
/// Extracted out of `DeviceDetailController` when the host-level Shared
/// folders page gained a typed path of its own: two call sites, one rule,
/// and a copy of it in the second is a copy that will be the first one to
/// stop matching the CLI. Pure, so it is tested with plain strings and a
/// map rather than through either page.
///
/// Throws [FormatException] as `Location.parse` does — a path that will not
/// parse is a field error for the caller to render, never a refusal from
/// the store.
String expandRootPath(String path, Map<String, String> environment) =>
    Location.parse(path).expandedPath(environment);
