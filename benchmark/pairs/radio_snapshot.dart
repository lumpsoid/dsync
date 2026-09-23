import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'channel_width.dart';

/// The phone's Wi-Fi association at one instant, parsed from what `adb shell`
/// can read without root (task 84fc92).
///
/// Taken at the start and the end of every measured run, because the link
/// drifts between runs by more than the changes being measured, and the one
/// column that separated this project's two unexplained eras was the phone's
/// association — band, width, rate — changing and staying changed.
///
/// **Every field is optional, and absent means "the dump did not say".** Two
/// devices on two Android versions print this, and the parser is written
/// against the documented `WifiInfo.toString` rather than against a capture
/// from each. A field it cannot find is shown as `?`, never guessed.
///
/// What it deliberately does not hold: network name, BSSID, MAC or IP. The AP
/// is kept as [apFingerprint], so two runs can be compared for "same AP?"
/// without the address being written into a report.
class RadioSnapshot {
  const RadioSnapshot({
    this.apFingerprint,
    required this.frequencyMhz,
    this.width,
    this.standard,
    this.rssiDbm,
    this.txLinkMbps,
    this.rxLinkMbps,
    this.txPackets,
    this.txRetried,
    this.txLost,
  });

  /// The first eight hex digits of the SHA-256 of the BSSID and a newline —
  /// the same fingerprint `scripts/phone-radio` prints, so the two agree.
  final String? apFingerprint;

  /// The associated channel's centre frequency. Required: a dump with no
  /// frequency is a phone that is not associated, and that is no snapshot.
  final int frequencyMhz;

  final ChannelWidth? width;

  /// `11ac`, `11ax` and so on.
  final String? standard;

  final int? rssiDbm;

  /// The negotiated rates. Android reports -1 for "unknown", which is kept as
  /// null here so it cannot be read as a rate.
  final int? txLinkMbps;
  final int? rxLinkMbps;

  /// Cumulative since boot, so only a difference between two snapshots
  /// describes a run.
  final int? txPackets;
  final int? txRetried;
  final int? txLost;

  /// Parses `cmd wifi status` and `dumpsys wifi`, either of which may be empty.
  ///
  /// Returns null when neither holds an associated `WifiInfo` — the phone is
  /// off the network, or adb gave back an error rather than a dump.
  static RadioSnapshot? parse({
    required String wifiStatus,
    required String dumpsys,
  }) {
    final info = _wifiInfo(wifiStatus) ?? _wifiInfo(dumpsys);
    if (info == null) return null;
    final frequency = _positive(info['Frequency']);
    if (frequency == null) return null;
    final bssid = info['BSSID']?.trim();
    return RadioSnapshot(
      apFingerprint: bssid == null || bssid.isEmpty
          ? null
          : sha256.convert(utf8.encode('$bssid\n')).toString().substring(0, 8),
      frequencyMhz: frequency,
      width: _width('$wifiStatus\n$dumpsys', bssid),
      standard: _standard(info['Wi-Fi standard']),
      rssiDbm: _rssi(info['RSSI']),
      txLinkMbps: _positive(info['Tx Link speed'] ?? info['Link speed']),
      rxLinkMbps: _positive(info['Rx Link speed']),
      txPackets: _counter(wifiStatus, 'successfulTxPackets'),
      txRetried: _counter(wifiStatus, 'retriedTxPackets'),
      txLost: _counter(wifiStatus, 'lostTxPackets'),
    );
  }

  String get band => switch (frequencyMhz) {
    >= 2400 && < 2500 => '2.4 GHz',
    >= 4900 && < 5925 => '5 GHz',
    >= 5925 && < 7200 => '6 GHz',
    _ => '$frequencyMhz MHz',
  };

  /// The IEEE channel number, or null for a frequency outside the three
  /// bands.
  int? get channel => switch (frequencyMhz) {
    2484 => 14,
    >= 2400 && < 2500 => (frequencyMhz - 2407) ~/ 5,
    >= 4900 && < 5925 => (frequencyMhz - 5000) ~/ 5,
    >= 5925 && < 7200 => (frequencyMhz - 5950) ~/ 5,
    _ => null,
  };

  /// One line: `5 GHz ch36 80 MHz 11ac, 866/866 Mbps, -45 dBm, ap 1a2b3c4d`.
  String describe() {
    String or(Object? value) => value?.toString() ?? '?';
    return '$band ch${or(channel)} ${width?.label ?? 'width ?'} '
        '${or(standard)}, ${or(txLinkMbps)}/${or(rxLinkMbps)} Mbps, '
        '${or(rssiDbm)} dBm, ap ${or(apFingerprint)}';
  }

  /// What about the association differs in [later]: AP, frequency, width,
  /// standard. Empty when it is the same association.
  ///
  /// Rate and RSSI are left out on purpose: rate adaptation moves them within
  /// one association all the time, so they are printed rather than judged.
  /// A field one side could not read is not a difference.
  List<String> associationChangesTo(RadioSnapshot later) => [
    if (_differ(apFingerprint, later.apFingerprint)) 'AP changed',
    if (frequencyMhz != later.frequencyMhz)
      '$band ch${channel ?? '?'} -> ${later.band} ch${later.channel ?? '?'}',
    if (_differ(width, later.width)) '${width!.label} -> ${later.width!.label}',
    if (_differ(standard, later.standard)) '$standard -> ${later.standard}',
  ];

  /// Retried transmissions as a share of successful ones between this
  /// snapshot and [later], or null when either lacks the counters or nothing
  /// was sent.
  double? retryShareUntil(RadioSnapshot later) {
    final sent = _delta(txPackets, later.txPackets);
    final retried = _delta(txRetried, later.txRetried);
    if (sent == null || retried == null || sent <= 0) return null;
    return retried / sent;
  }
}

bool _differ(Object? a, Object? b) => a != null && b != null && a != b;

int? _delta(int? from, int? to) =>
    from == null || to == null ? null : to - from;

/// `WifiInfo.toString`'s one long `key: value, key: value` line, as a map.
///
/// Found as the first line carrying both `RSSI:` and `Frequency:`, which
/// covers `cmd wifi status`'s `WifiInfo: SSID: …` and `dumpsys wifi`'s
/// `mWifiInfo SSID: …` alike. A value holding `, ` (an SSID can) only
/// corrupts its own key and the SSID is not read.
Map<String, String>? _wifiInfo(String text) {
  for (final line in const LineSplitter().convert(text)) {
    if (!line.contains('RSSI:') || !line.contains('Frequency:')) continue;
    final fields = <String, String>{};
    for (final segment in line.split(', ')) {
      final colon = segment.lastIndexOf(': ');
      if (colon < 0) continue;
      final key = segment.substring(0, colon).trim();
      // `WifiInfo: SSID: "x"` splits as key `WifiInfo: SSID` — keep the last
      // word-run after any earlier `: `, which is the real key.
      final innerColon = key.lastIndexOf(': ');
      fields.putIfAbsent(
        innerColon < 0 ? key : key.substring(innerColon + 2),
        () => segment.substring(colon + 2).trim(),
      );
    }
    return fields;
  }
  return null;
}

final _integer = RegExp(r'-?\d+');

int? _integerIn(String? value) {
  if (value == null) return null;
  final match = _integer.firstMatch(value);
  return match == null ? null : int.parse(match.group(0)!);
}

int? _positive(String? value) {
  final number = _integerIn(value);
  return number == null || number <= 0 ? null : number;
}

/// Android prints -127 for "no reading".
int? _rssi(String? value) {
  final number = _integerIn(value);
  return number == null || number <= -127 || number >= 0 ? null : number;
}

/// `ScanResult.WIFI_STANDARD_*`, for a build that prints the code rather than
/// the name.
const _standardCodes = {
  1: 'legacy',
  4: '11n',
  5: '11ac',
  6: '11ax',
  7: '11ad',
  8: '11be',
};

String? _standard(String? value) {
  if (value == null || value.isEmpty) return null;
  final code = int.tryParse(value);
  if (code == null) return value == 'unknown' ? null : value;
  return _standardCodes[code];
}

int? _counter(String text, String name) {
  final match = RegExp(
    '^\\s*$name:\\s*(\\d+)',
    multiLine: true,
  ).firstMatch(text);
  return match == null ? null : int.parse(match.group(1)!);
}

final _widthInMhz = RegExp(
  r'(?:channel[ _]?)?width\s*[:=]\s*(\d+)\s*MHz',
  caseSensitive: false,
);
final _scanBandwidth = RegExp(r'ChannelBandwidth:\s*(\d+)');
final _connectionBandwidth = RegExp(r'channelBandwidth\s*=\s*(\d+)');

/// The least certain field: `WifiInfo` does not carry it, so it is looked for
/// in three places, most specific first.
///
/// 1. A width written in MHz (`width: 80 MHz`, `iw`'s form).
/// 2. `ScanResult.toString`'s `ChannelBandwidth: N`, on a line that also
///    names this association's BSSID — a dump lists every AP in range, and
///    another AP's width is not this link's.
/// 3. `ConnectionCapabilities`' `channelBandwidth=N`.
ChannelWidth? _width(String text, String? bssid) {
  final inMhz = _widthInMhz.firstMatch(text);
  if (inMhz != null) {
    final width = ChannelWidth.fromMhz(int.parse(inMhz.group(1)!));
    if (width != null) return width;
  }
  if (bssid != null && bssid.isNotEmpty) {
    for (final line in const LineSplitter().convert(text)) {
      if (!line.contains(bssid)) continue;
      final match = _scanBandwidth.firstMatch(line);
      if (match != null) {
        return ChannelWidth.fromAndroidCode(int.parse(match.group(1)!));
      }
    }
  }
  final capabilities = _connectionBandwidth.firstMatch(text);
  return capabilities == null
      ? null
      : ChannelWidth.fromAndroidCode(int.parse(capabilities.group(1)!));
}
