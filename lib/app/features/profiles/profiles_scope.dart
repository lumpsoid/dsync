import '../../app_scope.dart';
import 'profiles_controller.dart';

/// The cell for [ProfilesController]; see the scope contract in
/// `app_scope.dart`.
final class ProfilesScope extends Scope<ProfilesController> {
  ProfilesScope() : super(() => ProfilesController(appScope.controller));
}

/// The single profiles scope.
final profilesScope = ProfilesScope();
