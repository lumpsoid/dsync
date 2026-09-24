/// What a scanned or pasted pairing code says, before it is redeemed.
sealed class PairCodeReading {
  const PairCodeReading();
}

/// Not a payload this build can use; [message] says which way.
final class UnreadablePairCode extends PairCodeReading {
  const UnreadablePairCode(this.message);

  final String message;
}

final class ReadPairCode extends PairCodeReading {
  const ReadPairCode({
    required this.desktopName,
    required this.address,
    required this.deviceId,
  });

  /// The name field's default for the showing device.
  final String desktopName;

  /// Where it will answer from now on (its peer:// address).
  final String address;
  final String? deviceId;
}
