/// This installation's long-lived cryptographic identity (SPEC §4.4) — the
/// thing a peer pins when it pairs with us, and presents when it connects.
///
/// Both halves are PEM text rather than key objects because that is what
/// consumes them: `SecurityContext.useCertificateChainBytes` and
/// `usePrivateKeyBytes` read PEM, and the certificate is also what travels in
/// a pairing exchange. Holding parsed keys here would mean re-encoding at
/// every use for no reader that wants them.
///
/// Carries no device id yet. What the id is — which hash of which field, and
/// how it is rendered for a human — is still open (task 4ec17f), and inventing
/// one here would make the first guess permanent by being the one already in
/// the code.
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
}
