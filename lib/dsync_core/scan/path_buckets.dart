/// How SPEC §6.1's unchanged paths are divided into buckets, and what a
/// bucket's digest is.
///
/// **Bucketed by a hash of the path, not by walk order or by any prefix of
/// the path.** Both sides have to put a path in the same bucket without
/// having exchanged anything, and the only thing they are both certain to
/// agree on about a path is the path itself. A prefix would bucket by
/// directory, which piles a project's whole tree into one bucket and leaves
/// the rest empty; a hash spreads the tree evenly whatever it looks like,
/// and two sides that walked in different orders still agree entry for
/// entry.
///
/// **One level, no tree.** A Merkle tree refining only down the branches
/// that differ is the general answer and is deliberately not built here: the
/// subtraction phase 2 does — a side digests its unchanged paths *minus* the
/// paths the peer just reported changed — is what keeps a dirty bucket rare
/// rather than one per changed path, so refinement has nothing much left to
/// refine. Build the tree when a measurement says one level is not enough,
/// not before.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';


/// How many unchanged entries a bucket aims to hold.
///
/// **K is scaled to the entry count, not fixed.** A fixed K wastes digests on
/// a small tree and makes a dirty bucket expensive on a large one, and the
/// cost of being wrong is asymmetric: an over-large bucket is paid in entries
/// dragged over the wire (~75 bytes each), an over-small one in digests (32
/// bytes each). A few hundred entries a bucket puts both terms in the same
/// small place — on the 14,471-file tree it is 57 buckets, 1.8 KiB of digests
/// a side, against a dirty bucket costing ~19 KiB.
const targetBucketEntries = 256;

/// How many buckets a scan of [entryCount] paths is divided into.
///
/// [entryCount] is the *whole* scan's count, not the unchanged one, and the
/// larger of the two sides' counts is what the exchange uses — both sides
/// must bucket identically, and the initiator is the only party that knows
/// both. Never zero: a bucket count of zero has no modulus, and an empty scan
/// still has to produce a digest list the other side can compare against.
int bucketCountFor(int entryCount) {
  if (entryCount <= 0) return 1;
  return (entryCount + targetBucketEntries - 1) ~/ targetBucketEntries;
}

/// Which of [bucketCount] buckets [path] falls in.
///
/// SHA-256 of the path's UTF-8, taken modulo [bucketCount] over its first
/// four bytes. A cheaper non-cryptographic hash would do the job — nothing
/// here is adversarial, and a collision only puts two paths in one bucket —
/// but the arithmetic of the usual candidates (FNV, xxHash) overflows 2^53 on
/// a JavaScript number, so a build that ever ran there would bucket
/// differently from one that did not, and that is a silent wrong answer
/// rather than a loud one. `package:crypto` is already a dependency for the
/// content hash and is exact everywhere.
int bucketOf(String path, int bucketCount) {
  final digest = sha256.convert(utf8.encode(path)).bytes;
  final key =
      (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
  return key % bucketCount;
}

/// The digest of every bucket over [entries], in bucket order.
///
/// **Over `(path, hash)` pairs, not paths alone** — a deliberate choice of
/// the stronger option, and a behaviour change; see SPEC §6. Paths alone
/// would reproduce today's behaviour exactly, since §6's `unchanged ×
/// unchanged` cell is "nothing" whatever the content. Digesting the pair
/// makes a bucket go dirty when the two sides agree on *membership* and
/// disagree on *content* — two archives that have silently diverged, which
/// today stay diverged forever because neither side has any reason to
/// mention the path. Those buckets are now fetched in full and reconciled,
/// and §6's `unchanged × unchanged` cell resolves a hash disagreement as a
/// conflict.
///
/// Members are sorted by path and hashed as one run rather than combined
/// commutatively (an XOR or a wrapping sum of per-entry digests). Both are
/// order-independent, which is the property this needs, but a sort and one
/// hash is the version whose collision behaviour is SHA-256's and needs no
/// argument of its own.
List<Uint8List> bucketDigests(Iterable<ScanEntry> entries, int bucketCount) {
  final buckets = List.generate(bucketCount, (_) => <ScanEntry>[]);
  for (final entry in entries) {
    buckets[bucketOf(entry.path, bucketCount)].add(entry);
  }
  return [
    for (final bucket in buckets)
      Uint8List.fromList(sha256.convert(_bucketBytes(bucket)).bytes),
  ];
}

/// One bucket's members as the bytes its digest is taken over: each entry as
/// `path \0 hash \n`, in path order.
///
/// The separators are what stop two different member sets from spelling the
/// same run of bytes — neither a path nor a hex hash can contain either one.
List<int> _bucketBytes(List<ScanEntry> bucket) {
  bucket.sort((a, b) => a.path.compareTo(b.path));
  final bytes = BytesBuilder(copy: false);
  for (final entry in bucket) {
    bytes
      ..add(utf8.encode(entry.path))
      ..addByte(0)
      // An `unchanged` entry always carries a hash — the fast path copies the
      // archive's (SPEC §5.2 step 1) and the rehash reports the one it just
      // computed (step 2) — so the empty fallback is unreachable and is here
      // only so this cannot silently depend on that staying true.
      ..add(utf8.encode(entry.hash ?? ''))
      ..addByte(10);
  }
  return bytes.takeBytes();
}
