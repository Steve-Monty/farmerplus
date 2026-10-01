import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:farmerplus_mobile/offline_access.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android Keystore file encryption, offline verification, rotation and tamper checks',
    (tester) async {
      expect(
        (await PackageInfo.fromPlatform()).packageName.endsWith('.qa'),
        true,
        reason: 'This test must never touch the normal application vault.',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Synthetic offline-login security test')),
        ),
      );
      await OfflineAccess.clear();
      addTearDown(OfflineAccess.clear);
      const meta = {
        'owner': 'native-qa-owner',
        'studentId': '0123456789abcdef0123456789abcdef',
        'username': 'native_qa_farmer',
        'server': 'https://qa.invalid',
        'credentialEpoch': 2,
      };
      const password = 'Synthetic-Native-Password';
      await OfflineAccess.channel.invokeMethod('enroll', {
        ...meta,
        'password': password,
      });
      final root = (await getApplicationSupportDirectory()).parent;
      final file = File('${root.path}/no_backup/offline-access.enc');
      expect(await file.exists(), true);
      final raw = await file.readAsString();
      expect(jsonDecode(raw)['version'], 1);
      for (final secret in [
        password,
        'native_qa_farmer',
        'native-qa-owner',
        'verifier',
      ]) {
        expect(raw, isNot(contains(secret)));
      }
      Future<dynamic> verify(
        String value, {
        String owner = 'native-qa-owner',
      }) => OfflineAccess.channel.invokeMethod('verify', {
        ...meta,
        'owner': owner,
        'password': value,
      });
      expect((await verify(password))['credentialEpoch'], 2);
      await expectLater(
        verify(password, owner: 'another-owner'),
        throwsA(isA<PlatformException>()),
      );
      for (var i = 0; i < 5; i++) {
        await expectLater(
          verify('Wrong-Password'),
          throwsA(isA<PlatformException>()),
        );
      }
      await expectLater(verify(password), throwsA(isA<PlatformException>()));
      // A new synthetic online proof rotates the salt, verifier, ciphertext and credential epoch.
      await OfflineAccess.channel.invokeMethod('enroll', {
        ...meta,
        'credentialEpoch': 3,
        'password': 'New-Native-Password',
      });
      expect(await file.readAsString(), isNot(raw));
      await expectLater(verify(password), throwsA(isA<PlatformException>()));
      expect((await verify('New-Native-Password'))['credentialEpoch'], 3);
      await OfflineAccess.clear(epoch: 2);
      expect((await OfflineAccess.info())?['credentialEpoch'], 3);
      final envelope = jsonDecode(await file.readAsString());
      final ciphertext = base64Decode(envelope['data']);
      ciphertext[0] ^= 1;
      envelope['data'] = base64Encode(ciphertext);
      await file.writeAsString(jsonEncode(envelope), flush: true);
      await expectLater(
        OfflineAccess.info(),
        throwsA(isA<PlatformException>()),
      );
      await OfflineAccess.clear();
      expect(await file.exists(), false);
    },
  );
}
