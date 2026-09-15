import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';

/// This installation's long-lived cryptographic identity (SPEC §4.4) — the
/// thing a peer pins when it pairs with us, and presents when it connects.
///
/// Both halves are PEM text rather than key objects because that is what
/// consumes them: `SecurityContext.useCertificateChainBytes` and
/// `usePrivateKeyBytes` read PEM, and the certificate is also what travels in
/// a pairing exchange. Holding parsed keys here would mean re-encoding at
/// every use for no reader that wants them.
class DeviceIdentity {
  /// The self-signed X.509 certificate, PEM-encoded.
  ///
  /// Self-signed *and* a CA, which is not a contradiction here: `dart:io`'s
  /// `SecureServerSocket` has no `onBadCertificate` hook, so BoringSSL
  /// verifies a peer's certificate before any code can inspect it, and a
  /// certificate can only be installed as a trust anchor if it can be its own
  /// issuer. See `generateDeviceIdentity`.
  final String certificatePem;

  /// The matching private key as PKCS#8, PEM-encoded. Never leaves the host.
  final String privateKeyPem;

  const DeviceIdentity({
    required this.certificatePem,
    required this.privateKeyPem,
  });

  /// This identity's device id (SPEC §4.4): SHA-256 of the certificate's
  /// `SubjectPublicKeyInfo`, lowercase hex in 4-character groups.
  ///
  /// Computed from [certificatePem] on every access through
  /// [deviceIdFromCertificateDer] — the same function a paired peer's id goes
  /// through — rather than cached at construction. There is exactly one path
  /// from certificate bytes to id, so nothing here can hold an id that has
  /// drifted from the certificate it was built from; asking a save/load
  /// round trip for its id and asking the identity that was never written to
  /// disk both answer through this same getter.
  String get deviceId => deviceIdFromCertificateDer(certificateDer);

  /// The certificate's raw DER bytes, decoded out of [certificatePem].
  Uint8List get certificateDer => certificateDerFromPem(certificatePem);
}
