import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/pairs/channel_width.dart';
import '../../benchmark/pairs/radio_snapshot.dart';

/// `adb shell cmd wifi status` as AOSP's WifiShellCommand prints it on
/// Android 14: `WifiInfo.toString` on one line, the packet counters below.
String wifiStatus({
  String standard = '11ac',
  String txLink = '866Mbps',
  String frequency = '5180MHz',
  String rssi = '-45',
  int txPackets = 1203311,
  int retried = 20411,
}) =>
    '''
Wifi is enabled
Wifi scanning is always available
Wifi is connected to "Home, Net"
WifiInfo: SSID: "Home, Net", BSSID: 3c:84:6a:12:34:56, MAC: 02:00:00:00:00:00, IP: /192.168.1.23, Security type: 2, Supplicant state: COMPLETED, Wi-Fi standard: $standard, RSSI: $rssi, Link speed: $txLink, Tx Link speed: $txLink, Max Supported Tx Link speed: 866Mbps, Rx Link speed: 780Mbps, Max Supported Rx Link speed: 866Mbps, Frequency: $frequency, Net ID: 3, Metered hint: false, score: 60, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"Home, Net"MLO Information: , Is TID-To-Link Mapping supported: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>
successfulTxPackets: $txPackets
successfulTxPacketsPerSecond: 12.5
retriedTxPackets: $retried
retriedTxPacketsPerSecond: 0.0
lostTxPackets: 17
lostTxPacketsPerSecond: 0.0
successfulRxPackets: 2210034
successfulRxPacketsPerSecond: 30.1
''';

RadioSnapshot parse(String status, [String dumpsys = '']) =>
    RadioSnapshot.parse(wifiStatus: status, dumpsys: dumpsys)!;

void main() {
  test('reads the association out of cmd wifi status', () {
    final radio = parse(wifiStatus());

    expect(radio.frequencyMhz, 5180);
    expect(radio.band, '5 GHz');
    expect(radio.channel, 36);
    expect(radio.standard, '11ac');
    expect(radio.rssiDbm, -45);
    expect(radio.txLinkMbps, 866);
    expect(radio.rxLinkMbps, 780);
    expect(radio.txPackets, 1203311);
    expect(radio.txRetried, 20411);
    expect(radio.txLost, 17);
    expect(radio.width, isNull);
  });

  test('fingerprints the AP the way scripts/phone-radio does', () {
    final expected = sha256
        .convert(utf8.encode('3c:84:6a:12:34:56\n'))
        .toString()
        .substring(0, 8);

    expect(parse(wifiStatus()).apFingerprint, expected);
    expect(parse(wifiStatus()).describe(), isNot(contains('3c:84')));
  });

  test('takes the width from this AP\'s scan result, not a neighbour\'s', () {
    const dumpsys = '''
Latest scan results:
SSID: "Other", BSSID: 9a:00:00:00:00:01, capabilities: [ESS], level: -70, frequency: 5500, ChannelBandwidth: 1, centerFreq0: 5510, standard: 11n
SSID: "Home, Net", BSSID: 3c:84:6a:12:34:56, capabilities: [ESS], level: -45, frequency: 5180, ChannelBandwidth: 2, centerFreq0: 5210, standard: 11ac
''';

    expect(parse(wifiStatus(), dumpsys).width, ChannelWidth.mhz80);
  });

  test('takes the width from the connection capabilities', () {
    expect(
      parse(wifiStatus(), 'ConnectionCapabilities: channelBandwidth=3').width,
      ChannelWidth.mhz160,
    );
  });

  test('takes a width written in MHz first', () {
    expect(
      parse(wifiStatus(), 'width: 40 MHz\nchannelBandwidth=2').width,
      ChannelWidth.mhz40,
    );
  });

  test('an unknown width is shown as unknown, not guessed', () {
    expect(parse(wifiStatus()).describe(), contains('width ?'));
  });

  test('a numeric standard and an unknown rate are read tolerantly', () {
    final radio = parse(wifiStatus(standard: '5', txLink: '-1Mbps'));

    expect(radio.standard, '11ac');
    expect(radio.txLinkMbps, isNull);
  });

  test('falls back to dumpsys wifi when cmd wifi status gave nothing', () {
    final dumpsys = wifiStatus().replaceFirst('WifiInfo: ', 'mWifiInfo ');

    expect(
      RadioSnapshot.parse(wifiStatus: '', dumpsys: dumpsys)!.frequencyMhz,
      5180,
    );
  });

  test('a phone that is not associated is no snapshot', () {
    expect(
      RadioSnapshot.parse(
        wifiStatus: wifiStatus(frequency: '-1MHz', rssi: '-127'),
        dumpsys: '',
      ),
      isNull,
    );
    expect(RadioSnapshot.parse(wifiStatus: '', dumpsys: ''), isNull);
    expect(
      RadioSnapshot.parse(
        wifiStatus: 'error: no devices/emulators found',
        dumpsys: '',
      ),
      isNull,
    );
  });

  test('bands and channels at their edges', () {
    RadioSnapshot at(int mhz) => RadioSnapshot(frequencyMhz: mhz);

    expect((at(2437).band, at(2437).channel), ('2.4 GHz', 6));
    expect(at(2484).channel, 14);
    expect((at(5745).band, at(5745).channel), ('5 GHz', 149));
    expect((at(5955).band, at(5955).channel), ('6 GHz', 1));
  });

  group('associationChangesTo', () {
    test('is empty for the same association at another rate and RSSI', () {
      final start = parse(wifiStatus());
      final end = parse(wifiStatus(txLink: '650Mbps', rssi: '-52'));

      expect(start.associationChangesTo(end), isEmpty);
    });

    test('names a move of band, width and standard', () {
      const start = RadioSnapshot(
        frequencyMhz: 5180,
        width: ChannelWidth.mhz80,
        standard: '11ac',
      );
      const end = RadioSnapshot(
        frequencyMhz: 2437,
        width: ChannelWidth.mhz20,
        standard: '11n',
      );

      expect(start.associationChangesTo(end), [
        '5 GHz ch36 -> 2.4 GHz ch6',
        '80 MHz -> 20 MHz',
        '11ac -> 11n',
      ]);
    });

    test('a field one side could not read is not a change', () {
      const start = RadioSnapshot(
        frequencyMhz: 5180,
        width: ChannelWidth.mhz80,
      );
      const end = RadioSnapshot(frequencyMhz: 5180);

      expect(start.associationChangesTo(end), isEmpty);
    });
  });

  test('retry share is taken over the run, not since boot', () {
    final start = parse(wifiStatus(txPackets: 1000, retried: 100));
    final end = parse(wifiStatus(txPackets: 3000, retried: 150));

    expect(start.retryShareUntil(end), 0.025);
  });
}
