import 'replica_side.dart';

/// What the core says of comparing a review row's two files, judged
/// before a byte is read.
sealed class CompareOffer {
  const CompareOffer();
}

final class OfferNotComparable extends CompareOffer {
  const OfferNotComparable();
}

/// Both files can be read as text.
final class OfferReadable extends CompareOffer {
  const OfferReadable();
}

/// The files are media; there is no text to compare.
final class OfferMedia extends CompareOffer {
  const OfferMedia();
}

/// The file on [side] is [size] bytes, too large to read.
final class OfferTooLarge extends CompareOffer {
  const OfferTooLarge(this.side, this.size);

  final ReplicaSide side;
  final int size;
}
