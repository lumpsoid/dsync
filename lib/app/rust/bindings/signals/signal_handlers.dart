part of 'signals.dart';

final assignRustSignal = <String, void Function(Uint8List, Uint8List)>{
  'CoreReply': (Uint8List messageBytes, Uint8List binary) {
    final message = CoreReply.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _coreReplyStreamController.add(rustSignal);
    CoreReply.latestRustSignal = rustSignal;
  },
  'PairingSnapshot': (Uint8List messageBytes, Uint8List binary) {
    final message = PairingSnapshot.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _pairingSnapshotStreamController.add(rustSignal);
    PairingSnapshot.latestRustSignal = rustSignal;
  },
  'RunSnapshot': (Uint8List messageBytes, Uint8List binary) {
    final message = RunSnapshot.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _runSnapshotStreamController.add(rustSignal);
    RunSnapshot.latestRustSignal = rustSignal;
  },
  'ServeSnapshot': (Uint8List messageBytes, Uint8List binary) {
    final message = ServeSnapshot.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _serveSnapshotStreamController.add(rustSignal);
    ServeSnapshot.latestRustSignal = rustSignal;
  },
};
