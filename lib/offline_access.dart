import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'store.dart';
import 'sync.dart';

class OfflineAccess {
  static const channel = MethodChannel('farmerplus/offline-access');
  final FarmStore store;
  final SyncEngine sync;
  OfflineAccess(this.store, this.sync);
  static Future<Map<String, dynamic>?> info() async {
    if (kIsWeb) return null;
    try {
      final value = await channel.invokeMapMethod<String, dynamic>('info');
      return value == null ? null : Map<String, dynamic>.from(value);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> clear({int? epoch}) async {
    if (kIsWeb) return;
    try {
      await channel.invokeMethod<void>('clear', {
        if (epoch != null) 'credentialEpoch': epoch,
      });
    } on MissingPluginException {
      /* No vault on this platform. */
    }
  }

  Future<void> checkBinding(Map<String, dynamic> value) async {
    if (value['owner'] != await store.setting('boundOwner') ||
        value['studentId'] != await store.setting('studentId') ||
        'farmerplus:${value['studentId']}' !=
            await store.setting('accessOwner') ||
        value['server'] != await sync.base()) {
      throw StateError(
        'Offline login does not match this device’s account. Your records are unchanged.',
      );
    }
  }

  Future<bool> matches(Map<String, dynamic> me) async {
    final revision = sync.credentialRevision;
    Map<String, dynamic>? value;
    try {
      value = await info();
    } on PlatformException {
      // Called only with a verified online account response. Rebuild a corrupt
      // verifier after online proof without blocking access to intact farm data.
      if (revision == sync.credentialRevision &&
          !sync.credentialChangeInProgress) {
        await clear();
      }
      return false;
    }
    if (value == null) return false;
    await checkBinding(value);
    if (revision != sync.credentialRevision ||
        sync.credentialChangeInProgress) {
      return false;
    }
    if (me['credentialEpoch'] != value['credentialEpoch'] ||
        me['owner'] != value['owner']) {
      await clear(epoch: value['credentialEpoch']);
      return false;
    }
    return true;
  }

  Future<void> enroll(String password, Map<String, dynamic> proof) async {
    if (proof['verified'] != true || proof['credentialEpoch'] is! int) {
      throw StateError(
        'The server has not enabled offline password verification yet.',
      );
    }
    final value = {...proof, 'server': await sync.base()};
    await checkBinding(value);
    await channel.invokeMethod<void>('enroll', {
      ...value,
      'password': password,
    });
  }

  Future<void> prepare(String password) async {
    final revision = sync.credentialRevision;
    if (!await sync.onlineAvailable()) {
      throw StateError(
        'Connect to verify your password and enable offline login.',
      );
    }
    final proof = Map<String, dynamic>.from(
      await sync.request(
        'POST',
        '/auth/offline/verify',
        body: {'current_password': password},
      ),
    );
    if (revision != sync.credentialRevision ||
        SyncEngine.accessRejected.value) {
      throw StateError('Your account access changed. Sign in online again.');
    }
    await enroll(password, proof);
    if (revision != sync.credentialRevision ||
        SyncEngine.accessRejected.value) {
      await clear(epoch: proof['credentialEpoch']);
      throw StateError('Your account access changed. Sign in online again.');
    }
  }

  Future<Map<String, dynamic>> verifyCurrentAccount() async {
    final value = await info();
    if (value == null) {
      throw StateError('Connect and sign in once to enable offline login.');
    }
    await checkBinding(value);
    // Never turn an explicit online rejection into an offline bypass.
    if (await sync.onlineAvailable()) {
      try {
        final me = Map<String, dynamic>.from(
          await sync.request('GET', '/auth/me'),
        );
        if (!await matches(me)) {
          throw StateError(
            'Your password or account access changed. Sign in online again.',
          );
        }
      } on SyncRequestError catch (e) {
        if (e.statusCode < 500) {
          await clear();
          rethrow;
        }
      } on SocketException {
        /* Device is offline. */
      } on SyncTransportError {
        /* Identity service is unreachable. */
      } on TimeoutException {
        /* Service unreachable; use the local verifier. */
      } on http.ClientException {
        /* No network route. */
      }
    }
    return value;
  }

  Future<Map<String, dynamic>> verify(String username, String password) async {
    final value = await verifyCurrentAccount();
    final result = await channel.invokeMapMethod<String, dynamic>('verify', {
      'owner': value['owner'],
      'server': value['server'],
      'username': username,
      'password': password,
    });
    if (result == null) {
      throw StateError('Offline verification did not complete.');
    }
    await checkBinding(result);
    return Map<String, dynamic>.from(result);
  }

  static Future<bool> biometricEnabled() async {
    if (kIsWeb) return false;
    try {
      return await channel.invokeMethod<bool>('biometricInfo') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> enableBiometric() async {
    await verifyCurrentAccount();
    await channel.invokeMethod('biometricEnroll');
  }

  Future<Map<String, dynamic>> unlockBiometric() async {
    await verifyCurrentAccount();
    final proof = await channel.invokeMapMethod<String, dynamic>(
      'biometricUnlock',
    );
    if (proof == null) throw StateError('Use your password to sign in.');
    await checkBinding(proof);
    return Map<String, dynamic>.from(proof);
  }

  Future<void> changePassword(String current, String next) async {
    if (!await sync.onlineAvailable()) {
      throw StateError('Password changes require an internet connection.');
    }
    sync.credentialChangeInProgress = true;
    sync.credentialRevision++;
    try {
      await _changePassword(current, next);
    } finally {
      sync.credentialChangeInProgress = false;
    }
  }

  Future<void> _changePassword(String current, String next) async {
    Map<String, dynamic> proof;
    try {
      proof = Map<String, dynamic>.from(
        await sync.request(
          'POST',
          '/auth/change',
          body: {'current_password': current, 'password': next},
        ),
      );
    } on SyncRequestError {
      rethrow;
    } catch (_) {
      // A lost response may follow a committed server change. Do not keep a stale verifier.
      await clear();
      throw StateError(
        'The password change could not be confirmed. Connect and sign in again before enabling offline login.',
      );
    }
    await clear();
    try {
      await enroll(next, proof);
    } catch (_) {
      throw StateError(
        'Your password changed online, but offline login could not be updated. Sign in online again to enable it.',
      );
    } finally {
      await sync.clearLocalSession();
    }
  }
}
