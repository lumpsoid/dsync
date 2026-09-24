part of 'signals.dart';

final assignRustSignal = <String, void Function(Uint8List, Uint8List)>{
  'ServeFailed': (Uint8List messageBytes, Uint8List binary) {
    final message = ServeFailed.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _serveFailedStreamController.add(rustSignal);
    ServeFailed.latestRustSignal = rustSignal;
  },
  'ServeReady': (Uint8List messageBytes, Uint8List binary) {
    final message = ServeReady.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _serveReadyStreamController.add(rustSignal);
    ServeReady.latestRustSignal = rustSignal;
  },
  'TransferDone': (Uint8List messageBytes, Uint8List binary) {
    final message = TransferDone.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _transferDoneStreamController.add(rustSignal);
    TransferDone.latestRustSignal = rustSignal;
  },
  'TransferProgress': (Uint8List messageBytes, Uint8List binary) {
    final message = TransferProgress.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _transferProgressStreamController.add(rustSignal);
    TransferProgress.latestRustSignal = rustSignal;
  },
};
