import 'app_controller.dart';
import 'app_paths.dart';

/// # How the Flutter head is put together
///
/// Every feature under `lib/app/features/<feature>/` is four files, and the
/// head's root is the same four things without the "feature":
///
/// ```
/// lib/app/
///   dsync_app.dart              MaterialApp + routes
///   app_state.dart              the one application state
///   app_scope.dart              cell for AppState + AppController (this file)
///   app_controller.dart         bootstrap: identity, stores
///   features/<feature>/
///     <feature>_page.dart       widgets only
///     <feature>_view_state.dart ChangeNotifier, one view's data
///     <feature>_controller.dart input methods, owns the view state
///     <feature>_scope.dart      hand-written cell
/// ```
///
/// The roles, in the direction data flows:
///
/// - A **controller** is the orchestrator. Its constructor takes its
///   dependencies (the [AppController], a store, a connector) — never a
///   service locator — so a test constructs it with fakes and a scope
///   constructs it with the real ones. Its public methods are the *inputs* a
///   widget can send (`pair(payload)`, `revoke(id)`, `start()`), named for
///   intent. It owns its view state and disposes it.
/// - A **view state** is a `ChangeNotifier` of *already-rendered* values:
///   strings, enums, sealed cases. No `dsync_core` decision logic lives on it
///   and no `Future` hangs off it — the controller awaits, decides, and then
///   writes the verdict as a value the widget only has to display.
/// - A **page** is widgets only. It calls controller input methods and reads
///   view state. It never branches on domain data (`if (device.isExpired)`)
///   — that branch belongs in the controller, and the page reads the case it
///   produced. This is "tell, don't ask" applied at the widget border, and it
///   is what keeps a page's test a rendering test rather than a logic test.
/// - A **scope** is the hand-written cell that hands a page its controller.
///
/// ## The scope contract
///
/// A scope is a plain top-level object — not a `provider`, not an
/// `InheritedWidget` — holding a nullable cached instance and a swappable
/// factory. It is deliberately this dumb so that a widget test drives a page
/// by calling `xScope.setController(fake)` and pumping the page directly,
/// with no wrapper widget to build and no binding to configure.
///
/// Every scope is a subclass of [Scope] and exposes exactly this surface:
///
/// - `controller` — the cached instance, built on first read by the factory.
///   For a view that outlives its pages (the app, the device list).
/// - `create()` — a *fresh* instance from the factory, never cached. For a
///   view that must own its instance and `dispose()` it. The Run page is the
///   reason this exists alongside `controller`: two runs must never share a
///   loop, and a `RunEvent` arriving late from a finished run must not write
///   into a view state that a later page has already torn down. A page that
///   calls `create()` calls `dispose()` on what it got.
/// - `setController(c)` — pin one instance: both `controller` and `create()`
///   return `c` until `reset()`. Tests use this to hand a page a fake.
/// - `setFactory(f)` — swap the factory and drop the cache. Tests use this
///   when the page under test calls `create()` and must get a fresh fake per
///   call, or when a real controller is wanted with one dependency faked.
/// - `reset()` — back to the default factory, cache dropped. Call it in
///   `tearDown` so one test's pin cannot leak into the next.
///
/// [Scope] is a generic base class rather than a per-feature copy of the same
/// six members: the members are the contract, and a copy in each feature is
/// five places for it to drift. A subclass is one constructor that names the
/// default factory — [AppScope] below is the whole of it, and a feature scope
/// is the same shape with its dependencies threaded in:
///
/// ```dart
/// final class DevicesScope extends Scope<DevicesController> {
///   DevicesScope() : super(() => DevicesController(appScope.controller));
/// }
///
/// final devicesScope = DevicesScope();
/// ```
abstract base class Scope<C> {
  Scope(C Function() defaultFactory)
    : _defaultFactory = defaultFactory,
      _factory = defaultFactory;

  final C Function() _defaultFactory;
  C Function() _factory;
  C? _controller;

  /// The cached instance, built by the factory on first read.
  C get controller => _controller ??= _factory();

  /// A fresh instance from the factory, bypassing the cache. The caller owns
  /// it and must dispose it — see the contract above for why this exists.
  C create() => _factory();

  /// Pins [controller] so that both [Scope.controller] and [create] return it
  /// until [reset].
  void setController(C controller) {
    _controller = controller;
    _factory = () => controller;
  }

  /// Replaces the factory and drops the cache, so the next [Scope.controller]
  /// read and every [create] call go through [factory].
  void setFactory(C Function() factory) {
    _factory = factory;
    _controller = null;
  }

  /// Restores the default factory and drops the cache.
  void reset() {
    _factory = _defaultFactory;
    _controller = null;
  }
}

/// The cell for the head's [AppController] — and, through it, the one
/// `AppState`. Every feature scope's default factory reaches this for the
/// dependencies its controller borrows from the application.
final class AppScope extends Scope<AppController> {
  AppScope() : super(() => AppController(AppPaths.forThisDevice));
}

/// The single application scope. A page or a feature scope reaches the
/// application through this and nothing else.
final appScope = AppScope();
