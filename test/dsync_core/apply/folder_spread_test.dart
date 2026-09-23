import 'package:dsync/dsync_core/apply/folder_spread.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:test/test.dart';

List<PlanAction> _copies(List<String> paths) => [
  for (final path in paths) PlanAction(path: path, type: ActionType.copyAtoB),
];

List<String> _paths(List<PlanAction> actions) => [
  for (final action in actions) action.path,
];

void main() {
  group('spreadAcrossFolders (task 5d8c28)', () {
    test('takes one action from each folder in turn', () {
      final spread = spreadAcrossFolders(
        _copies([
          'a/1',
          'a/2',
          'a/3',
          'b/1',
          'b/2',
          'b/3',
          'c/1',
          'c/2',
          'c/3',
        ]),
      );

      expect(_paths(spread), [
        'a/1', 'b/1', 'c/1', //
        'a/2', 'b/2', 'c/2', //
        'a/3', 'b/3', 'c/3',
      ]);
    });

    test('a folder that runs out drops out of the rotation', () {
      final spread = spreadAcrossFolders(
        _copies(['big/1', 'big/2', 'big/3', 'big/4', 'small/1']),
      );

      expect(_paths(spread), ['big/1', 'small/1', 'big/2', 'big/3', 'big/4']);
    });

    test('the parent is the whole folder path, not its first segment', () {
      final spread = spreadAcrossFolders(
        _copies(['a/1', 'a/2', 'a/x/1', 'a/x/2', 'top1', 'top2']),
      );

      expect(_paths(spread), ['a/1', 'a/x/1', 'top1', 'a/2', 'a/x/2', 'top2']);
    });

    test('one folder keeps its given order', () {
      final actions = _copies(['z', 'a', 'm']);

      expect(_paths(spreadAcrossFolders(actions)), ['z', 'a', 'm']);
    });

    test('every action appears exactly once, whatever its type', () {
      const actions = [
        PlanAction(path: 'a/1', type: ActionType.copyAtoB),
        PlanAction(path: 'a/2', type: ActionType.deleteOnA),
        PlanAction(path: 'b/1', type: ActionType.copyBtoA),
        PlanAction(path: 'b/2', type: ActionType.commitOnly),
        PlanAction(path: 'c/1', type: ActionType.deleteOnB),
      ];

      final spread = spreadAcrossFolders(actions);

      expect(spread, unorderedEquals(actions));
      expect(spread, hasLength(actions.length));
    });

    test('an empty plan stays empty', () {
      expect(spreadAcrossFolders(const []), isEmpty);
    });
  });
}
