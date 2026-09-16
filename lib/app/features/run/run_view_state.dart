import 'package:flutter/foundation.dart';

/// The rendered values of the Run page: a `dsync_core` run's `RunEvent`s as
/// something a widget can display (SPEC §9).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`. Its fields land with the page itself.
class SyncRunViewState extends ChangeNotifier {}
