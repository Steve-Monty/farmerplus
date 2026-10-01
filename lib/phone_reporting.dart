import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'store.dart';

typedef PhoneSender = Future<dynamic> Function(Map<String, dynamic> body);

/// Persist the exact snapshot before sending. Never acknowledge a different
/// report/account/device, or lose a pending report when the network drops.
class PhoneReporter {
  final FarmStore store;
  final Future<Map<String, dynamic>> Function() collect;
  bool _busy = false;
  DateTime? _retryAt;
  int _failures = 0;
  PhoneReporter(
    this.store, {
    Future<Map<String, dynamic>> Function()? collector,
  }) : collect = collector ?? collectAndroid;

  static Future<Map<String, dynamic>> collectAndroid() async {
    if (kIsWeb || !Platform.isAndroid) throw UnsupportedError('Android only');
    final result = await const MethodChannel(
      'farmerplus/phone-diagnostics',
    ).invokeMapMethod<String, dynamic>('collect');
    if (result == null) throw StateError('No diagnostics returned');
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(result)));
  }

  Future<void> report({
    required String owner,
    required String server,
    required PhoneSender send,
    bool forceRetry = false,
    bool captureCurrent = false,
  }) async {
    if (_busy ||
        (!forceRetry &&
            _retryAt != null &&
            DateTime.now().isBefore(_retryAt!))) {
      return;
    }
    _busy = true;
    try {
      final key = 'phoneReport:$owner:$server';
      var stillCaptureCurrent = captureCurrent;
      while (true) {
        var state = await store.setting(key);
        // A fresh technical snapshot is collected only after a successful
        // online login. Ordinary startup/background calls only retry an
        // unacknowledged snapshot, so an offline unlock never creates a
        // misleading new report.
        if (state is! Map || state['ack'] == 'y') {
          if (!stillCaptureCurrent) break;
          stillCaptureCurrent = false;
          final device = await store.setting('deviceId') ?? const Uuid().v4();
          await store.setSetting('deviceId', device);
          final snapshot = await collect();
          final technical = Map<String, dynamic>.from(
            snapshot['technical'] as Map,
          );
          technical.putIfAbsent('phoneIdentifier', () => 'INSTALL-$device');
          technical.putIfAbsent(
            'phoneIdentifierType',
            () => 'Installation ID fallback; resets on reinstall',
          );
          final body = <String, dynamic>{
            'schemaVersion': 1,
            'reportId': const Uuid().v4(),
            'deviceId': device,
            'capturedAt': DateTime.now().millisecondsSinceEpoch,
            'technical': technical,
            'permissions': snapshot['permissions'],
            'unavailable': [
              'imei',
              'hardwareSerial',
              'macAddress',
              'rootAttestation',
            ],
          };
          state = {'ack': 'n', 'body': body};
          await store.setSetting(key, state);
        }
        final body = Map<String, dynamic>.from(state['body'] as Map);
        final response = await send(body);
        if (response is! Map ||
            response['ack'] != 'y' ||
            response['reportId'] != body['reportId'] ||
            response['deviceId'] != body['deviceId'] ||
            response['owner'] != owner ||
            response['receivedAt'] is! int) {
          throw StateError('Phone report acknowledgement did not match');
        }
        if (await store.setting('boundOwner') != owner ||
            await store.setting('boundServer') != server) {
          return;
        }
        await store.setSetting(key, {
          'ack': 'y',
          'body': body,
          'receivedAt': response['receivedAt'],
        });
        if (!stillCaptureCurrent) break;
      }
      _retryAt = null;
      _failures = 0;
    } catch (_) {
      _failures = (_failures + 1).clamp(1, 6);
      _retryAt = DateTime.now().add(
        Duration(seconds: (15 * (1 << _failures)).clamp(30, 900)),
      );
      // ACK remains n; ordinary record syncing is unaffected.
    } finally {
      _busy = false;
    }
  }
}
