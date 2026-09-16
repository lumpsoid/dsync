/// The one application state of the Flutter head (SPEC §13, §16): what this
/// device is, who it is paired with, and whether the head has finished
/// bootstrapping enough to show a page at all.
///
/// Phase 1 lands only the type so `AppController` and `AppScope` have a
/// shape to own; its fields — this device's id and certificate expiry, the
/// paired devices as view-ready rows, and a sealed bootstrap gate — arrive
/// with the bootstrap itself, at which point this becomes a `ChangeNotifier`
/// like every feature's view state (see `app_scope.dart`). It is a plain
/// class until then only so that nothing under `test/app/` needs a Flutter
/// binding to exercise the scope mechanism.
class AppState {}
