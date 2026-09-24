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
  'EnrolmentUpdate': (Uint8List messageBytes, Uint8List binary) {
    final message = EnrolmentUpdate.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _enrolmentUpdateStreamController.add(rustSignal);
    EnrolmentUpdate.latestRustSignal = rustSignal;
  },
  'RunUpdate': (Uint8List messageBytes, Uint8List binary) {
    final message = RunUpdate.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _runUpdateStreamController.add(rustSignal);
    RunUpdate.latestRustSignal = rustSignal;
  },
  'ServeUpdate': (Uint8List messageBytes, Uint8List binary) {
    final message = ServeUpdate.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _serveUpdateStreamController.add(rustSignal);
    ServeUpdate.latestRustSignal = rustSignal;
  },
};
