import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/sync.dart';

void main() {
  test(
    'sign in chooses verified local access offline and after a timeout',
    () async {
      var localCalls = 0, remoteCalls = 0;
      Future<Map<String, dynamic>> local() async {
        localCalls++;
        return {'owner': 'one'};
      }

      final offline = await automaticSignIn(
        online: () async => false,
        remote: () async {
          remoteCalls++;
          return {};
        },
        local: local,
      );
      expect(offline.$2, isTrue);
      expect(remoteCalls, 0);
      final unavailable = await automaticSignIn(
        online: () async => true,
        remote: () async => throw TimeoutException('offline'),
        local: local,
      );
      expect(unavailable.$2, isTrue);
      expect(localCalls, 2);
    },
  );
  test(
    'authentication rejection never falls back to saved credentials',
    () async {
      for (final status in [400, 401, 403, 429]) {
        await expectLater(
          automaticSignIn(
            online: () async => true,
            remote: () async => throw SyncRequestError(status, 'Rejected'),
            local: () async {
              fail('Offline bypass');
            },
          ),
          throwsA(isA<SyncRequestError>()),
        );
      }
      final result = await automaticSignIn(
        online: () async => true,
        remote: () async => {'owner': 'one'},
        local: () async {
          fail('Unexpected fallback');
        },
      );
      expect(result.$2, isFalse);
    },
  );
}
