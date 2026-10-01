import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'auth.dart';
import 'sync.dart';
import 'ui.dart';

Future<void> showRecoveryCodes(BuildContext context, List<String> codes) async {
  const channel = MethodChannel('farmerplus/privacy');
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await channel.invokeMethod('secureScreen', true);
  }
  try {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        bool stored = false;
        return StatefulBuilder(
          builder: (c, update) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Keep your recovery codes safe'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Write these codes down and keep them somewhere separate from this phone. Anyone with a code and your username can reset your password. They will not be shown again.',
                    ),
                    gap(),
                    for (final code in codes)
                      SelectableText(
                        code,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                      ),
                    gap(),
                    const Text(
                      'Using a code resets your password, signs out server sessions and replaces all old codes. Email and SMS are not required.',
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: stored,
                      onChanged: (v) => update(() => stored = v!),
                      title: const Text('I stored these codes separately'),
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: stored ? () => Navigator.pop(c) : null,
                  child: const Text('Codes stored · continue'),
                ),
              ],
            ),
          ),
        );
      },
    );
  } finally {
    codes.clear(); // No files, preferences, logs or clipboard are written.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await channel.invokeMethod('secureScreen', false);
    }
  }
}

class RecoveryPage extends StatefulWidget {
  final SyncEngine sync;
  const RecoveryPage({super.key, required this.sync});
  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  final username = TextEditingController(),
      code = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false, show = false, showConfirm = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    code.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> reset() async {
    final issue = passwordIssue(password.text);
    if (issue != null) {
      setState(() => error = issue);
      return;
    }
    if (password.text != confirm.text) {
      setState(() => error = 'Passwords do not match.');
      return;
    }
    if (username.text.trim().isEmpty || code.text.trim().isEmpty) {
      setState(
        () => error = 'Enter your username and an unused recovery code.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final body = {
      'username': username.text.trim(),
      'code': code.text.trim(),
      'password': password.text,
    };
    code.clear();
    password.clear();
    confirm.clear();
    try {
      final result = await widget.sync.request(
        'POST',
        '/auth/recover',
        body: body,
      );
      if (!mounted) return;
      await showRecoveryCodes(
        context,
        List<String>.from(result['recoveryCodes']),
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Password reset. Sign in with your new password. Old server sessions and recovery codes were revoked.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Recovery could not verify these details or reach the service. Check your connection, username and an unused code. If a previous request was interrupted, try signing in with the new password first.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Recover your account',
    children: [
      note(
        'Use an unused recovery code stored separately from your phone. Recovery needs internet. No email or SMS is required. Existing Learning accounts need their approved Learning recovery process until the shared integration is enabled.',
      ),
      TextField(
        controller: username,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Username'),
      ),
      gap(),
      TextField(
        controller: code,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'Unused recovery code'),
      ),
      gap(),
      TextField(
        controller: password,
        obscureText: !show,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'New password',
          suffixIcon: IconButton(
            tooltip: show ? 'Hide new password' : 'Show new password',
            onPressed: () => setState(() => show = !show),
            icon: Icon(show ? Icons.visibility_off : Icons.visibility),
          ),
        ),
      ),
      gap(),
      TextField(
        controller: confirm,
        obscureText: !showConfirm,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'Confirm new password',
          suffixIcon: IconButton(
            tooltip: showConfirm
                ? 'Hide new confirmation'
                : 'Show new confirmation',
            onPressed: () => setState(() => showConfirm = !showConfirm),
            icon: Icon(showConfirm ? Icons.visibility_off : Icons.visibility),
          ),
        ),
      ),
      gap(),
      if (error != null) note(error!),
      FilledButton(
        onPressed: busy ? null : reset,
        child: Text(busy ? 'Verifying…' : 'Reset password with code'),
      ),
      note(
        'If the phone and every recovery code are lost, automatic recovery is unavailable. An assisted recovery policy has not been configured.',
      ),
    ],
  );
}

class RecoveryReissuePage extends StatefulWidget {
  final SyncEngine sync;
  const RecoveryReissuePage({super.key, required this.sync});
  @override
  State<RecoveryReissuePage> createState() => _RecoveryReissuePageState();
}

class _RecoveryReissuePageState extends State<RecoveryReissuePage> {
  final password = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Replace recovery codes',
    children: [
      note(
        'Re-enter your password to replace every old recovery code. Store the new set separately from your phone. This requires a connection.',
      ),
      TextField(
        controller: password,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Current password'),
      ),
      gap(),
      FilledButton(
        onPressed: busy
            ? null
            : () => guarded(c, () async {
                setState(() => busy = true);
                final secret = password.text;
                password.clear();
                try {
                  final result = await widget.sync.request(
                    'POST',
                    '/auth/recovery/reissue',
                    body: {'current_password': secret},
                  );
                  if (!c.mounted) return;
                  await showRecoveryCodes(
                    c,
                    List<String>.from(result['recoveryCodes']),
                  );
                  if (c.mounted) Navigator.pop(c);
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              }),
        child: const Text('Verify & replace codes'),
      ),
    ],
  );
}
