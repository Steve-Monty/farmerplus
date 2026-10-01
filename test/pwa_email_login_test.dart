import 'dart:convert';
import 'dart:io';

import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/pwa_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class KeycloakProviderFixture extends SyncEngine {
  KeycloakProviderFixture(super.store);
  @override
  Future<dynamic> request(
    String method,
    String route, {
    Object? body,
  }) async => {
    'authority': 'keycloak',
    'keycloak': {'configured': true, 'startUrl': '/oidc/web/login'},
    'google': {
      'configured': true,
      'startUrl': '/oidc/web/login?provider=google',
    },
    'apple': {'configured': true, 'startUrl': '/oidc/web/login?provider=apple'},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late FarmStore store;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('pwa-email-login-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: directory.path,
    );
    await store.setSetting('server', 'http://127.0.0.1:8087');
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'Keycloak opens the sign-in form directly and provides a bounded retry',
    (tester) async {
      final engine = KeycloakProviderFixture(store);
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: EmailSignInPage(
            store: store,
            sync: engine,
            onAuthenticated: (_, _) async {},
            onOfflineAuthenticated: () async {},
            openSignIn: opened.add,
          ),
        ),
      );
      await tester.runAsync(() async {
        // Provider discovery now reads the account's persisted offline state.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(opened, ['/oidc/web/login']);
      expect(find.text('Opening sign-in…'), findsOneWidget);
      expect(find.text('Register as a farmer'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pump(const Duration(seconds: 13));
      expect(find.text('Retry sign-in'), findsOneWidget);
      await tester.tap(find.text('Retry sign-in'));
      expect(opened.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      engine.client.close();
    },
  );

  testWidgets('registration requires names and can reveal both passwords', (
    tester,
  ) async {
    final engine = KeycloakProviderFixture(store);
    await tester.pumpWidget(
      MaterialApp(home: EmailRegistrationPage(sync: engine)),
    );
    expect(find.text('Register as a farmer'), findsOneWidget);
    expect(find.text('First name (optional)'), findsNothing);
    expect(find.text('Last name (optional)'), findsNothing);
    await tester.tap(find.text('Create account'));
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byTooltip('Show confirmed password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show confirmed password'));
    await tester.pump();
    expect(find.byTooltip('Hide confirmed password'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
  });

  testWidgets('service outage retains device unlock without redirecting', (
    tester,
  ) async {
    final engine = KeycloakProviderFixture(store);
    await tester.runAsync(
      () => store.setSetting('offlineEmailVerifier', {
        'purpose': 'device-unlock',
      }),
    );
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: EmailSignInPage(
          store: store,
          sync: engine,
          onAuthenticated: (_, _) async {},
          onOfflineAuthenticated: () async {},
          openSignIn: opened.add,
          initialMessage: 'FarmerPlus could not check the server.',
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('Device passphrase'), findsOneWidget);
    expect(find.text('Open saved work offline'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
  });

  test(
    'minimal email login response resolves the canonical browser session',
    () async {
      final routes = <String>[];
      final engine = SyncEngine(
        store,
        client: MockClient((request) async {
          routes.add('${request.method} ${request.url.path}');
          if (request.url.path == '/auth/email/login') {
            expect(jsonDecode(request.body), {
              'email': 'farmer@example.org',
              'password': 'Safe password 42',
            });
            return http.Response(
              jsonEncode({
                'owner': 'owner-a',
                'expires': 1924992000,
                'verified': true,
                'studentId': '0123456789abcdef0123456789abcdef',
                'accessOwner': 'farmerplus:0123456789abcdef0123456789abcdef',
                'accountKind': 'email',
              }),
              200,
            );
          }
          expect(request.url.path, '/auth/me');
          return http.Response(
            jsonEncode({
              'owner': 'owner-a',
              'username': 'email:hashed-account',
              'admin': false,
              'verified': true,
              'email': 'farmer@example.org',
              'studentId': '0123456789abcdef0123456789abcdef',
              'firstname': 'Review',
              'lastname': 'Farmer',
              'accessOwner': 'farmerplus:0123456789abcdef0123456789abcdef',
              'accountKind': 'email',
              'credentialEpoch': 1,
            }),
            200,
          );
        }),
      );

      final session = await engine.emailLogin(
        'farmer@example.org',
        'Safe password 42',
      );

      expect(routes, ['POST /auth/email/login', 'GET /auth/me']);
      expect(session['email'], 'farmer@example.org');
      expect(session['credentialEpoch'], 1);
      await engine.acceptBrowserSession(session);
      expect(await store.setting('boundOwner'), 'owner-a');
      expect(await store.setting('accountEmail'), 'farmer@example.org');
      engine.dispose();
    },
  );

  test('email login rejects a canonical session for another owner', () async {
    final engine = SyncEngine(
      store,
      client: MockClient((request) async {
        if (request.url.path == '/auth/email/login') {
          return http.Response('{"owner":"owner-a"}', 200);
        }
        return http.Response(
          '{"owner":"owner-b","email":"farmer@example.org"}',
          200,
        );
      }),
    );

    await expectLater(
      engine.emailLogin('farmer@example.org', 'Safe password 42'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('did not match'),
        ),
      ),
    );
    engine.dispose();
  });
}
