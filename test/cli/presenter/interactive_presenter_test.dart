import 'dart:io';

import 'package:dsync/cli/presenter/interactive_presenter.dart';
import 'package:dsync/cli/presenter/non_interactive_stdin_error.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:test/test.dart';

/// A synchronous, in-memory stand-in for [IOSink]: every [write]/[writeln]
/// lands in [buffer] instead of a real terminal, so a prompt's own text can
/// be asserted on with no timing dependent on a real process's stdout.
/// `noSuchMethod` covers the rest of [IOSink]'s interface, which this
/// presenter never calls.
class _FakeSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

InteractivePresenter _presenter(
  List<String> script, {
  IOSink? output,
  bool isTerminal = true,
}) {
  return InteractivePresenter(
    lines: Stream.fromIterable(script),
    output: output ?? _FakeSink(),
    isTerminal: isTerminal,
  );
}

/// [PlanAction] has no [Object.==] override, so a runtime-constructed
/// instance (as [InteractivePresenter] builds for a resolved conflict) is
/// never equal to a separately-built expectation even with identical
/// fields — only field-by-field comparison is meaningful here.
void _expectSingleAction(
  List<PlanAction> result, {
  required String path,
  required ActionType type,
  int bytes = 0,
}) {
  expect(result, hasLength(1));
  expect(result.single.path, path);
  expect(result.single.type, type);
  expect(result.single.bytes, bytes);
}

const _entryA = ScanEntry(path: 'p', status: ScanStatus.modified, size: 10);
const _entryB = ScanEntry(path: 'p', status: ScanStatus.modified, size: 20);

void main() {
  group('InteractivePresenter', () {
    test('accepts one action and skips another', () async {
      const plan = Plan(
        actions: [
          PlanAction(path: 'keep.txt', type: ActionType.copyAtoB, bytes: 5),
          PlanAction(path: 'drop.txt', type: ActionType.copyBtoA, bytes: 5),
        ],
        conflicts: [],
      );

      final result = await _presenter(['y', 's']).call(plan);

      expect(result.map((a) => a.path), ['keep.txt']);
    });

    test('a deletion is prompted and can be vetoed', () async {
      const plan = Plan(
        actions: [PlanAction(path: 'gone.txt', type: ActionType.deleteOnA)],
        conflicts: [],
      );

      final vetoed = await _presenter(['s']).call(plan);
      expect(vetoed, isEmpty);

      final accepted = await _presenter(['y']).call(plan);
      _expectSingleAction(
        accepted,
        path: 'gone.txt',
        type: ActionType.deleteOnA,
      );
    });

    test('accept-all-remaining stops prompting for the rest', () async {
      const plan = Plan(
        actions: [
          PlanAction(path: 'one.txt', type: ActionType.copyAtoB),
          PlanAction(path: 'two.txt', type: ActionType.copyBtoA),
          PlanAction(path: 'three.txt', type: ActionType.deleteOnB),
        ],
        conflicts: [],
      );

      // Only one line is ever supplied: if the presenter tried to read past
      // it for the remaining two actions, the stream would end and every
      // unread action would come back as an implicit quit instead.
      final result = await _presenter(['a']).call(plan);

      expect(result.map((a) => a.path), ['one.txt', 'two.txt', 'three.txt']);
    });

    test('quit stops prompting and leaves the rest undecided', () async {
      const plan = Plan(
        actions: [
          PlanAction(path: 'one.txt', type: ActionType.copyAtoB),
          PlanAction(path: 'two.txt', type: ActionType.copyBtoA),
        ],
        conflicts: [],
      );

      final result = await _presenter(['y', 'q']).call(plan);

      expect(result.map((a) => a.path), ['one.txt']);
    });

    test('a two-sided conflict resolved as copy A -> B', () async {
      const plan = Plan(
        actions: [],
        conflicts: [Conflict(path: 'c.txt', onA: _entryA, onB: _entryB)],
      );

      final result = await _presenter(['1']).call(plan);

      _expectSingleAction(
        result,
        path: 'c.txt',
        type: ActionType.copyAtoB,
        bytes: 10,
      );
    });

    test('a two-sided conflict resolved as copy B -> A', () async {
      const plan = Plan(
        actions: [],
        conflicts: [Conflict(path: 'c.txt', onA: _entryA, onB: _entryB)],
      );

      final result = await _presenter(['2']).call(plan);

      _expectSingleAction(
        result,
        path: 'c.txt',
        type: ActionType.copyBtoA,
        bytes: 20,
      );
    });

    test('a two-sided conflict can be skipped', () async {
      const plan = Plan(
        actions: [],
        conflicts: [Conflict(path: 'c.txt', onA: _entryA, onB: _entryB)],
      );

      final result = await _presenter(['s']).call(plan);

      expect(result, isEmpty);
    });

    test(
      'a one-sided conflict (absent on A) only offers copy B -> A',
      () async {
        const plan = Plan(
          actions: [],
          conflicts: [Conflict(path: 'c.txt', onA: null, onB: _entryB)],
        );

        final result = await _presenter(['y']).call(plan);

        _expectSingleAction(
          result,
          path: 'c.txt',
          type: ActionType.copyBtoA,
          bytes: 20,
        );
      },
    );

    test(
      'a one-sided conflict (absent on B) only offers copy A -> B',
      () async {
        const plan = Plan(
          actions: [],
          conflicts: [Conflict(path: 'c.txt', onA: _entryA, onB: null)],
        );

        final result = await _presenter(['y']).call(plan);

        _expectSingleAction(
          result,
          path: 'c.txt',
          type: ActionType.copyAtoB,
          bytes: 10,
        );
      },
    );

    test('conflicts are resolved before actions are prompted', () async {
      const plan = Plan(
        actions: [PlanAction(path: 'act.txt', type: ActionType.copyAtoB)],
        conflicts: [Conflict(path: 'c.txt', onA: _entryA, onB: _entryB)],
      );

      final result = await _presenter(['1', 'y']).call(plan);

      expect(result.map((a) => a.path), ['c.txt', 'act.txt']);
    });

    test('re-prompts on an unrecognized key before accepting', () async {
      const plan = Plan(
        actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
        conflicts: [],
      );

      final sink = _FakeSink();
      final result = await _presenter(['bogus', 'y'], output: sink).call(plan);

      expect(result.map((a) => a.path), ['a.txt']);
      expect(sink.buffer.toString(), contains('Not understood'));
    });

    test('prints its own legend before the first prompt', () async {
      const plan = Plan(
        actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
        conflicts: [],
      );
      final sink = _FakeSink();

      await _presenter(['y'], output: sink).call(plan);

      final printed = sink.buffer.toString();
      expect(printed, contains('y = accept'));
      expect(printed, contains('s = skip'));
      expect(printed, contains('a = accept all remaining'));
      expect(printed, contains('q = quit'));
    });

    test('non-TTY stdin without --batch raises rather than accepting all', () {
      const plan = Plan(
        actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
        conflicts: [],
      );

      final presenter = _presenter([], isTerminal: false);

      expect(presenter.call(plan), throwsA(isA<NonInteractiveStdinError>()));
    });
  });
}
