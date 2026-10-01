import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('farmer_test_');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test('geodesic area, perimeter, winding and invalid boundaries', () {
    const p = [
      GeoPoint(0, 0),
      GeoPoint(0, .001),
      GeoPoint(.001, .001),
      GeoPoint(.001, 0),
    ];
    expect(area(p), closeTo(12364.35, 1));
    expect(perimeter(p), closeTo(444.78, 1));
    expect(area(p.reversed.toList()), closeTo(area(p), .01));
    expect(validatePolygon(p), isNull);
    expect(validatePolygon([p[0], p[2], p[1], p[3]]), contains('crosses'));
    expect(validatePolygon([p[0], p[1], p[0]]), contains('overlap'));
    expect(validatePolygon([GeoPoint(double.nan, 0), p[1], p[2]]), isNotNull);
  });
  test('boundary review warns without rejecting unusual valid shapes', () {
    const tiny = [
      GeoPoint(0, 0),
      GeoPoint(0, .00002),
      GeoPoint(.00002, .00002),
      GeoPoint(.00002, 0),
    ];
    expect(validatePolygon(tiny), isNull);
    expect(boundaryReviewWarnings(tiny, isFarm: true), isNotEmpty);

    const ordinary = [
      GeoPoint(0, 0),
      GeoPoint(0, .001),
      GeoPoint(.001, .001),
      GeoPoint(.001, 0),
    ];
    expect(boundaryReviewWarnings(ordinary, isFarm: true), isEmpty);
  });
  test('plant estimates reject invalid numbers and round down', () {
    expect(plantCount(100, .8, .3), 416);
    expect(() => plantCount(1, 0, 1), throwsArgumentError);
    expect(() => plantCount(double.infinity, 1, 1), throwsArgumentError);
  });
  test(
    'offline writes, drafts and stable identifiers survive restart',
    () async {
      final farmer = await store.setting('farmerId');
      final id = await store.save('diary', {
        'title': 'Planted beans',
        'media': [],
      });
      await store.setSetting('profileDraft', {'name': 'Incomplete'});
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      expect(await store.setting('farmerId'), farmer);
      expect((await store.get(id))!['data']['title'], 'Planted beans');
      expect((await store.db.query('queue')).length, 1);
      expect((await store.setting('profileDraft'))['name'], 'Incomplete');
    },
  );
  test(
    'closing an independent background handle keeps foreground open',
    () async {
      final background = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
        singleInstance: false,
      );
      await background.setSetting('backgroundProbe', true);
      await background.close();

      expect(await store.setting('backgroundProbe'), true);
      await store.setSetting('foregroundProbe', true);
      expect(await store.setting('foregroundProbe'), true);
    },
  );
  test(
    'permission boundaries reject other mini-app records and payments',
    () async {
      expect(
        () => store.save('diary', {}, scope: catalogue.last),
        throwsStateError,
      );
      expect(
        () => store.records('profile', scope: catalogue.first),
        throwsStateError,
      );
      expect(() => store.save('payment', {}), throwsStateError);
    },
  );
  test(
    'acknowledging an in-flight edit preserves a newer offline edit',
    () async {
      final id = await store.save('diary', {'title': 'First'});
      final op = (await store.db.query('queue')).single;
      await store.save('diary', {'title': 'Edited during upload'}, id: id);
      await store.acknowledge(op, 1);
      final queued = (await store.db.query('queue')).single;
      expect(queued['op_id'], isNot(op['op_id']));
      expect(queued['base_version'], 1);
      expect((await store.get(id))!['data']['title'], 'Edited during upload');
    },
  );
  test(
    'incoming changes cannot overwrite queued edits; explicit resolution rebases',
    () async {
      final id = await store.save('diary', {'title': 'Offline'});
      await store.incoming({
        'id': id,
        'kind': 'diary',
        'data': {'title': 'Server'},
        'version': 3,
        'deleted': false,
        'updated': DateTime.now().toUtc().toIso8601String(),
      });
      expect((await store.get(id))!['data']['title'], 'Offline');
      expect((await store.db.query('conflicts')).length, 1);
      await store.resolve(id, keepLocal: true);
      expect((await store.db.query('queue')).single['base_version'], 3);
      expect((await store.db.query('conflicts')), isEmpty);
    },
  );
  test(
    'server deletion is applied only after user resolves conflict',
    () async {
      final id = await store.save('task', {'title': 'Keep?'});
      await store.incoming({
        'id': id,
        'kind': 'task',
        'data': {},
        'version': 2,
        'deleted': true,
        'updated': DateTime.now().toUtc().toIso8601String(),
      });
      expect(await store.records('task'), isNotEmpty);
      await store.resolve(id, keepLocal: false);
      expect(await store.records('task'), isEmpty);
      expect(await store.db.query('queue'), isEmpty);
    },
  );
  test(
    'install persists, integrity catches corruption, removal removes owned records and pending work',
    () async {
      await store.save('diary', {'title': 'Retained'});
      await store.install(catalogue.firstWhere((a) => a.id == 'diary'));
      expect(await store.ready('diary'), true);
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      expect(await store.ready('diary'), true);
      await File('${dir.path}/packs/diary.json').writeAsString('corrupt');
      expect(await store.ready('diary'), false);
      await store.install(catalogue.firstWhere((a) => a.id == 'diary'));
      expect(await store.ready('diary'), true);
      await store.removeApp('diary');
      expect(await store.ready('diary'), false);
      expect(await store.records('diary'), isEmpty);
      expect(await store.db.query('queue'), isEmpty);
    },
  );
  test(
    'partial package resumes and rejects mismatched partial prefix',
    () async {
      var calls = 0;
      await store.install(catalogue.last, cancelled: () => ++calls > 1);
      expect(await store.ready('learning'), false);
      expect((await store.installations()).single['bytes'], 128);
      await File(
        '${dir.path}/packs/learning.partial',
      ).writeAsString('bad prefix');
      await store.install(catalogue.last);
      expect(await store.ready('learning'), true);
      expect((await store.content('learning'))['id'], 'learning');
    },
  );
  test(
    'Learning client installation is distinct from course content and progress',
    () async {
      await store.install(catalogue.last);
      expect(await store.ready('sample-records'), false);
      const course = MiniManifest(
        'sample-records',
        'Sample',
        '',
        'Learning',
        {'progress'},
        {'progress'},
      );
      await store.install(course);
      expect((await store.content('sample-records'))['lessons'], hasLength(2));
      await store.save('progress', {
        'courseId': 'sample-records',
        'sample': true,
        'lessons': [0],
      }, scope: catalogue.last);
      await store.removeApp('sample-records');
      expect(await store.records('progress'), hasLength(1));
      expect(await store.ready('learning'), true);
    },
  );
  test('wallet disconnected adapter fails closed for every action', () async {
    final wallet = DisconnectedWallet();
    const asset = AssetConfiguration('', '', '', '');
    expect(asset.valid, false);
    await expectLater(wallet.verifiedBalance(asset), throwsStateError);
    await expectLater(wallet.quote(asset, 'recipient', '1'), throwsStateError);
    await expectLater(
      wallet.submit({}, explicitlyApproved: true),
      throwsStateError,
    );
    expect(jsonEncode(await store.db.query('queue')), '[]');
  });
}
