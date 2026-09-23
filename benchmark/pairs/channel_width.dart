/// A Wi-Fi channel's width, as the association negotiated it (task 84fc92).
///
/// The codes are Android's `ScanResult.CHANNEL_WIDTH_*`, which is also what
/// `WifiNative.ConnectionCapabilities` reports its `channelBandwidth` in.
enum ChannelWidth {
  mhz20('20 MHz'),
  mhz40('40 MHz'),
  mhz80('80 MHz'),
  mhz160('160 MHz'),
  mhz80Plus80('80+80 MHz'),
  mhz320('320 MHz');

  const ChannelWidth(this.label);

  final String label;

  /// Android's integer code, or null for one this does not know.
  static ChannelWidth? fromAndroidCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;

  /// A width written out in MHz, as `iw` and some dumps print it.
  static ChannelWidth? fromMhz(int mhz) => switch (mhz) {
    20 => mhz20,
    40 => mhz40,
    80 => mhz80,
    160 => mhz160,
    320 => mhz320,
    _ => null,
  };
}
