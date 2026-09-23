import 'dart:io';

import 'package:dsync/dsync_core/agent/posix_chmod.dart';
import 'package:dsync/dsync_core/agent/write_target_probe.dart';
import 'package:dsync/dsync_core/models/write_target.dart';
import 'package:test/test.dart';

/// The real binding, against the real filesystem: a wrong `st_nlink` offset
/// for this ABI reads a neighbouring field, and only a real hard link can
/// tell.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('write_target_probe_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  ExistingWriteTarget existing(String path) {
    final target = probeWriteTarget(path);
    expect(target, isA<ExistingWriteTarget>());
    return target as ExistingWriteTarget;
  }

  test('nothing there reads as absent, and writes in place', () {
    final target = probeWriteTarget('${dir.path}/missing.txt');

    expect(target, isA<AbsentWriteTarget>());
    expect(target.writesInPlace, isTrue);
  });

  test('a plain file has one link and is writable', () {
    File('${dir.path}/a.txt').writeAsStringSync('a');

    final target = existing('${dir.path}/a.txt');

    expect(target.linkCount, 1);
    expect(target.writable, isTrue);
    expect(target.writesInPlace, isTrue);
  });

  test('a hard-linked file counts its links, and is replaced', () async {
    File('${dir.path}/a.txt').writeAsStringSync('a');
    final ln = await Process.run('ln', ['${dir.path}/a.txt', '${dir.path}/b']);
    expect(ln.exitCode, 0, reason: '${ln.stderr}');

    final target = existing('${dir.path}/a.txt');

    expect(target.linkCount, 2);
    expect(target.writesInPlace, isFalse);
  }, testOn: 'linux || mac-os');

  test('a read-only file is not writable, and is replaced', () {
    File('${dir.path}/a.txt').writeAsStringSync('a');
    // 0o444 in decimal.
    posixChmod('${dir.path}/a.txt', 292);
    try {
      File('${dir.path}/a.txt').openSync(mode: FileMode.append).closeSync();
      markTestSkipped('running as root: 0444 does not deny writes');
      return;
    } on FileSystemException {
      // Good — the bits took, so the probe has something to see.
    }

    final target = existing('${dir.path}/a.txt');

    expect(target.writable, isFalse);
    expect(target.writesInPlace, isFalse);
  }, testOn: 'linux || mac-os');

  test('a symlink reads as its target, links and all', () async {
    File('${dir.path}/a.txt').writeAsStringSync('a');
    await Process.run('ln', ['${dir.path}/a.txt', '${dir.path}/b']);
    Link('${dir.path}/link').createSync('${dir.path}/a.txt');

    expect(existing('${dir.path}/link').linkCount, 2);
  }, testOn: 'linux || mac-os');
}
