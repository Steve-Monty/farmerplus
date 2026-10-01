import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'appearance.dart';
import 'auth.dart' show AccountAccess, passwordIssue;
import 'pwa_password.dart';
import 'store.dart';
import 'sync.dart';
import 'sign_in_location.dart';
import 'ui.dart';
import 'session_activity.dart';
import 'browser_bridge.dart' if (dart.library.html) 'browser_bridge_web.dart';

class PwaWorkspace {
  static Future<bool> Function(Map<String, dynamic> proof, String? password)?
  switcher;
}

class _AuthLoading extends StatelessWidget {
  const _AuthLoading();

  @override
  Widget build(BuildContext context) => FarmBackdrop(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/branding/wordmark.png',
                    semanticLabel: 'FarmerPlus',
                  ),
                  gap(24),
                  const FrostPanel(
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Opening FarmerPlus…'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class PwaAuthGate extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Widget child;
  const PwaAuthGate({
    super.key,
    required this.store,
    required this.sync,
    required this.child,
  });

  @override
  State<PwaAuthGate> createState() => _PwaAuthGateState();
}

class _PwaAuthGateState extends State<PwaAuthGate> {
  bool checking = true;
  String? restoreMessage;

  @override
  void initState() {
    super.initState();
    SyncEngine.accessRejected.addListener(rejected);
    restore();
  }

  void rejected() async {
    if (!SyncEngine.accessRejected.value ||
        widget.sync.credentialChangeInProgress) {
      return;
    }
    await invalidateOfflineEmail(widget.store);
    await AccountAccess.lock();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    SyncEngine.accessRejected.removeListener(rejected);
    super.dispose();
  }

  Future<void> restore() async {
    final path = Uri.base.path;
    final token = Uri.base.queryParameters['token'];
    if (path == '/auth/verify' && token != null) {
      await openFlow(EmailVerificationPage(sync: widget.sync, token: token));
    } else if (path == '/auth/reset' && token != null) {
      await openFlow(PasswordResetPage(sync: widget.sync, token: token));
    }
    try {
      final me = Map<String, dynamic>.from(
        await widget.sync.request('GET', '/auth/me'),
      );
      await accept(me, null);
      if (path.startsWith('/auth/')) {
        browserReplacePath('/');
      }
    } on SyncRequestError catch (e) {
      if ([401, 403].contains(e.statusCode)) {
        await invalidateOfflineEmail(widget.store);
      } else {
        restoreMessage =
            'FarmerPlus could not check the server. Use your saved offline unlock, or retry when the service is available.';
      }
    } catch (_) {
      restoreMessage =
          'FarmerPlus is offline. Use your saved offline unlock to open saved work.';
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> openFlow(Widget page) async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      browserReplacePath('/');
    });
  }

  Future<void> accept(Map<String, dynamic> result, String? password) async {
    if (await PwaWorkspace.switcher?.call(result, password) == true) return;
    final previousEpoch = await widget.store.setting('credentialEpoch');
    final nextEpoch = result['credentialEpoch'];
    if (previousEpoch is int &&
        nextEpoch is int &&
        previousEpoch != nextEpoch) {
      await invalidateOfflineEmail(widget.store);
    }
    await widget.sync.acceptBrowserSession(result);
    await widget.store.setSetting('credentialEpoch', nextEpoch);
    final owner = 'farmerplus:${result['studentId']}';
    await AccountAccess.verifyOwner(
      widget.store,
      owner,
      syncOwner: result['owner'],
      verifiedPermanent: true,
    );
    await AccountAccess.unlock(
      widget.store,
      owner,
      (result['email'] ?? result['username']).toString(),
      result['accountKind']?.toString() ?? 'email',
    );
    if (password != null && result['email'] is String) {
      await enrollOfflineEmail(widget.store, result['email'], password);
    }
    if (password != null ||
        Uri.base.path == '/auth/callback' ||
        await widget.store.setting('pendingSignInLocation') == true ||
        await widget.store.setting('lastGpsFix') == null) {
      await widget.store.setSetting('pendingSignInLocation', true);
      unawaited(OnlineSignInLocation.captureAndSync(widget.store, widget.sync));
    }
  }

  @override
  Widget build(BuildContext context) => checking
      ? const _AuthLoading()
      : ValueListenableBuilder<String?>(
          valueListenable: AccountAccess.unlocked,
          builder: (context, owner, _) => owner == null
              ? EmailSignInPage(
                  store: widget.store,
                  sync: widget.sync,
                  initialMessage: SessionActivity.expired
                      ? 'Your session paused after 30 minutes without activity. Your saved work is safe.'
                      : restoreMessage,
                  onAuthenticated: accept,
                  onOfflineAuthenticated: acceptOffline,
                )
              : widget.child,
        );

  Future<void> acceptOffline() async {
    final owner = await widget.store.setting('accessOwner');
    final account = await widget.store.setting('accountEmail');
    if (owner is! String || account is! String) {
      throw StateError('Connect once before using this account offline.');
    }
    await AccountAccess.unlock(
      widget.store,
      owner,
      account,
      (await widget.store.setting('accountKind'))?.toString() ?? 'email',
      offline: true,
    );
  }
}

class EmailSignInPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Future<void> Function(Map<String, dynamic>, String?) onAuthenticated;
  final Future<void> Function() onOfflineAuthenticated;
  final String? initialMessage;
  final void Function(String)? openSignIn;
  const EmailSignInPage({
    super.key,
    required this.store,
    required this.sync,
    required this.onAuthenticated,
    required this.onOfflineAuthenticated,
    this.initialMessage,
    this.openSignIn,
  });

  @override
  State<EmailSignInPage> createState() => _EmailSignInPageState();
}

class _EmailSignInPageState extends State<EmailSignInPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false, visible = false, providersLoading = true;
  String? error;
  Map<String, dynamic> providers = const {};
  bool deviceUnlockReady = false;
  bool openingSignIn = false;
  Timer? navigationTimer;

  @override
  void initState() {
    super.initState();
    error = widget.initialMessage;
    loadProviders();
  }

  Future<void> loadProviders() async {
    final kind = await widget.store.setting('accountKind');
    final verifier = await widget.store.setting('offlineEmailVerifier');
    deviceUnlockReady =
        verifier is Map && verifier['purpose'] == 'device-unlock';
    try {
      providers = Map<String, dynamic>.from(
        await widget.sync.request('GET', '/auth/providers'),
      );
      if (mounted &&
          providers['authority'] == 'keycloak' &&
          widget.initialMessage == null) {
        openIdentitySignIn();
      }
    } catch (_) {
      providers = kind == 'keycloak'
          ? const {'authority': 'keycloak'}
          : const {};
    }
    if (mounted) setState(() => providersLoading = false);
  }

  @override
  void dispose() {
    navigationTimer?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  void openIdentitySignIn() {
    setState(() {
      openingSignIn = true;
      error = null;
    });
    try {
      (widget.openSignIn ?? browserAssign)('/oidc/web/login');
      navigationTimer?.cancel();
      navigationTimer = Timer(const Duration(seconds: 12), () {
        if (mounted)
          setState(() {
            openingSignIn = false;
            error =
                'Sign-in is taking longer than expected. Check your connection and try again.';
          });
      });
    } catch (_) {
      setState(() {
        openingSignIn = false;
        error = 'Could not open sign-in. Check your connection and try again.';
      });
    }
  }

  Future<void> signIn() async {
    if (busy) return;
    final address = email.text.trim().toLowerCase();
    if (!_email(address) || password.text.isEmpty) {
      setState(() => error = 'Enter your email address and password.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final enteredPassword = password.text;
      final result = await widget.sync.emailLogin(address, enteredPassword);
      await widget.onAuthenticated(result, enteredPassword);
      password.clear();
      unawaited(widget.sync.sync());
    } on SyncRequestError catch (e) {
      if (mounted) setState(() => error = _message(e));
    } catch (e) {
      try {
        if (await verifyOfflineEmail(widget.store, address, password.text)) {
          password.clear();
          await widget.onOfflineAuthenticated();
          return;
        }
      } on StateError catch (offlineError) {
        if (mounted) setState(() => error = _message(offlineError));
        return;
      } catch (_) {}
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> unlockDevice() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // An available server is authoritative. Only transport/service outages
      // permit local unlock; a rejected or different online identity cannot.
      Map<String, dynamic>? me;
      try {
        me = Map<String, dynamic>.from(
          await widget.sync.request('GET', '/auth/me'),
        );
      } on SyncTransportError {
        // Saved work remains available during a connection outage.
      } on SyncRequestError catch (e) {
        if (![502, 503, 504].contains(e.statusCode)) {
          if ([401, 403].contains(e.statusCode)) {
            await invalidateOfflineEmail(widget.store);
          }
          rethrow;
        }
      }
      if (me != null) {
        if (me['owner'] != await widget.store.setting('boundOwner')) {
          throw StateError(
            'Another account is signed in. Sign in to the owner of this saved work.',
          );
        }
        await widget.onAuthenticated(me, null);
      } else {
        final account = await widget.store.setting('accountEmail');
        if (account is! String ||
            !await verifyOfflineEmail(
              widget.store,
              account,
              password.text,
              deviceUnlock: true,
            )) {
          throw StateError(
            'The device passphrase is incorrect or offline unlock needs to be set up again.',
          );
        }
        await widget.onOfflineAuthenticated();
      }
      password.clear();
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> social(String provider) async {
    final entry = providers[provider];
    final configured = entry is Map
        ? entry['configured'] == true
        : entry == true;
    final start = entry is Map ? entry['startUrl']?.toString() : null;
    if (!configured || start == null) return;
    browserAssign(start);
  }

  @override
  Widget build(BuildContext context) {
    if (providersLoading) return const _AuthLoading();
    final applePlatform =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final socialName = applePlatform ? 'apple' : 'google';
    final socialEntry = providers[socialName];
    final socialConfigured = socialEntry is Map
        ? socialEntry['configured'] == true
        : socialEntry == true;
    if (providers['authority'] == 'keycloak') {
      return FarmBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(24),
                  children: [
                    Image.asset('assets/branding/wordmark.png', height: 44),
                    gap(24),
                    FrostPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            openingSignIn
                                ? 'Opening sign-in…'
                                : 'Sign in to FarmerPlus',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          gap(12),
                          if (openingSignIn) const LinearProgressIndicator(),
                          if (!openingSignIn) ...[
                            FilledButton(
                              onPressed: openIdentitySignIn,
                              child: const Text('Retry sign-in'),
                            ),
                          ],
                          if (deviceUnlockReady) ...[
                            gap(20),
                            TextField(
                              controller: password,
                              obscureText: true,
                              enableSuggestions: false,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Device passphrase',
                              ),
                              onSubmitted: (_) => unlockDevice(),
                            ),
                            OutlinedButton.icon(
                              onPressed: busy ? null : unlockDevice,
                              icon: const Icon(Icons.lock_open_outlined),
                              label: const Text('Open saved work offline'),
                            ),
                          ],
                          if (error != null) ...[gap(12), Text(error!)],
                        ],
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
    return FarmBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(24),
                children: [
                  Image.asset('assets/branding/wordmark.png', height: 44),
                  gap(24),
                  FrostPanel(
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Farmer sign in',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          gap(18),
                          TextField(
                            controller: email,
                            enabled: !busy,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Email address',
                            ),
                          ),
                          gap(14),
                          TextField(
                            controller: password,
                            enabled: !busy,
                            obscureText: !visible,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => signIn(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
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
                          if (error != null) ...[
                            gap(12),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                          gap(18),
                          FilledButton(
                            onPressed: busy ? null : signIn,
                            child: Text(busy ? 'Signing in…' : 'Sign in'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => openPage(
                                    context,
                                    ForgotPasswordPage(
                                      sync: widget.sync,
                                      initialEmail: email.text,
                                    ),
                                  ),
                            child: const Text('Forgot password?'),
                          ),
                          const Divider(height: 28),
                          OutlinedButton.icon(
                            onPressed: !providersLoading && socialConfigured
                                ? () => social(socialName)
                                : null,
                            icon: Icon(
                              applePlatform
                                  ? Icons.apple
                                  : Icons.account_circle_outlined,
                            ),
                            label: Text(
                              applePlatform
                                  ? 'Continue with Apple'
                                  : 'Continue with Google',
                            ),
                          ),
                          gap(12),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => openPage(
                                    context,
                                    EmailRegistrationPage(sync: widget.sync),
                                  ),
                            child: const Text('Register as a farmer'),
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
}

class EmailRegistrationPage extends StatefulWidget {
  final SyncEngine sync;
  const EmailRegistrationPage({super.key, required this.sync});
  @override
  State<EmailRegistrationPage> createState() => _EmailRegistrationPageState();
}

class _EmailRegistrationPageState extends State<EmailRegistrationPage> {
  final email = TextEditingController(),
      first = TextEditingController(),
      last = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false,
      sent = false,
      passwordVisible = false,
      confirmVisible = false;
  String? error;
  @override
  void dispose() {
    for (final c in [email, first, last, password, confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    final address = email.text.trim().toLowerCase();
    final issue = passwordIssue(password.text);
    if (!_email(address) ||
        first.text.trim().isEmpty ||
        last.text.trim().isEmpty ||
        issue != null ||
        password.text != confirm.text) {
      setState(
        () => error = !_email(address)
            ? 'Enter a valid email address.'
            : first.text.trim().isEmpty || last.text.trim().isEmpty
            ? 'Enter your first and last name.'
            : issue ?? 'Passwords do not match.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.sync.request(
        'POST',
        '/auth/email/register',
        body: {
          'email': address,
          'password': password.text,
          'firstname': first.text.trim(),
          'lastname': last.text.trim(),
        },
      );
      password.clear();
      confirm.clear();
      if (mounted) setState(() => sent = true);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Register as a farmer',
    children: [
      TextField(
        controller: email,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Email address'),
      ),
      gap(),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: first,
              decoration: const InputDecoration(labelText: 'First name'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: last,
              decoration: const InputDecoration(labelText: 'Last name'),
            ),
          ),
        ],
      ),
      gap(),
      TextField(
        controller: password,
        obscureText: !passwordVisible,
        decoration: InputDecoration(
          labelText: 'Password',
          helperText:
              'At least 8 characters with uppercase and lowercase letters.',
          suffixIcon: IconButton(
            tooltip: passwordVisible ? 'Hide password' : 'Show password',
            onPressed: () => setState(() => passwordVisible = !passwordVisible),
            icon: Icon(
              passwordVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ),
      gap(),
      TextField(
        controller: confirm,
        obscureText: !confirmVisible,
        decoration: InputDecoration(
          labelText: 'Confirm password',
          suffixIcon: IconButton(
            tooltip: confirmVisible
                ? 'Hide confirmed password'
                : 'Show confirmed password',
            onPressed: () => setState(() => confirmVisible = !confirmVisible),
            icon: Icon(
              confirmVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ),
      if (error != null) ...[
        gap(),
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      gap(),
      FilledButton(
        onPressed: busy || sent ? null : submit,
        child: Text(
          busy
              ? 'Creating…'
              : sent
              ? 'Verification requested'
              : 'Create account',
        ),
      ),
      if (sent)
        note(
          'Check your email for the verification link, then return here to sign in.',
        ),
    ],
  );
}

class ForgotPasswordPage extends StatefulWidget {
  final SyncEngine sync;
  final String initialEmail;
  const ForgotPasswordPage({
    super.key,
    required this.sync,
    this.initialEmail = '',
  });
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final email = TextEditingController(text: widget.initialEmail);
  bool busy = false, sent = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final address = email.text.trim().toLowerCase();
    if (!_email(address)) {
      setState(() => error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.sync.request(
        'POST',
        '/auth/email/password/forgot',
        body: {'email': address},
      );
      if (mounted) setState(() => sent = true);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Reset password',
    children: [
      const Text(
        'Enter your account email. The testing server will route the message according to its visible email-mode configuration.',
      ),
      gap(),
      TextField(
        controller: email,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Email address'),
      ),
      if (error != null) ...[gap(), Text(error!)],
      gap(),
      FilledButton(
        onPressed: busy || sent ? null : submit,
        child: Text(sent ? 'Reset requested' : 'Send reset link'),
      ),
    ],
  );
}

class EmailVerificationPage extends StatefulWidget {
  final SyncEngine sync;
  final String token;
  const EmailVerificationPage({
    super.key,
    required this.sync,
    required this.token,
  });
  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  String status = 'Verifying email…';
  @override
  void initState() {
    super.initState();
    verify();
  }

  Future<void> verify() async {
    try {
      await widget.sync.request(
        'POST',
        '/auth/email/verification/confirm',
        body: {'token': widget.token},
      );
      status = 'Email verified. You can sign in now.';
    } catch (e) {
      status = _message(e);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Verify email',
    children: [
      Text(status),
      gap(),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Continue'),
      ),
    ],
  );
}

class PasswordResetPage extends StatefulWidget {
  final SyncEngine sync;
  final String token;
  const PasswordResetPage({super.key, required this.sync, required this.token});
  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

class _PasswordResetPageState extends State<PasswordResetPage> {
  final password = TextEditingController(), confirm = TextEditingController();
  bool busy = false, done = false;
  String? error;
  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final issue = passwordIssue(password.text);
    if (issue != null || password.text != confirm.text) {
      setState(() => error = issue ?? 'Passwords do not match.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.sync.request(
        'POST',
        '/auth/email/password/reset',
        body: {'token': widget.token, 'password': password.text},
      );
      password.clear();
      confirm.clear();
      done = true;
    } catch (e) {
      error = _message(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Choose a new password',
    children: [
      TextField(
        controller: password,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'New password'),
      ),
      gap(),
      TextField(
        controller: confirm,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Confirm password'),
      ),
      if (error != null) ...[gap(), Text(error!)],
      gap(),
      FilledButton(
        onPressed: busy || done ? null : submit,
        child: Text(done ? 'Password changed' : 'Change password'),
      ),
      if (done)
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Return to sign in'),
        ),
    ],
  );
}

bool _email(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
String _message(Object error) =>
    error.toString().replaceFirst('Bad state: ', '');

Future<void> enrollOfflineEmail(
  FarmStore store,
  String email,
  String password, {
  bool deviceUnlock = false,
}) async {
  final server = await store.setting('boundServer');
  final owner = await store.setting('boundOwner');
  final epoch = await store.setting('credentialEpoch');
  if (server is! String ||
      server.isEmpty ||
      owner is! String ||
      owner.isEmpty ||
      epoch is! int ||
      epoch < 0) {
    throw StateError(
      'The server did not provide a valid offline account binding.',
    );
  }
  final normalizedEmail = email.trim().toLowerCase();
  final random = Random.secure();
  final salt = List<int>.generate(24, (_) => random.nextInt(256));
  const rounds = 600000;
  final verifier = await deriveOfflinePassword(
    _offlineMaterial(
      deviceUnlock ? 'device-unlock\u0000$password' : password,
      server,
      owner,
      normalizedEmail,
      epoch,
    ),
    salt,
    rounds,
  );
  await store.setSetting('offlineEmailVerifier', {
    if (deviceUnlock) 'purpose': 'device-unlock',
    'email': normalizedEmail,
    'server': server,
    'owner': owner,
    'credentialEpoch': epoch,
    'salt': base64UrlEncode(salt),
    'rounds': rounds,
    'verifier': base64UrlEncode(verifier),
    'failures': 0,
    'lockedUntil': null,
  });
}

Future<bool> verifyOfflineEmail(
  FarmStore store,
  String email,
  String password, {
  bool deviceUnlock = false,
}) async {
  final value = await store.setting('offlineEmailVerifier');
  if (value is! Map) return false;
  if ((value['purpose'] == 'device-unlock') != deviceUnlock) return false;
  final server = await store.setting('boundServer');
  final owner = await store.setting('boundOwner');
  final epoch = await store.setting('credentialEpoch');
  final normalizedEmail = email.trim().toLowerCase();
  if (value['email'] != normalizedEmail) return false;
  if (value['server'] != server ||
      value['owner'] != owner ||
      value['credentialEpoch'] != epoch) {
    await invalidateOfflineEmail(store);
    return false;
  }
  final lockedUntil = DateTime.tryParse(value['lockedUntil']?.toString() ?? '');
  if (lockedUntil != null && DateTime.now().toUtc().isBefore(lockedUntil)) {
    throw StateError('Too many offline sign-in attempts. Try again later.');
  }
  try {
    final rounds = value['rounds'];
    if (rounds is! int || rounds != 600000) {
      await invalidateOfflineEmail(store);
      return false;
    }
    final salt = base64Url.decode(value['salt'] as String);
    final expected = base64Url.decode(value['verifier'] as String);
    if (salt.length != 24 || expected.length != 32) {
      await invalidateOfflineEmail(store);
      return false;
    }
    final actual = await deriveOfflinePassword(
      _offlineMaterial(
        deviceUnlock ? 'device-unlock\u0000$password' : password,
        server,
        owner,
        normalizedEmail,
        epoch,
      ),
      salt,
      rounds,
    );
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < actual.length && i < expected.length; i++) {
      difference |= actual[i] ^ expected[i];
    }
    if (difference == 0) {
      if (value['failures'] != 0 || value['lockedUntil'] != null) {
        await store.setSetting('offlineEmailVerifier', {
          ...value,
          'failures': 0,
          'lockedUntil': null,
        });
      }
      return true;
    }
    final failures = ((value['failures'] as int?) ?? 0) + 1;
    final lockSeconds = failures < 5
        ? 0
        : (30 * (1 << (failures - 5).clamp(0, 5))).clamp(30, 900);
    await store.setSetting('offlineEmailVerifier', {
      ...value,
      'failures': failures,
      'lockedUntil': lockSeconds == 0
          ? null
          : DateTime.now()
                .toUtc()
                .add(Duration(seconds: lockSeconds))
                .toIso8601String(),
    });
    return false;
  } on FormatException {
    await invalidateOfflineEmail(store);
    return false;
  } on TypeError {
    await invalidateOfflineEmail(store);
    return false;
  }
}

Future<void> invalidateOfflineEmail(FarmStore store) =>
    store.setSetting('offlineEmailVerifier', null);

String _offlineMaterial(
  String password,
  Object? server,
  Object? owner,
  String email,
  Object? epoch,
) => '$password\u0000$server\u0000$owner\u0000$email\u0000$epoch';

/// Device-only enrollment always requires fresh proof from the server.
Future<void> enrollDeviceUnlock(
  FarmStore store,
  SyncEngine sync,
  String passphrase,
) async {
  if (passphrase.length < 12) {
    throw StateError('Use at least 12 characters for your device passphrase.');
  }
  final me = Map<String, dynamic>.from(await sync.request('GET', '/auth/me'));
  final owner = await store.setting('boundOwner');
  if (me['verified'] != true ||
      me['accountKind'] != 'keycloak' ||
      me['owner'] != owner ||
      me['studentId'] != await store.setting('studentId') ||
      me['credentialEpoch'] is! int ||
      me['email'] is! String ||
      await sync.base() != await store.setting('boundServer') ||
      AccountAccess.unlocked.value != 'farmerplus:${me['studentId']}') {
    throw StateError(
      'Sign in to this account online before setting up offline unlock.',
    );
  }
  await store.setSetting('credentialEpoch', me['credentialEpoch']);
  await enrollOfflineEmail(store, me['email'], passphrase, deviceUnlock: true);
}

class KeycloakAccountSecurity extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const KeycloakAccountSecurity({
    super.key,
    required this.store,
    required this.sync,
  });
  @override
  State<KeycloakAccountSecurity> createState() =>
      _KeycloakAccountSecurityState();
}

class _KeycloakAccountSecurityState extends State<KeycloakAccountSecurity> {
  final passphrase = TextEditingController(), confirm = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    passphrase.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> enroll() async {
    if (busy) return;
    if (passphrase.text != confirm.text) {
      setState(() => message = 'The device passphrases do not match.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await enrollDeviceUnlock(widget.store, widget.sync, passphrase.text);
      passphrase.clear();
      confirm.clear();
      if (mounted) {
        setState(() => message = 'Offline unlock is ready in this browser.');
      }
    } catch (e) {
      if (mounted) setState(() => message = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Account & security',
    children: [
      const Text(
        'Your FarmerPlus account manages your profile, password, recovery and connected sign-in providers.',
      ),
      OutlinedButton.icon(
        onPressed: busy
            ? null
            : () => guarded(context, () async {
                final config = await widget.sync.oidcConfiguration();
                final issuer = Uri.parse(config['issuer'].toString());
                if (issuer.scheme != 'https') {
                  throw StateError(
                    'Secure account settings are not configured yet.',
                  );
                }
                browserAssign(
                  '${issuer.toString().replaceFirst(RegExp(r'/+$'), '')}/account/',
                );
              }),
        icon: const Icon(Icons.manage_accounts_outlined),
        label: const Text('Manage FarmerPlus account · online'),
      ),
      gap(),
      Text(
        'Unlock saved work on this device',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const Text(
        'Choose a separate passphrase of at least 12 characters. It stays in this browser and is never sent to Keycloak. Use it when the service is unavailable. Sign in online first to set it up.',
      ),
      gap(),
      TextField(
        controller: passphrase,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'New device passphrase'),
      ),
      gap(),
      TextField(
        controller: confirm,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Confirm device passphrase',
        ),
      ),
      FilledButton.icon(
        onPressed: busy ? null : enroll,
        icon: const Icon(Icons.lock_outline),
        label: Text(busy ? 'Saving…' : 'Set up offline unlock'),
      ),
      TextButton(
        onPressed: busy
            ? null
            : () => guarded(context, () async {
                await invalidateOfflineEmail(widget.store);
                if (mounted) {
                  setState(
                    () => message =
                        'Offline unlock removed. Saved work has been kept.',
                  );
                }
              }),
        child: const Text('Remove offline unlock'),
      ),
      const Text(
        'This locks access through the app; it does not encrypt browser storage. Account changes made elsewhere take effect when this device reconnects. Clearing browser data removes this setup.',
      ),
      if (message != null) ...[gap(), Text(message!)],
    ],
  );
}
