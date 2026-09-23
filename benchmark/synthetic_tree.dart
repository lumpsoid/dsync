// Writes a synthetic tree for a `peer://` pull onto the phone (tasks 4759eb,
// 84fc92). Not part of the build.
//
//   dart run benchmark/synthetic_tree.dart create <dir>
//   dart run benchmark/synthetic_tree.dart create <dir> --files 3000 --per-dir 30
//   dart run benchmark/synthetic_tree.dart modify <dir> --round 1
//
// `create` writes the tree the device harness writes
// (`integration_test/apply_write_path_test.dart`): SPEC §5.3's mean file size,
// sizes drawn exponentially and seeded, `--per-dir` files to a directory. A
// pull of it onto an empty phone folder is the fresh pass, and its per-file
// cost reads directly against the harness's 15.4 ms a file at 16 workers, where
// the source was local and there was no link. `--per-dir 100000` puts every
// file in one directory.
//
// `modify` rewrites every file under <dir> at the same size with bytes it has
// not held before, so the next pull overwrites each one. Use a new `--round`
// each time.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _meanBytes = 13007; // SPEC §5.3's 179.5 MiB / 14,471

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: synthetic_tree.dart create <dir> [--files N] [--per-dir N]\n'
      '       synthetic_tree.dart modify <dir> [--round N]',
    );
    exit(2);
  }
  final options = {
    for (var i = 2; i + 1 < args.length; i += 2)
      args[i]: int.parse(args[i + 1]),
  };
  final root = Directory(args[1]);
  switch (args[0]) {
    case 'create':
      _create(
        root,
        files: options['--files'] ?? 3000,
        perDir: options['--per-dir'] ?? 30,
      );
    case 'modify':
      _modify(root, options['--round'] ?? 1);
    default:
      stderr.writeln('unknown command: ${args[0]}');
      exit(2);
  }
}

void _create(Directory root, {required int files, required int perDir}) {
  if (root.existsSync() && root.listSync().isNotEmpty) {
    stderr.writeln('${root.path} is not empty');
    exit(1);
  }
  final random = Random(58609);
  final buffer = Uint8List(1 << 20);
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] = random.nextInt(256);
  }
  var total = 0;
  final dirs = <String>{};
  for (var i = 0; i < files; i++) {
    final dir = Directory(
      '${root.path}/d${i ~/ (perDir * perDir)}/d${(i ~/ perDir) % perDir}',
    );
    if (dirs.add(dir.path)) dir.createSync(recursive: true);
    final size = min(
      buffer.length,
      max(1, (-log(1 - random.nextDouble()) * _meanBytes).round()),
    );
    final offset = random.nextInt(buffer.length - size + 1);
    File('${dir.path}/f$i.bin')
        .writeAsBytesSync(Uint8List.sublistView(buffer, offset, offset + size));
    total += size;
  }
  stdout.writeln(
    'created $files files in ${dirs.length} directories, '
    '${(total / (1 << 20)).toStringAsFixed(1)} MiB, under ${root.path}',
  );
}

void _modify(Directory root, int round) {
  var count = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (bytes[i] + round) & 0xFF;
    }
    entity.writeAsBytesSync(bytes);
    count++;
  }
  stdout.writeln('rewrote $count files under ${root.path} (round $round)');
}
