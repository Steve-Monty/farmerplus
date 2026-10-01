import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'learning.dart';
import 'store.dart';
import 'sync.dart';
import 'ui.dart';
import 'appearance.dart';
import 'offline_access.dart';
import 'recovery.dart';
import 'registration.dart';
import 'account_workspaces.dart';
import 'sign_in_location.dart';

const activities = [
  'None',
  'Cassava',
  'Wheat',
  'Horticulture & vegetables',
  'Livestock',
  'Maize',
  'Rice',
  'Other farming activity',
];
String? passwordIssue(String value) =>
    value.length < 8 ||
        !RegExp('[A-Z]').hasMatch(value) ||
        !RegExp('[a-z]').hasMatch(value)
    ? 'Use at least 8 characters with uppercase and lowercase letters.'
    : null;

class AccountAccess {
  static const secure = FlutterSecureStorage();
  static final unlocked = ValueNotifier<String?>(null);
  static int browserUntil = 0, browserChecked = 0;
  static bool offlineSession = false, authenticating = false;
  static Future<void> restore(FarmStore store, [SyncEngine? sync]) async {
    final revision = sync?.credentialRevision;
    if (!kIsWeb &&
        unlocked.value == null &&
        await OfflineAccess.biometricEnabled()) {
      return;
    }
    if (sync != null && !kIsWeb && !await sync.onlineAvailable()) {
      if (!offlineSession) unlocked.value = null;
      return;
    }
    if (sync != null &&
        !kIsWeb &&
        sync.token == null &&
        await sync.oidcStored() == null &&
        await sync.secure.read(key: 'syncToken') == null) {
      if (!offlineSession) unlocked.value = null;
      return;
    }
    if (sync != null) {
      try {
        final me = Map<String, dynamic>.from(
          await sync.request('GET', '/auth/me'),
        );
        if (revision != sync.credentialRevision ||
            sync.credentialChangeInProgress) {
          return;
        }
        if (me['accountKind'] != 'oidc') {
          throw StateError('A verified single sign-on session is required.');
        }
        final owner = 'farmerplus:${me['studentId']}';
        await verifyOwner(
          store,
          owner,
          syncOwner: me['owner'],
          verifiedPermanent: true,
        );
        if (kIsWeb) await sync.acceptOidc(me);
        final offlineReady =
            !kIsWeb && await OfflineAccess(store, sync).matches(me);
        if (!kIsWeb &&
            (revision != sync.credentialRevision ||
                sync.credentialChangeInProgress)) {
          return;
        }
        await unlock(
          store,
          owner,
          me['username'],
          'oidc',
          offline: offlineReady,
        );
        return;
      } on SyncRequestError catch (e) {
        if (revision != sync.credentialRevision ||
            sync.credentialChangeInProgress) {
          return;
        }
        if ({401, 403, 409}.contains(e.statusCode)) {
          await OfflineAccess.clear();
          await lock();
          return;
        }
      } on SyncTransportError {
        // Keep only an already verified, offline-capable in-memory session.
      } on PlatformException {
        await lock();
        return;
      } on StateError {
        await lock();
        return;
      } catch (_) {}
    }
    if (kIsWeb) {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (now >= browserUntil ||
          now < browserChecked - 60000 ||
          unlocked.value != await store.setting('accessOwner')) {
        unlocked.value = null;
      }
      return;
    }
    // Cold offline starts require a password, not a cached bearer-session flag.
    if (!offlineSession ||
        unlocked.value != await store.setting('accessOwner')) {
      unlocked.value = null;
    }
  }

  static Future<void> lock() async {
    unlocked.value = null;
    offlineSession = false;
    browserUntil = 0;
    if (!kIsWeb) {
      await secure.delete(key: 'farmer.access.owner');
      await secure.delete(key: 'farmer.access.until');
    }
  }

  static Future<void> verifyOwner(
    FarmStore store,
    String owner, {
    String? syncOwner,
    bool verifiedPermanent = false,
  }) async {
    final bound = await store.setting('accessOwner');
    final oldSync = await store.setting('boundOwner');
    final verifiedMigration =
        verifiedPermanent &&
        bound == 'local:$syncOwner' &&
        oldSync == syncOwner;
    if ((bound != null && bound != owner && !verifiedMigration) ||
        (bound == null && oldSync != null && oldSync != syncOwner)) {
      throw StateError(
        'This device belongs to another account. Sign in to its original account to recover the saved records. Nothing has been removed or transferred.',
      );
    }
    final learner = await store.setting('learningUser');
    if (bound == null &&
        oldSync == null &&
        learner != null &&
        owner != 'moodle:${learner['id']}') {
      throw StateError(
        'Existing lessons belong to a Learning account. Sign in with that account to keep your records and downloads together.',
      );
    }
  }

  static Future<void> unlock(
    FarmStore store,
    String owner,
    String name,
    String kind, {
    bool offline = false,
  }) async {
    await store.setSetting('accessOwner', owner);
    await store.setSetting('accountName', name);
    await store.setSetting('accountKind', kind);
    await store.setSetting(
      'migrationNotice',
      'Existing records, drafts and downloads were kept and linked to this account on this device.',
    );
    if (!kIsWeb) {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await secure.write(key: 'farmer.access.owner', value: owner);
      await secure.write(key: 'farmer.access.checked', value: '$now');
      await secure.write(
        key: 'farmer.access.until',
        value: '${now + 86400000}',
      );
    } else {
      browserChecked = DateTime.now().toUtc().millisecondsSinceEpoch;
      browserUntil = browserChecked + 86400000;
    }
    offlineSession = offline;
    unlocked.value = owner;
  }

  static Future<void> signOut(FarmStore store, SyncEngine sync) async {
    await OfflineAccess.clear();
    await lock();
    await StudentLearning(store).clearSession();
    await sync.logout();
  }
}

class AuthGate extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Widget child;
  const AuthGate({
    super.key,
    required this.store,
    required this.sync,
    required this.child,
  });
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool loaded = false;
  bool checking = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    SyncEngine.accessRejected.addListener(rejected);
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load());
  }

  void rejected() async {
    if (SyncEngine.accessRejected.value &&
        !widget.sync.credentialChangeInProgress) {
      await OfflineAccess.clear();
      await AccountAccess.lock();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    SyncEngine.accessRejected.removeListener(rejected);
    super.dispose();
  }

  Future<void> load() async {
    if (checking ||
        AccountAccess.authenticating ||
        widget.sync.credentialChangeInProgress) {
      return;
    }
    checking = true;
    await AccountAccess.restore(widget.store, widget.sync);
    checking = false;
    if (mounted && AccountAccess.unlocked.value == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    if (mounted) setState(() => loaded = true);
  }

  @override
  Widget build(BuildContext c) => !loaded
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : ValueListenableBuilder<String?>(
          valueListenable: AccountAccess.unlocked,
          builder: (c, owner, _) => owner == null
              ? SignInPage(store: widget.store, sync: widget.sync)
              : widget.child,
        );
}

/// Fall back only for connectivity/service availability, never rejected credentials.
Future<(Map<String, dynamic>, bool)> automaticSignIn({
  required Future<bool> Function() online,
  required Future<Map<String, dynamic>> Function() remote,
  required Future<Map<String, dynamic>> Function() local,
}) async {
  if (!await online()) return (await local(), true);
  try {
    return (await remote(), false);
  } on SyncRequestError catch (e) {
    if (e.statusCode < 500) rethrow;
  } on SocketException {
    // No network route.
  } on TimeoutException {
    // Server unreachable.
  } on http.ClientException {
    // Transport failed.
  } on SyncTransportError {
    // Service unavailable.
  }
  return (await local(), true);
}

class SignInPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const SignInPage({super.key, required this.store, required this.sync});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final username = TextEditingController(), password = TextEditingController();
  bool busy = true, offline = false, visible = false, fingerprint = false;
  String? error;
  Map<String, dynamic>? saved;
  OfflineAccess get access => OfflineAccess(widget.store, widget.sync);
  @override
  void initState() {
    super.initState();
    AccountAccess.authenticating = true;
    initialise();
  }

  @override
  void dispose() {
    AccountAccess.authenticating = false;
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> initialise() async {
    try {
      fingerprint = await OfflineAccess.biometricEnabled();
      saved = await OfflineAccess.info();
      username.text =
          saved?['username'] ??
          await widget.store.setting('accountUsername') ??
          '';
      offline = !await widget.sync.onlineAvailable();
    } catch (_) {
      /* An unavailable verifier must not prevent online login. */
    }
    if (mounted) setState(() => busy = false);
  }

  String friendly(Object e) => e is PlatformException
      ? e.message ?? 'Account access could not be verified.'
      : e.toString().replaceFirst('Bad state: ', '');
  Future<void> signIn() async {
    if (busy) return;
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = 'Enter your username and password.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final (result, useOffline) = await automaticSignIn(
        online: widget.sync.onlineAvailable,
        remote: () => widget.sync.nativeLogin(username.text, password.text),
        local: () => access.verify(username.text, password.text),
      );
      final owner = 'farmerplus:${result['studentId']}';
      if (!useOffline &&
          await widget.store.setting('boundOwner') != null &&
          await widget.store.setting('boundOwner') != result['owner'] &&
          AccountWorkspaces.adopt != null) {
        await AccountWorkspaces.adopt!(result, password.text);
        return;
      }
      await AccountAccess.verifyOwner(
        widget.store,
        owner,
        syncOwner: result['owner'],
        verifiedPermanent: true,
      );
      if (!useOffline) {
        await widget.sync.acceptOidc(result);
        await widget.store.setSetting('accessOwner', owner);
        try {
          if (!await access.matches(result)) {
            await access.enroll(password.text, result);
          }
        } on PlatformException {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Signed in. Offline login could not be prepared; retry in Account.',
                ),
              ),
            );
          }
        }
        await OnlineSignInLocation.captureAndSync(widget.store, widget.sync);
      }
      password.clear();
      await AccountAccess.unlock(
        widget.store,
        owner,
        result['username'],
        'oidc',
        offline: useOffline || await access.matches(result),
      );
      await widget.store.setSetting('learningNotice', null);
      AccountAccess.authenticating = false;
      if (!useOffline && await widget.store.setting('lastSync') == null) {
        // One initial restoration after an online sign-in; empty queues are
        // otherwise idle until the farmer explicitly requests a server refresh.
        await widget.store.setSetting('consent', true);
        unawaited(widget.sync.sync());
      }
      if (!useOffline) unawaited(widget.sync.onlineLoginReports());
    } catch (e) {
      password.clear();
      if (mounted) setState(() => error = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> unlockFingerprint() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final proof = await access.unlockBiometric();
      await AccountAccess.unlock(
        widget.store,
        'farmerplus:${proof['studentId']}',
        proof['username'],
        'oidc',
        offline: true,
      );
      AccountAccess.authenticating = false;
    } catch (e) {
      if (mounted) setState(() => error = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> createAccount() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            RegisterFarmerPage(store: widget.store, sync: widget.sync),
      ),
    );
    if (result == null || !mounted) return;
    await AccountAccess.unlock(
      widget.store,
      'farmerplus:${result['studentId']}',
      result['username'],
      'oidc',
      offline: result['offlineReady'] == true,
    );
    unawaited(widget.sync.onlineLoginReports());
    AccountAccess.authenticating = false;
  }

  @override
  Widget build(BuildContext c) => FarmBackdrop(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Image.asset(
                  'assets/branding/wordmark.png',
                  height: 42,
                  semanticLabel: 'FarmerPlus',
                ),
                gap(24),
                FrostPanel(
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Farmer sign in',
                          style: Theme.of(c).textTheme.headlineMedium,
                        ),
                        gap(20),
                        TextField(
                          controller: username,
                          enabled: !busy,
                          autofillHints: const [AutofillHints.username],
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                          ),
                        ),
                        gap(16),
                        TextField(
                          controller: password,
                          enabled: !busy,
                          obscureText: !visible,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => signIn(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            suffixIcon: IconButton(
                              tooltip: visible
                                  ? 'Hide password'
                                  : 'Show password',
                              onPressed: () =>
                                  setState(() => visible = !visible),
                              icon: Icon(
                                visible
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                            ),
                          ),
                        ),
                        gap(20),
                        FilledButton(
                          onPressed: busy ? null : signIn,
                          child: Text(busy ? 'Signing in…' : 'Sign in'),
                        ),
                        if (!busy)
                          TextButton(
                            onPressed: createAccount,
                            child: const Text('Create account'),
                          ),
                        if (fingerprint)
                          OutlinedButton.icon(
                            onPressed: busy ? null : unlockFingerprint,
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Unlock with fingerprint'),
                          ),
                        if (offline)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              'Offline · use the password last verified on this phone.',
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(error!),
                            ),
                          ),
                        if (!busy)
                          TextButton(
                            onPressed: () =>
                                openPage(c, RecoveryPage(sync: widget.sync)),
                            child: const Text('Use a recovery code'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> configureOfflineLogin(
  BuildContext context,
  FarmStore store,
  SyncEngine sync,
) async {
  final password = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Enable offline login'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Online confirmation is required. Only an encrypted password verifier is stored on this Android device.',
          ),
          gap(16),
          TextField(
            controller: password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Account password'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, password.text),
          child: const Text('Verify online'),
        ),
      ],
    ),
  );
  password.clear();
  password.dispose();
  if (value == null || !context.mounted) return;
  await guarded(context, () async {
    await OfflineAccess(store, sync).prepare(value);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Encrypted offline login is ready on this device.'),
        ),
      );
    }
  });
}

class ChangePasswordPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const ChangePasswordPage({
    super.key,
    required this.store,
    required this.sync,
  });
  @override
  State<ChangePasswordPage> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<ChangePasswordPage> {
  final current = TextEditingController(),
      next = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final issue = passwordIssue(next.text);
    if (issue != null || next.text != confirm.text) {
      setState(() => error = issue ?? 'The new passwords do not match.');
      return;
    }
    if (!await widget.sync.onlineAvailable()) {
      if (mounted) {
        setState(
          () => error = 'Password changes require an internet connection.',
        );
      }
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await OfflineAccess(
        widget.store,
        widget.sync,
      ).changePassword(current.text, next.text);
      current.clear();
      next.clear();
      confirm.clear();
      await AccountAccess.lock();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Change password',
    children: [
      note(
        'Online only. After the server accepts the change, this phone replaces its encrypted offline verifier and asks you to sign in again.',
      ),
      for (final field in [
        (current, 'Current password'),
        (next, 'New password'),
        (confirm, 'Confirm new password'),
      ]) ...[
        gap(12),
        TextField(
          controller: field.$1,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          decoration: InputDecoration(labelText: field.$2),
        ),
      ],
      gap(16),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? 'Changing password…' : 'Change password'),
      ),
      if (error != null) Semantics(liveRegion: true, child: note(error!)),
    ],
  );
}

class AccountConnectionPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const AccountConnectionPage({
    super.key,
    required this.store,
    required this.sync,
  });
  @override
  State<AccountConnectionPage> createState() => _AccountConnectionPageState();
}

class _AccountConnectionPageState extends State<AccountConnectionPage> {
  final server = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.sync.base().then((value) {
      if (mounted) setState(() => server.text = value);
    });
  }

  @override
  void dispose() {
    server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Account connection',
    children: [
      note(
        'Use the account-service address supplied for this test installation. Remote services require HTTPS. Your phone remains bound to its original account and server.',
      ),
      TextField(
        controller: server,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'Account service URL'),
      ),
      gap(),
      FilledButton(
        onPressed: () => guarded(c, () async {
          final value = server.text.trim().replaceFirst(RegExp(r'/$'), '');
          final uri = Uri.tryParse(value);
          if (uri == null ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              (uri.scheme != 'https' &&
                  !(uri.scheme == 'http' &&
                      {
                        '127.0.0.1',
                        'localhost',
                        '10.0.2.2',
                      }.contains(uri.host)))) {
            throw StateError(
              'Enter an HTTPS service address without credentials or query parameters.',
            );
          }
          final bound = await widget.store.setting('boundServer');
          if (bound != null && bound != value) {
            throw StateError(
              'Existing records belong to the original server. Sign in there to recover them.',
            );
          }
          await widget.store.setSetting('server', value);
          if (c.mounted) Navigator.pop(c);
        }),
        child: const Text('Save connection'),
      ),
    ],
  );
}
