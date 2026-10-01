import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/backup.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/store.dart';

Map<String, dynamic> feature(
  String id,
  String kind,
  List<List<num>> ring, {
  String? farm,
}) => {
  'type': 'Feature',
  'properties': {
    'id': id,
    'kind': kind,
    'name': id,
    if (farm != null) 'farmId': farm,
  },
  'geometry': {
    'type': 'Polygon',
    'coordinates': [ring],
  },
};
Map<String, dynamic> collection(List<dynamic> features) => {
  'type': 'FeatureCollection',
  'features': features,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final outer = [
    [0, 0],
    [.01, 0],
    [.01, .01],
    [0, .01],
    [0, 0],
  ];
  final inner = [
    [.001, .001],
    [.002, .001],
    [.002, .002],
    [.001, .002],
    [.001, .001],
  ];
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('farmer_amendments_');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'GeoJSON import remaps parents, strips unknown values and commits atomically',
    () async {
      final farm = feature('farm-a', 'farm', outer);
      farm['properties']['owner'] = 'untrusted-owner';
      final rows = parseGeoJson(
        collection([feature('field-a', 'field', inner, farm: 'farm-a'), farm]),
      );
      expect(rows.first['kind'], 'farm');
      expect(rows.last['data']['farmId'], rows.first['id']);
      expect(rows.first['data'].containsKey('owner'), false);
      expect(rows.first['id'], isNot('farm-a'));
      await importPolygons(store, rows);
      await expectLater(importPolygons(store, rows), throwsStateError);
      expect(await store.records('farm'), hasLength(1));
      expect(await store.records('field'), hasLength(1));
      expect(await store.db.query('queue'), hasLength(2));
    },
  );
  test(
    'Malformed imports, foreign parents and fields outside boundaries fail before save',
    () {
      for (final item in [
        {'geometry': 'invalid'},
        {...feature('a', 'farm', outer), 'properties': []},
        {
          ...feature('a', 'farm', outer),
          'properties': {'name': []},
        },
        feature('field', 'field', inner, farm: 'not-in-file'),
      ]) {
        expect(() => parseGeoJson(collection([item])), throwsStateError);
      }
      expect(
        () => parseGeoJson(
          collection([
            feature('a', 'farm', inner),
            feature('b', 'field', outer, farm: 'a'),
          ]),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'Removal wins over an earlier install through another store and blocks synced resurrection',
    () async {
      final second = FarmStore(store.db, store.filesPath);
      final app = catalogue.firstWhere((a) => a.id == 'diary');
      final install = store.install(app);
      final removal = second.removeApp('diary');
      await Future.wait([install, removal]);
      expect(await store.ready('diary'), false);
      expect(await store.setting('removedApp:diary'), true);
      await store.incoming({
        'id': 'old-server-record',
        'kind': 'diary',
        'data': {'title': 'Old'},
        'version': 1,
        'deleted': false,
        'updated': DateTime.now().toUtc().toIso8601String(),
      });
      expect(await store.records('diary'), isEmpty);
      await expectLater(
        store.save('diary', {'title': 'Stale form'}),
        throwsStateError,
      );
      for (final id in ['store', 'farm', 'wallet', 'learning', 'inbox']) {
        await expectLater(store.removeApp(id), throwsStateError);
      }
    },
  );
  test(
    'Offline stock and sale entries reject overspending while payment edits retain the sale',
    () async {
      final farm = await store.save('farm', {
        'name': 'Test farm',
        'points': [
          for (final p in outer.take(4)) {'lat': p[1], 'lon': p[0]},
        ],
      });
      final stock = await store.save('stock', {
        'name': 'Seed',
        'farmId': farm,
        'unit': 'kg',
      });
      await store.save('stockmove', {
        'farmId': farm,
        'stockId': stock,
        'delta': 10,
      });
      await expectLater(
        store.save('stockmove', {
          'farmId': farm,
          'stockId': stock,
          'delta': -11,
        }),
        throwsStateError,
      );
      final harvest = await store.save('harvest', {
        'farmId': farm,
        'name': 'Beans',
        'quantity': 10,
        'unit': 'kg',
      });
      final values = {
        'farmId': farm,
        'harvestId': harvest,
        'quantity': 6,
        'unitPrice': 2.5,
        'currency': 'ZAR',
        'payment': 'Unpaid',
      };
      final sale = await store.save('sale', values);
      await store.save('sale', {...values, 'payment': 'Paid'}, id: sale);
      expect((await store.get(sale))!['data']['total'], 15);
      await expectLater(
        store.save('sale', {...values, 'quantity': 5}),
        throwsStateError,
      );
      expect(await store.records('sale'), hasLength(1));
    },
  );
}
