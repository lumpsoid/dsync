// Pairs two state directories on this host with each other, for a
// desktop -> desktop `peer://` run over loopback (task 9a89f7). Not part of
// the build.
//
//   dart run benchmark/loopback_pair.dart \
//     --server-state /tmp/x/server --client-state /tmp/x/client/dsync \
//     --port 38771 --grant /tmp/x/dst-1 --grant /tmp/x/dst-2
//
// Why. `dsync pair show` insists on a terminal and a human answering `y`,
// which is right for two devices and in the way for two identities on one
// machine. This writes what a completed pairing would have: each side's
// identity (created if missing), each recorded in the other's paired-device
// store — the client as `client` on the server, granted --grant; the server
// as `server` on the client, at 127.0.0.1:--port. Everything after that is
// the real CLI and the real TLS transport:
//
//   dsync agent --serve --bind 127.0.0.1 --port 38771 --state-dir <server>
//   XDG_STATE_HOME=<client's parent> dsync sync <tree> peer://server:<dst> \
//     --batch --timings
//
// Pass --client-state as `<XDG_STATE_HOME>/dsync`: `sync` takes no
// --state-dir, so the client's is set through the environment.
import 'dart:io';

import 'package:args/args.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

Future<void> main(List<String> arguments) async {
  final args =
      (ArgParser()
            ..addOption('server-state', mandatory: true)
            ..addOption('client-state', mandatory: true)
            ..addOption('port', defaultsTo: '38771')
            ..addMultiOption('grant'))
          .parse(arguments);

  final serverState = Directory(args.option('server-state')!);
  final clientState = Directory(args.option('client-state')!);
  final port = int.parse(args.option('port')!);

  final server = await DeviceIdentityStore(serverState)
      .loadOrCreate(commonName: 'loopback-server');
  final client = await DeviceIdentityStore(clientState)
      .loadOrCreate(commonName: 'loopback-client');

  final now = DateTime.now().toUtc();
  await PairedDeviceStore(File('${serverState.path}/paired-devices.json')).add(
    PairedDevice(
      certificatePem: client.certificatePem,
      name: 'client',
      agreedReplicaRoots: {...args.multiOption('grant')},
      pairedAt: now,
      // The client never serves; an address is required, and unused.
      lastKnownAddress: PeerAddress(host: '127.0.0.1', port: 1),
    ),
  );
  await PairedDeviceStore(File('${clientState.path}/paired-devices.json')).add(
    PairedDevice(
      certificatePem: server.certificatePem,
      name: 'server',
      agreedReplicaRoots: const {},
      pairedAt: now,
      lastKnownAddress: PeerAddress(host: '127.0.0.1', port: port),
    ),
  );

  stdout.writeln('server ${server.deviceId}');
  stdout.writeln('client ${client.deviceId}');
}
