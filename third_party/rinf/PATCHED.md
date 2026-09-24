This is the published `rinf` 8.10.1 package from pub.dev, vendored with one
patch, until rinf ships a fix (task 07876c spike; see native/NOTES.md):

- `cargokit/gradle/plugin.gradle`: `CargoKitBuildTask` runs the Cargokit
  build tool through an injected `ExecOperations` instead of `project.exec`,
  which Gradle 9 removed (the app is on Gradle 9.3.1 / AGP 9.1.0). Without it
  `flutter build apk` fails with "Could not find method exec() ... on project
  ':rinf'".

`example/` is dropped. Everything else is byte-for-byte the pub package.
The app picks this copy up through `dependency_overrides` in pubspec.yaml.
