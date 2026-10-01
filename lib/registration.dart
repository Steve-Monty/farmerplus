import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'auth.dart';
import 'offline_access.dart';
import 'recovery.dart';
import 'store.dart';
import 'sync.dart';
import 'ui.dart';
import 'account_workspaces.dart';
import 'sign_in_location.dart';

class RegisterFarmerPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const RegisterFarmerPage({
    super.key,
    required this.store,
    required this.sync,
  });
  @override
  State<RegisterFarmerPage> createState() => _RegisterFarmerState();
}

class _RegisterFarmerState extends State<RegisterFarmerPage> {
  final username = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false, visible = false, created = false;
  String? error, createdUsername;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> register() async {
    if (busy) return;
    final name = username.text.trim();
    final issue = passwordIssue(password.text);
    if (!RegExp(r'^[A-Za-z0-9_@.+-]{3,64}$').hasMatch(name) ||
        issue != null ||
        password.text != confirm.text) {
      setState(
        () => error = !RegExp(r'^[A-Za-z0-9_@.+-]{3,64}$').hasMatch(name)
            ? 'Use a username of 3–64 letters, numbers, or _ @ . + -.'
            : issue ?? 'Passwords do not match.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await widget.sync.onlineAvailable()) {
        throw StateError(
          'Connect to create your account. Afterwards you can work offline.',
        );
      }
      if (!created) {
        final response = await widget.sync.request(
          'POST',
          '/auth/register',
          body: {'username': name, 'password': password.text},
        );
        created = true;
        createdUsername = name;
        if (!mounted) return;
        await showRecoveryCodes(
          context,
          List<String>.from(response['recoveryCodes']),
        );
      }
      final proof = await widget.sync.nativeLogin(
        createdUsername!,
        password.text,
      );
      if (await widget.store.setting('boundOwner') != null &&
          await widget.store.setting('boundOwner') != proof['owner'] &&
          AccountWorkspaces.adopt != null) {
        await AccountWorkspaces.adopt!(proof, password.text);
        return;
      }
      final owner = 'farmerplus:${proof['studentId']}';
      await AccountAccess.verifyOwner(
        widget.store,
        owner,
        syncOwner: proof['owner'],
        verifiedPermanent: true,
      );
      await widget.sync.acceptOidc(proof);
      await widget.store.setSetting('accessOwner', owner);
      var offlineReady = false;
      try {
        await OfflineAccess(
          widget.store,
          widget.sync,
        ).enroll(password.text, proof);
        offlineReady = true;
      } on PlatformException {
        /* The verified online session remains usable. */
      }
      await OnlineSignInLocation.captureAndSync(widget.store, widget.sync);
      password.clear();
      confirm.clear();
      if (mounted) {
        Navigator.pop(context, {...proof, 'offlineReady': offlineReady});
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = created
              ? 'Your account was created. Retry signing in below, or return to Sign in. Your recovery codes remain valid.'
              : e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Create farmer account',
    children: [
      note(
        'One account for FarmerPlus and Learning. No email or SMS is required.',
      ),
      AutofillGroup(
        child: Column(
          children: [
            TextField(
              controller: username,
              enabled: !busy && !created,
              autocorrect: false,
              autofillHints: const [AutofillHints.newUsername],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            gap(16),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: !visible,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText:
                    'At least 8 characters, with uppercase and lowercase letters.',
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  tooltip: visible ? 'Hide password' : 'Show password',
                  onPressed: () => setState(() => visible = !visible),
                  icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
            gap(16),
            TextField(
              controller: confirm,
              enabled: !busy,
              obscureText: !visible,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => register(),
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
          ],
        ),
      ),
      gap(20),
      if (error != null) Semantics(liveRegion: true, child: Text(error!)),
      FilledButton(
        onPressed: busy ? null : register,
        child: Text(
          busy
              ? 'Please wait…'
              : created
              ? 'Sign in to my new account'
              : 'Create account',
        ),
      ),
      note(
        'Your recovery codes appear next. Keep them somewhere separate from this phone.',
      ),
    ],
  );
}
