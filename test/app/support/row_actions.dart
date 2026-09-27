import 'package:dsync/app/row_action.dart';

/// [actions] as one line each, so a builder's whole list reads as one
/// expectation: a command by its label (with `[Delete]` for a bound key and
/// ` !` when destructive), a copy by its label and the exact value it
/// copies.
List<String> describeActions(List<RowAction> actions) => [
  for (final action in actions)
    switch (action) {
      RowCommand(:final label, :final destructive, :final shortcut) =>
        '$label'
            '${shortcut == null ? '' : ' [${shortcut.trigger.keyLabel}]'}'
            '${destructive ? ' !' : ''}',
      RowCopy(:final label, :final value) => '$label = $value',
    },
];

/// Runs the command labelled [label] in [actions], as choosing it does.
void choose(List<RowAction> actions, String label) {
  for (final action in actions) {
    if (action case RowCommand(label: final named, :final onSelected)
        when named == label) {
      onSelected();
      return;
    }
  }
  throw StateError('no command "$label" in ${describeActions(actions)}');
}
