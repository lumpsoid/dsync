import 'package:dsync/app/core_link/models/enrolment_outcome.dart';
import 'package:dsync/app/core_link/models/enrolment_update.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/serve_update.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;

/// A session update as the hub's signal carries it, so a test can write
/// the update in the head's own terms and [FakeHub] delivers what the hub
/// would send.

wire.ServeUpdateBody wireServeUpdate(ServeUpdate update) => switch (update) {
  ServeRefused(:final from, :final message) => wire.ServeUpdateBodyRefused(
    from: from,
    message: message,
  ),
  ServeSessionStarted(:final from, :final deviceId, :final name) =>
    wire.ServeUpdateBodyStarted(from: from, deviceId: deviceId, name: name),
  ServeServing(:final root) => wire.ServeUpdateBodyServing(root: root),
  ServeSessionEnded(
    :final from,
    :final deviceId,
    :final name,
    :final failure,
  ) =>
    wire.ServeUpdateBodyEnded(
      from: from,
      deviceId: deviceId,
      name: name,
      failure: failure,
    ),
  ServeStopped(:final failure) => wire.ServeUpdateBodyStopped(failure: failure),
};

wire.EnrolmentUpdateBody wireEnrolmentUpdate(EnrolmentUpdate update) =>
    switch (update) {
      EnrolmentRefused(:final from, :final message) =>
        wire.EnrolmentUpdateBodyRefused(from: from, message: message),
      EnrolmentAwaiting(:final from, :final deviceId, :final name) =>
        wire.EnrolmentUpdateBodyAwaiting(
          from: from,
          deviceId: deviceId,
          name: name,
        ),
      EnrolmentEnded(:final outcome) => wire.EnrolmentUpdateBodyEnded(
        value: switch (outcome) {
          Enrolled(:final device) => wire.EnrolmentEndViewEnrolled(
            value: _device(device),
          ),
          EnrolmentDeclined(:final deviceId) => wire.EnrolmentEndViewDeclined(
            deviceId: deviceId,
          ),
          EnrolmentUnconfirmed(:final deviceId) =>
            wire.EnrolmentEndViewUnconfirmed(deviceId: deviceId),
          EnrolmentNotStored(:final deviceId, :final message) =>
            wire.EnrolmentEndViewNotStored(
              deviceId: deviceId,
              message: message,
            ),
          EnrolmentExpired() => const wire.EnrolmentEndViewExpired(),
          EnrolmentCancelled() => const wire.EnrolmentEndViewCancelled(),
          EnrolmentFailed(:final message) => wire.EnrolmentEndViewFailed(
            message: message,
          ),
        },
      ),
    };

wire.DeviceView _device(PairedDeviceInfo device) => wire.DeviceView(
  deviceId: device.deviceId,
  name: device.name,
  commonName: device.commonName,
  grantedRoots: device.grantedRoots,
  address: device.address,
  pairedAtMs: device.pairedAt.millisecondsSinceEpoch,
  verifiedAtMs: device.verifiedAt?.millisecondsSinceEpoch,
  notBeforeMs: device.issuedAt.millisecondsSinceEpoch,
  notAfterMs: device.expiresAt.millisecondsSinceEpoch,
  expiryNote: device.expiryNote,
);
