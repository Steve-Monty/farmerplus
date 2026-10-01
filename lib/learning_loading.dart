import 'dart:async';
import 'package:flutter/foundation.dart';

/// Bounds each page load and ignores callbacks from a retired viewer attempt.
class LearningLoading extends ChangeNotifier {
  final Duration timeout;
  LearningLoading({this.timeout = const Duration(seconds: 45)});

  Timer? _timer;
  int _attempt = 0;
  bool _disposed = false;
  bool loading = false;
  int progress = 0;
  String? error;

  bool owns(int attempt) => !_disposed && attempt == _attempt;
  bool accepts(int attempt) => owns(attempt) && error == null;

  int begin() {
    _attempt++;
    error = null;
    pageStarted(_attempt);
    return _attempt;
  }

  void pageStarted(int attempt) {
    if (!accepts(attempt)) return;
    loading = true;
    progress = 0;
    _timer?.cancel();
    _timer = Timer(
      timeout,
      () => fail(
        attempt,
        'Learning is taking too long to open. Check your connection and tap Retry. If it stays blank, restart your phone. Your saved lessons are still available.',
      ),
    );
    notifyListeners();
  }

  void updateProgress(int attempt, int value) {
    if (!accepts(attempt) || !loading) return;
    progress = value.clamp(0, 100);
    notifyListeners();
  }

  void finish(int attempt) {
    if (!accepts(attempt)) return;
    _timer?.cancel();
    loading = false;
    progress = 100;
    notifyListeners();
  }

  void fail(int attempt, String message) {
    if (!accepts(attempt)) return;
    _timer?.cancel();
    loading = false;
    error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
