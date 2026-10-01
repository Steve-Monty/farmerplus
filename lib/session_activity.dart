import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'auth.dart' show AccountAccess;
import 'sync.dart';

/// Only actual interaction extends activity. Polling and sync never do.
class InactivityClock {
  static const limit = Duration(minutes: 30);
  DateTime last;
  InactivityClock(this.last);
  bool expired(DateTime now) => now.difference(last) >= limit;
  bool touch(DateTime now) {
    if (expired(now)) return false;
    last = now;
    return true;
  }
}

class SessionActivity extends StatefulWidget {
  static bool expired = false;
  static VoidCallback? recordInteraction;
  final SyncEngine sync;
  final Widget child;
  final VoidCallback onLock;
  const SessionActivity({
    super.key,
    required this.sync,
    required this.child,
    required this.onLock,
  });
  @override
  State<SessionActivity> createState() => _SessionActivityState();
}

class _SessionActivityState extends State<SessionActivity>
    with WidgetsBindingObserver {
  InactivityClock? clock;
  DateTime sent = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? reportedActivity;
  Timer? timer;
  bool sending = false, locking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AccountAccess.unlocked.addListener(accountChanged);
    SessionActivity.recordInteraction = activity;
    accountChanged();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => check());
  }

  void accountChanged() {
    clock = AccountAccess.unlocked.value == null
        ? null
        : InactivityClock(DateTime.now());
    if (clock != null) {
      SessionActivity.expired = false;
      unawaited(report());
    }
  }

  void check() {
    if (clock?.expired(DateTime.now()) == true) {
      unawaited(lock());
      return;
    }
    if (clock != null &&
        reportedActivity != clock!.last &&
        DateTime.now().difference(sent) >= const Duration(seconds: 45))
      unawaited(report());
  }

  void activity() {
    final current = clock;
    if (current == null || locking) return;
    if (!current.touch(DateTime.now())) {
      unawaited(lock());
      return;
    }
    if (DateTime.now().difference(sent) >= const Duration(seconds: 45)) {
      unawaited(report());
    }
  }

  Future<void> report() async {
    if (!kIsWeb || sending || clock == null || locking) return;
    sending = true;
    try {
      final last = clock!.last;
      await widget.sync.request(
        'POST',
        '/auth/activity',
        body: {
          'idleForSeconds': DateTime.now()
              .difference(last)
              .inSeconds
              .clamp(0, 1799),
        },
      );
      reportedActivity = last;
      sent = DateTime.now();
    } catch (_) {
      /* Network failure does not lock active local work. Server rejection is handled by AuthGate. */
    } finally {
      sending = false;
    }
  }

  Future<void> lock() async {
    if (locking || clock == null) return;
    locking = true;
    SessionActivity.expired = true;
    await AccountAccess.lock();
    await widget.sync.clearLocalSession();
    if (mounted) widget.onLock();
    locking = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  @override
  void dispose() {
    SessionActivity.recordInteraction = null;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    AccountAccess.unlocked.removeListener(accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => activity(),
    onPointerMove: (_) => activity(),
    onPointerSignal: (_) => activity(),
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        activity();
        return KeyEventResult.ignored;
      },
      child: widget.child,
    ),
  );
}
