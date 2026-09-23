/// How the two arms of a comparison alternate within one sitting (task
/// 84fc92).
enum PairOrder {
  /// A B A B … — every run switches arm.
  abab,

  /// A B B A A B … — also cancels a drift that is linear in time, and
  /// switches arm half as often, which matters when a switch is a reinstall.
  abba;

  /// The arm index (0 or 1) of each run, [pairs] of each.
  List<int> sequence(int pairs) => [
    for (var pair = 0; pair < pairs; pair++)
      ...switch (this) {
        abab => const [0, 1],
        abba => pair.isEven ? const [0, 1] : const [1, 0],
      },
  ];
}
