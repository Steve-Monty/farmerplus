import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/learning.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:crypto/crypto.dart';

const owner = '0123456789abcdef0123456789abcdef';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('oidc_learning_');
    store = await FarmStore.open(
      factory: databaseFactoryFfiNoIsolate,
      filesPath: dir.path,
    );
    await store.setSetting('studentId', owner);
    SyncEngine.activeTokens[store] = 'opaque-fixture-only';
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'Learning accepts the FarmerPlus realm and rejects substituted issuers',
    () async {
      Future<Map<String, dynamic>> configuration(String issuer) {
        final sync = SyncEngine(
          store,
          client: MockClient((request) async {
            expect(request.url.path, '/oidc/config');
            return http.Response(
              jsonEncode({
                'enabled': true,
                'provider': 'keycloak',
                'issuer': issuer,
                'learningUrl': 'https://learn.agritec.earth',
              }),
              200,
            );
          }),
        );
        return sync.oidcConfiguration().whenComplete(sync.client.close);
      }

      expect(
        (await configuration(
          'https://auth.agritec.earth/realms/farmerplus',
        ))['enabled'],
        true,
      );
      for (final issuer in [
        'https://auth.agritec.earth/realms/other',
        'https://auth.agritec.earth.evil.example/realms/farmerplus',
        'http://auth.agritec.earth/realms/farmerplus',
        'https://auth.agritec.earth/realms/farmerplus?realm=other',
        'https://identity.agritec.earth',
      ]) {
        await expectLater(configuration(issuer), throwsStateError);
      }
    },
  );
  test(
    'Scoped course API adopts only the matching permanent and legacy learner identity',
    () async {
      await store.setSetting('learningUser', {
        'id': 31,
        'name': 'Existing student',
      });
      final calls = <String>[];
      final api = StudentLearning(
        store,
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.method, 'GET');
          expect(
            request.headers['authorization'],
            'Bearer opaque-fixture-only',
          );
          expect(request.url.queryParameters.containsKey('userid'), false);
          return http.Response(
            jsonEncode({
              'farmerplus_id': owner,
              'moodle_user_id': 31,
              'courses': [
                {'id': 2, 'name': 'Records', 'progress': null},
              ],
              'total': 1,
            }),
            200,
          );
        }),
      );
      await api.refresh();
      expect(calls, ['/learning/courses']);
      expect((await store.setting('learningUser'))['farmerplusId'], owner);
      expect(
        (await store.setting('learningCourses'))['courses'][0]['fullname'],
        'Records',
      );
      api.client.close();
    },
  );
  test(
    'A different mapped Moodle person cannot replace preserved downloads',
    () async {
      await store.setSetting('learningUser', {'id': 31});
      await store.setSetting('learningCourse:2', {'offlineText': 'Preserved'});
      final api = StudentLearning(
        store,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'farmerplus_id': owner,
              'moodle_user_id': 99,
              'courses': [],
              'total': 0,
            }),
            200,
          ),
        ),
      );
      await expectLater(api.refresh(), throwsStateError);
      expect((await store.setting('learningUser'))['id'], 31);
      expect(
        (await store.setting('learningCourse:2'))['offlineText'],
        'Preserved',
      );
      api.client.close();
    },
  );
  test('A failed refresh never deletes downloaded lessons', () async {
    await store.setSetting('learningCourse:2', {'offlineText': 'Preserved'});
    final api = StudentLearning(
      store,
      client: MockClient(
        (_) async => http.Response('{"detail":"Unavailable"}', 503),
      ),
    );
    await expectLater(api.refresh(), throwsStateError);
    expect(
      (await store.setting('learningCourse:2'))['offlineText'],
      'Preserved',
    );
    api.client.close();
  });
  test(
    'Text downloads use scoped routes and preserve old text on partial failure',
    () async {
      await store.setSetting('learningCourse:2', {
        'offlineText': 'Previous download',
      });
      final calls = <String>[];
      final api = StudentLearning(
        store,
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.method, 'GET');
          expect(request.url.queryParameters.containsKey('token'), false);
          if (request.url.path == '/learning/activities/2') {
            return http.Response(
              jsonEncode({
                'courseid': 2,
                'activities': [
                  {
                    'id': 3,
                    'name': 'Page',
                    'type': 'page',
                    'launch_url':
                        'https://learn.agritec.earth/auth/farmerplusoidc/login.php?cmid=3',
                  },
                  {
                    'id': 4,
                    'name': 'Book',
                    'type': 'book',
                    'launch_url':
                        'https://learn.agritec.earth/auth/farmerplusoidc/login.php?cmid=4',
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/learning/text/3') {
            return http.Response(
              '{"cmid":3,"text":"Plain entitled text"}',
              200,
            );
          }
          return http.Response('{"detail":"Unavailable"}', 503);
        }),
      );
      await expectLater(api.downloadText(2), throwsStateError);
      expect(
        (await store.setting('learningCourse:2'))['offlineText'],
        'Previous download',
      );
      expect(calls, [
        '/learning/activities/2',
        '/learning/text/3',
        '/learning/text/4',
      ]);
      await expectLater(api.resource('quiz-attempt'), throwsStateError);
      api.client.close();
    },
  );
  test(
    'Downloaded text is owner partitioned and contains no credential URLs',
    () async {
      final api = StudentLearning(
        store,
        client: MockClient(
          (request) async => request.url.path == '/learning/activities/2'
              ? http.Response(
                  jsonEncode({
                    'courseid': 2,
                    'activities': [
                      {
                        'id': 3,
                        'name': 'Lesson',
                        'type': 'page',
                        'launch_url':
                            'https://learn.agritec.earth/auth/farmerplusoidc/login.php?cmid=3',
                      },
                    ],
                  }),
                  200,
                )
              : http.Response('{"cmid":3,"text":"Read offline"}', 200),
        ),
      );
      await api.downloadText(2);
      final saved = await api.savedCourse(2);
      expect(saved!['owner'], owner);
      expect(saved['downloadedTexts'], 1);
      expect(saved['sections'][0]['modules'][0]['offlineText'], 'Read offline');
      expect(jsonEncode(saved), isNot(contains('opaque-fixture')));
      api.client.close();
    },
  );
  test(
    'Selected downloads verify hashes and keep unselected and removed lessons',
    () async {
      await store.setSetting('learningCourse:2', {
        'owner': owner,
        'sections': [
          {
            'modules': [
              {'id': 9, 'name': 'Prior lesson', 'offlineText': 'Saved earlier'},
            ],
          },
        ],
      });
      final text = 'A verified soil lesson';
      final manifest = <String, dynamic>{
        'schema': 1,
        'courseid': 2,
        'farmerplus_id': owner,
        'tenant_id': 'farmerplus',
        'instance_id': 'farmerplus-learning',
        'offline_enabled': true,
        'version': 'v1',
        'activities': [
          {
            'id': 3,
            'name': 'Soil',
            'type': 'page',
            'section': 1,
            'offline': true,
            'format': 'text/plain',
            'bytes': utf8.encode(text).length,
            'sha256': sha256.convert(utf8.encode(text)).toString(),
          },
          {'id': 4, 'name': 'Quiz', 'type': 'quiz', 'offline': false},
        ],
      };
      final api = StudentLearning(
        store,
        client: MockClient((r) async {
          expect(r.url.path, '/learning/text/3');
          return http.Response(jsonEncode({'cmid': 3, 'text': text}), 200);
        }),
      );
      await api.downloadSelected(2, manifest, {3});
      final saved = (await api.savedCourse(2))!;
      expect(saved['onlineActivities'], 1);
      expect(saved['downloadedTexts'], 2);
      expect(
        saved['sections'][0]['modules'].last['offlineText'],
        'Saved earlier',
      );
      expect(saved['sections'][0]['modules'].last['archivedDownload'], true);
      await expectLater(
        api.downloadSelected(2, manifest, {4}),
        throwsStateError,
      );
      manifest['activities'][0]['sha256'] = 'tampered';
      await expectLater(
        api.downloadSelected(2, manifest, {3}),
        throwsStateError,
      );
      expect(await api.savedCourse(2), saved);
      expect(
        (await store.setting(
          'learningCourse:2',
        ))['sections'][0]['modules'][0]['offlineText'],
        'Saved earlier',
      );
      manifest['farmerplus_id'] = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await expectLater(
        api.downloadSelected(2, manifest, {3}),
        throwsStateError,
      );
      api.client.close();
    },
  );
  test('HTML summaries remove scripts and styles', () {
    expect(
      lessonText(
        '<p>Farm</p><script>secret()</script><style>x</style><p>Records</p>',
      ),
      'Farm\nRecords',
    );
  });
}
