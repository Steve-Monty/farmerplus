import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/store.dart';

List<GeoPoint> points(List<List<num>> xy) => xy
    .map((p) => GeoPoint(p[1].toDouble() * .001, p[0].toDouble() * .001))
    .toList();
Map<String, dynamic> shape(List<GeoPoint> p, {String? farm}) => {
  'name': 'Geometry test',
  'points': p.map((p) => p.toJson()).toList(),
  if (farm != null) 'farmId': farm,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final farm = points([
    [0, 0],
    [4, 0],
    [4, 4],
    [3, 4],
    [3, 1],
    [1, 1],
    [1, 4],
    [0, 4],
  ]);
  final contained = points([
    [0, 0],
    [1, 0],
    [1, 1],
    [0, 1],
  ]);
  final bridge = points([
    [.5, 2],
    [3.5, 2],
    [3.5, 3],
    [.5, 3],
  ]);
  test(
    'Concave edge crossing rejected even when all vertices are inside; border contact allowed',
    () {
      expect(validateContainment(farm, contained), isNull);
      expect(validateContainment(farm, bridge), contains('edge'));
      expect(
        validateContainment(
          farm,
          points([
            [5, 0],
            [6, 0],
            [6, 1],
          ]),
        ),
        isNotNull,
      );
      expect(
        validateContainment(farm, [
          contained[0],
          contained[2],
          contained[1],
          contained[3],
        ]),
        isNotNull,
      );
      expect(validateContainment(farm, farm.reversed.toList()), isNull);
    },
  );
  test(
    'Persistence, parent edits, orphan writes and incoming conflicts enforce containment',
    () async {
      final dir = await Directory.systemTemp.createTemp('containment_');
      var store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      try {
        final id = await store.save('farm', shape(farm));
        final field = await store.save('field', shape(contained, farm: id));
        await expectLater(
          store.save('field', shape(bridge, farm: id)),
          throwsStateError,
        );
        await expectLater(
          store.save('field', shape(contained, farm: 'absent')),
          throwsStateError,
        );
        await expectLater(
          store.save(
            'farm',
            shape(
              points([
                [2, 0],
                [4, 0],
                [4, 1],
                [2, 1],
              ]),
            ),
            id: id,
          ),
          throwsStateError,
        );
        await expectLater(
          store.save('farm', shape(farm), id: id, deleted: true),
          throwsStateError,
        );
        await store.close();
        store = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: dir.path,
        );
        expect((await store.records('field')).single['id'], field);
        await store.incoming({
          'id': 'remote-field',
          'kind': 'field',
          'data': shape(bridge, farm: id),
          'version': 1,
          'deleted': false,
          'updated': DateTime.now().toIso8601String(),
        });
        expect(await store.get('remote-field'), isNull);
        expect(await store.db.query('conflicts'), hasLength(1));
        await expectLater(
          store.resolve('remote-field', keepLocal: false),
          throwsStateError,
        );
        expect(await store.db.query('conflicts'), hasLength(1));
        expect(await store.geometryIssue((await store.get(field))!), isNull);
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
