// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Where the run stands for what the head may do with it: `Live` from
/// connecting to applying (the screen is held, leaving asks first, a
/// stop is offered); `Resumable` when an attempt ended short and a resume
/// runs it again (paused, failed, the replica busy, the deletions
/// declined, no summary); `Over` when it finished or was stopped.
enum RunStandingView {
  live,
  resumable,
  over,
}

extension RunStandingViewExtension on RunStandingView {
  static RunStandingView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunStandingView.live;
      case 1: return RunStandingView.resumable;
      case 2: return RunStandingView.over;
      default: throw Exception('Unknown variant index for RunStandingView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case RunStandingView.live: return serializer.serializeVariantIndex(0);
      case RunStandingView.resumable: return serializer.serializeVariantIndex(1);
      case RunStandingView.over: return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunStandingView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunStandingViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

