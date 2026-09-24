/// This machine's interface addresses, and the one a peer is best told to
/// dial.
final class ServeAddresses {
  const ServeAddresses({required this.interfaces, required this.preferred});

  final List<String> interfaces;
  final String? preferred;
}
