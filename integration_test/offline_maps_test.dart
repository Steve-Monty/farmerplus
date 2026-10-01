import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/farm.dart';
import 'package:farmerplus_mobile/map_downloads.dart';
import 'package:farmerplus_mobile/farm_details.dart';
import 'package:farmerplus_mobile/ui.dart';
import 'package:farmerplus_mobile/domain.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native offline polygons sync create and edit, and local PMTiles renders',
    (tester) async {
      HttpOverrides.global = null;
      final dir = await Directory.systemTemp.createTemp('farmer-mapping-qa-');
      var store = await FarmStore.open(filesPath: dir.path);
      final farmPoints = [
        {'lat': -29.792, 'lon': 30.898},
        {'lat': -29.792, 'lon': 30.904},
        {'lat': -29.787, 'lon': 30.904},
        {'lat': -29.787, 'lon': 30.898},
      ];
      final areaPoints = [
        {'lat': -29.791, 'lon': 30.899},
        {'lat': -29.791, 'lon': 30.901},
        {'lat': -29.789, 'lon': 30.901},
        {'lat': -29.789, 'lon': 30.899},
      ];
      final farm = await store.save('farm', {
        'name': 'QA farm · synthetic',
        'points': farmPoints,
      });
      final area = await store.save('field', {
        'name': 'QA paddock',
        'farmId': farm,
        'points': areaPoints,
      });
      final unmapped = await store.save('field', {
        'name': 'Map later',
        'farmId': farm,
        'points': [],
      });
      expect(await store.db.query('queue'), hasLength(3));
      await store.close();
      store = await FarmStore.open(filesPath: dir.path);
      expect((await store.get(unmapped))!['data']['points'], isEmpty);
      const base = 'http://10.0.2.2:8089';
      await store.setSetting('server', base);
      await store.setSetting('boundServer', base);
      await store.setSetting('consent', true);
      final credentials = {
        'username': 'qa_${uuid.v4().substring(0, 12)}',
        'password': 'Local-QA-${uuid.v4()}',
      };
      final client = http.Client();
      final registered = await client.post(
        Uri.parse('$base/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(credentials),
      );
      expect(registered.statusCode, 201);
      final login = await client.post(
        Uri.parse('$base/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(credentials),
      );
      final token = jsonDecode(login.body)['token'] as String;
      final sync = SyncEngine(store)..token = token;
      await sync.sync();
      expect(sync.failures, 0, reason: sync.status);
      expect(await store.db.query('queue'), isEmpty);
      Future<Map<String, dynamic>> world() async => jsonDecode(
        (await client.get(
          Uri.parse('$base/map/geojson'),
          headers: {'Authorization': 'Bearer $token'},
        )).body,
      );
      expect((await world())['features'], hasLength(2));
      areaPoints[1] = {'lat': -29.791, 'lon': 30.902};
      await store.save('field', {
        'name': 'QA paddock updated',
        'farmId': farm,
        'points': areaPoints,
      }, id: area);
      expect(await store.db.query('queue'), hasLength(1));
      await sync.sync();
      expect(sync.failures, 0, reason: sync.status);
      final feature = ((await world())['features'] as List).firstWhere(
        (r) => r['id'] == area,
      );
      expect(feature['properties']['version'], 2);
      expect(feature['geometry']['coordinates'][0][1], [30.902, -29.791]);

      const mapBase = 'http://10.0.2.2:8088';
      final job = jsonDecode(
        (await client.get(
          Uri.parse('$mapBase/jobs/8007ba4896d6300e0f57be74b68f1271'),
        )).body,
      );
      expect(job['state'], 'ready');
      final bytes = (await client.get(
        Uri.parse('$mapBase/files/${job['id']}'),
      )).bodyBytes;
      expect(sha256.convert(bytes).toString(), job['sha256']);
      final maps = await Directory('${dir.path}/maps').create();
      final pack = File('${maps.path}/${job['id']}.pmtiles');
      await pack.writeAsBytes(bytes, flush: true);
      await store.setSetting('downloadedMapPacks', [
        {...job, 'path': pack.path, 'name': 'QA test pack', 'farmId': farm},
      ]);
      await store.setSetting('activeMapPack', job['id']);
      final style = await MapPacks(store).activeStyle();
      expect(style, contains('pmtiles://file://'));
      await tester.pumpWidget(
        MaterialApp(
          theme: farmTheme(),
          home: BoundaryPage(
            store: store,
            kind: 'field',
            farmId: farm,
            record: await store.get(area),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Standard · downloaded'), findsOneWidget);
      expect(find.text('Save boundary'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final handle = find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.grab,
      );
      expect(handle, findsNWidgets(4));
      final before = polygonPoints((await store.get(area))!['data']);
      await tester.timedDrag(
        handle.at(2),
        const Offset(-12, -8),
        const Duration(milliseconds: 800),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byTooltip('Undo'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump(const Duration(seconds: 1));
      final dynamic editor = tester.state(find.byType(BoundaryPage));
      await editor.paint();
      expect(
        (editor.map as dynamic).lines.last.options.geometry.length,
        before.length + 1,
      );
      final draft = await store.setting('boundaryDraft:$area:field');
      expect(
        polygonPoints(
          Map<String, dynamic>.from(draft),
        ).map((p) => p.toJson()).toList(),
        before.map((p) => p.toJson()).toList(),
      );
      if (Platform.isAndroid) {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        await binding.convertFlutterSurfaceToImage();
        await tester.pump(const Duration(seconds: 1));
        final screen = await binding.takeScreenshot('offline-boundary');
        await File('${dir.path}/offline-boundary.png').writeAsBytes(screen);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: farmTheme(),
          home: FarmDetailsPage(store: store, kind: 'field', farmId: farm),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Save details'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      sync.dispose();
      client.close();
      await store.close();
      // Keep only synthetic QA artifacts for visual inspection; never touches the user's app database.
      debugPrint('QA_ARTIFACT_DIRECTORY=${dir.path}');
    },
  );
}
