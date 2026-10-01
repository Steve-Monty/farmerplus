import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/farm_context.dart';
import 'package:farmerplus_mobile/map_downloads.dart';
import 'package:farmerplus_mobile/place_colors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('farm-area-test-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  const parent = [
    GeoPoint(0, 0),
    GeoPoint(0, .004),
    GeoPoint(.004, .004),
    GeoPoint(.004, 0),
  ];
  const inner = [
    GeoPoint(.001, .001),
    GeoPoint(.001, .002),
    GeoPoint(.002, .002),
    GeoPoint(.002, .001),
  ];
  test(
    'open path rejects crossings before closing and allows concave shapes',
    () {
      expect(
        validateOpenBoundary([parent[0], parent[2], parent[1], parent[3]]),
        isNotNull,
      );
      expect(validateOpenBoundary(parent.take(2).toList()), isNull);
      expect(
        validatePolygon([
          parent[0],
          parent[1],
          GeoPoint(.001, .002),
          parent[2],
          parent[3],
        ]),
        isNull,
      );
    },
  );
  test(
    'unmapped names link offline; mapping edits keep IDs and history',
    () async {
      final f = await store.save('farm', {'name': 'Farm'});
      final a = await store.save('field', {
        'name': 'Paddock',
        'farmId': f,
        'points': [],
      });
      final d = await store.save('diary', {
        'title': 'First activity',
        'fieldId': a,
      });
      expect((await store.get(d))!['data']['farmId'], f);
      await store.save('farm', {
        'name': 'Farm',
        'points': parent.map((p) => p.toJson()).toList(),
      }, id: f);
      await store.save('field', {
        'name': 'Renamed paddock',
        'farmId': f,
        'points': inner.map((p) => p.toJson()).toList(),
      }, id: a);
      expect((await store.get(d))!['data']['fieldId'], a);
      final snapshot = areaSnapshot((await store.get(a))!);
      await store.save('calculation', {
        'title': 'Plant estimate',
        'farmId': f,
        'fieldId': a,
        'areaSnapshot': snapshot,
      });
      await store.save('field', {
        'name': 'Renamed paddock',
        'farmId': f,
        'points': [],
      }, id: a);
      expect(
        (await store.records(
          'calculation',
        )).single['data']['areaSnapshot']['source'],
        'Mapped',
      );
      expect(
        (await store.records(
          'calculation',
        )).single['data']['areaSnapshot']['areaM2'],
        greaterThan(0),
      );
      await expectLater(
        store.save(
          'field',
          {'name': 'Delete', 'farmId': f},
          id: a,
          deleted: true,
        ),
        throwsStateError,
      );
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      expect(await store.db.query('queue'), hasLength(4));
    },
  );
  test('farm cannot shrink or clear around mapped children', () async {
    final f = await store.save('farm', {
      'name': 'Farm',
      'points': parent.map((p) => p.toJson()).toList(),
    });
    await store.save('field', {
      'name': 'Mapped',
      'farmId': f,
      'points': inner.map((p) => p.toJson()).toList(),
    });
    await expectLater(
      store.save('farm', {'name': 'Farm', 'points': []}, id: f),
      throwsStateError,
    );
  });
  test(
    'stock use and linked diary save atomically and replay without duplicates',
    () async {
      final f = await store.save('farm', {'name': 'Farm'}),
          a = await store.save('field', {'name': 'Area', 'farmId': f});
      final stock = await store.save('stock', {
        'name': 'Seed',
        'farmId': f,
        'unit': 'kg',
      });
      await store.save('stockmove', {
        'farmId': f,
        'stockId': stock,
        'delta': 10,
        'date': '2026-09-13',
      });
      final data = {
        'farmId': f,
        'fieldId': a,
        'stockId': stock,
        'delta': -2,
        'date': '2026-09-13',
        'createDiary': true,
        'itemName': 'Seed',
        'unit': 'kg',
      };
      final movement = await store.save('stockmove', data);
      await store.save('stockmove', {...data, 'delta': -3}, id: movement);
      expect(await store.records('diary'), hasLength(1));
      expect(
        (await store.records('diary')).single['data']['stockmoveId'],
        movement,
      );
      await expectLater(
        store.save('stockmove', {...data, 'delta': -30}, id: movement),
        throwsStateError,
      );
      expect((await store.get(movement))!['data']['delta'], -3);
      expect(
        (await store.records('diary')).single['data']['notes'],
        startsWith('3'),
      );
      await store.setSetting('removedApp:diary', true);
      await expectLater(
        store.save('stockmove', {...data, 'delta': -4}, id: movement),
        throwsStateError,
      );
      expect((await store.get(movement))!['data']['delta'], -3);
      expect(
        (await store.records('diary')).single['data']['notes'],
        startsWith('3'),
      );
    },
  );
  test('cross-farm associations and invalid pins are rejected', () async {
    final f = await store.save('farm', {'name': 'One'}),
        g = await store.save('farm', {'name': 'Two'});
    final a = await store.save('field', {'name': 'Area', 'farmId': f});
    await expectLater(
      store.save('task', {'title': 'Wrong', 'farmId': g, 'fieldId': a}),
      throwsStateError,
    );
    await expectLater(
      store.save('pin', {'name': 'Bad', 'farmId': f, 'lat': 91, 'lon': 0}),
      throwsStateError,
    );
  });
  test(
    'places queue at farm level and crop seasons keep their chosen area',
    () async {
      final f = await store.save('farm', {'name': 'Farm One'});
      final a = await store.save('field', {'name': 'Craal', 'farmId': f});
      final p = await store.save('pin', {
        'name': 'North gate',
        'type': 'Gate',
        'fieldId': a,
        'lat': -26.0565,
        'lon': 28.0697,
      });
      final s = await store.save('season', {
        'name': 'Spring maize',
        'crop': 'Maize',
        'farmId': f,
        'fieldId': a,
        'start': '2026-09-17',
        'status': 'Planned',
      });
      final place = (await store.get(p))!;
      expect(place['data']['farmId'], f);
      expect(place['data']['fieldId'], isNull);
      expect((await store.get(s))!['data']['fieldId'], a);
      final queue = await store.db.query('queue');
      expect(queue.where((r) => r['id'] == p || r['id'] == s), hasLength(2));
      final queuedPlace = jsonDecode(
        queue.singleWhere((r) => r['id'] == p)['data'] as String,
      );
      expect(queuedPlace['fieldId'], isNull);
      expect(queuedPlace['lat'], -26.0565);
      final color = place['data']['color'];
      expect(validPlaceColor(color), isTrue);
      final p2 = await store.save('pin', {
        'name': 'Water point',
        'farmId': f,
        'lat': -26.0566,
        'lon': 28.0698,
      });
      expect((await store.get(p2))!['data']['color'], isNot(color));
      await store.save(
        'pin',
        Map<String, dynamic>.from(place['data'])..['name'] = 'Renamed gate',
        id: p,
      );
      expect((await store.get(p))!['data']['color'], color);
      expect(
        seasonLocation((await store.get(s))!, [(await store.get(a))!]),
        'Craal',
      );
    },
  );
  test('map radius means radius and offline style has no network assets', () {
    final b = mapBounds(-30, 25, 5);
    expect(
      distance(GeoPoint(b[1], 25), GeoPoint(b[3], 25)),
      closeTo(10000, 10),
    );
    final style = jsonDecode(localMapStyle('/data/farm/map.pmtiles'));
    expect(style.containsKey('glyphs'), false);
    expect(style.containsKey('sprite'), false);
    expect(
      style['sources']['local']['url'],
      'pmtiles://file:///data/farm/map.pmtiles',
    );
  });
  test(
    'legacy pin colours are unique beyond the palette and independent of list order',
    () {
      final rows = List.generate(
        30,
        (i) => <String, dynamic>{'id': 'place-$i', 'data': <String, dynamic>{}},
      );
      final colors = resolvePlaceColors(rows);
      expect(colors.values.toSet(), hasLength(30));
      expect(resolvePlaceColors(rows.reversed.toList()), colors);
    },
  );
}
