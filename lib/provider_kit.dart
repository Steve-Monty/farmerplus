import 'domain.dart';
import 'store.dart';

/// A facade for reviewed, compiled mini-apps; this is not an executable sandbox.
class MiniAppSession {
  final FarmStore _store;
  final MiniManifest manifest;
  MiniAppSession(this._store, this.manifest);
  Future<List<Map<String, dynamic>>> list(String kind) =>
      _store.records(kind, scope: manifest);
  Future<String> save(String kind, Map<String, dynamic> data, {String? id}) =>
      _store.save(kind, data, id: id, scope: manifest);
  Future<Map<String, dynamic>> content() => _store.content(manifest.id);
}

class PaymentReview {
  final AssetConfiguration asset;
  final String id, recipient, amount, fee;
  final DateTime expiresAt;
  const PaymentReview({
    required this.asset,
    required this.id,
    required this.recipient,
    required this.amount,
    required this.fee,
    required this.expiresAt,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'network': asset.network,
    'contract': asset.contract,
    'asset': asset.symbol,
    'custodyProvider': asset.custodyProvider,
    'recipient': recipient,
    'amount': amount,
    'fee': fee,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// Payment approval is transient and never part of the durable farm sync queue.
class PaymentApprovalGate {
  final WalletProvider provider;
  final Set<String> _submitted = {};
  PaymentApprovalGate(this.provider);
  Future<String> approve(
    PaymentReview review, {
    required String approvedQuoteId,
    required bool connected,
    required bool userApproved,
  }) async {
    final amount = RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$');
    if (!connected ||
        !userApproved ||
        review.id != approvedQuoteId ||
        _submitted.contains(review.id) ||
        !review.asset.valid ||
        review.recipient.trim().isEmpty ||
        !review.expiresAt.isAfter(DateTime.now().toUtc()) ||
        !amount.hasMatch(review.amount) ||
        !amount.hasMatch(review.fee) ||
        !RegExp(r'[1-9]').hasMatch(review.amount)) {
      throw StateError(
        'Refresh payment details and approve the current quote while connected.',
      );
    }
    _submitted.add(
      review.id,
    ); // An uncertain submission requires provider status reconciliation, never blind retry.
    return provider.submit(review.toJson(), explicitlyApproved: true);
  }
}

/// Existing learning service owns entitlements, grading and official completion.
abstract class LearningProvider {
  Future<List<Map<String, dynamic>>> myCourses();
  Future<Map<String, dynamic>> entitlement(String courseId, int version);
  Future<Map<String, dynamic>> permittedPackage(String courseId, int version);
  Future<Map<String, dynamic>> submitProgress({
    required String eventId,
    required String courseId,
    required int version,
    required Map<String, dynamic> evidence,
  });
  Future<Map<String, dynamic>> authoritativeResult(String courseId);
}

class DisconnectedLearning implements LearningProvider {
  Never unavailable() => throw StateError(
    'Your learning service is not connected. Sample progress is local practice only.',
  );
  @override
  Future<List<Map<String, dynamic>>> myCourses() async => unavailable();
  @override
  Future<Map<String, dynamic>> entitlement(
    String courseId,
    int version,
  ) async => unavailable();
  @override
  Future<Map<String, dynamic>> permittedPackage(
    String courseId,
    int version,
  ) async => unavailable();
  @override
  Future<Map<String, dynamic>> submitProgress({
    required String eventId,
    required String courseId,
    required int version,
    required Map<String, dynamic> evidence,
  }) async => unavailable();
  @override
  Future<Map<String, dynamic>> authoritativeResult(String courseId) async =>
      unavailable();
}
