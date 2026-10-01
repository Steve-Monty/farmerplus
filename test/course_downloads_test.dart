import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/course_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  late CourseDownloads manager;
  late Map<String, dynamic> manifest;
  late List<int> body;
  late List<int> offsets;
  late List<ConnectivityResult> networks;
  bool corrupt = false;
  int? failAt;
  Future<void> settle() async {
    for (var i = 0; i < 1000; i++) {
      if (!manager.running) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Download worker did not finish');
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('course-download-qa-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    await store.setSetting('studentId', '0123456789abcdef0123456789abcdef');
    await store.setSetting('boundServer', 'https://app.agritec.earth');
    body = utf8.encode('reading ' * 12000);
    offsets = [];
    networks = [ConnectivityResult.wifi];
    corrupt = false;
    failAt = null;
    manifest = {
      'schema': 1,
      'courseid': 10,
      'name': 'Reading course',
      'farmerplus_id': '0123456789abcdef0123456789abcdef',
      'tenant_id': 'farmerplus',
      'instance_id': 'farmerplus-learning',
      'learning_origin': 'https://learn.agritec.earth',
      'offline_enabled': true,
      'version': 'a' * 64,
      'activities': [
        {
          'id': 35,
          'name': 'Lesson',
          'offline': true,
          'format': 'text/html',
          'bytes': body.length,
          'sha256': sha256.convert(body).toString(),
          'section_id': 0,
          'type': 'page',
        },
        {'id': 32, 'name': 'Assessment', 'offline': false, 'type': 'h5p'},
      ],
    };
    manager = CourseDownloads(
      store,
      connectivity: () async => networks,
      requester: (route) async {
        if (route.contains('/manifest/')) return manifest;
        final uri = Uri.parse(route);
        final offset = int.parse(uri.queryParameters['offset']!);
        offsets.add(offset);
        if (offset == failAt) throw const SocketException('interrupted');
        final data = body.sublist(offset, min(offset + 65536, body.length));
        if (corrupt) data[0] ^= 1;
        return {
          'cmid': 35,
          'sha256': manifest['activities'][0]['sha256'],
          'offset': offset,
          'total': body.length,
          'data': base64Encode(data),
        };
      },
    );
  });
  tearDown(() async {
    await settle();
    manager.dispose();
    await store.db.close();
    await dir.delete(recursive: true);
  });
  test(
    'downloads missing chunks, verifies, avoids repeat transfers and labels partial',
    () async {
      await manager.manifest(10);
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      var s = (await manager.state(10))!;
      expect(s['state'], 'complete');
      expect(offsets, [0, 65536]);
      expect(CourseDownloads.label(s), 'Partly downloaded — 1 of 2 lessons');
      final file = File(s['installed']['35']['path']);
      expect(await file.readAsBytes(), body);
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      expect(offsets.length, 2);
    },
  );
  test(
    'interrupted chunks resume at durable offset and retain old version on failed update',
    () async {
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      final original = (await manager.state(10))!['installed']['35']['path'];
      body = utf8.encode('changed ' * 12000);
      manifest = {
        ...manifest,
        'version': 'b' * 64,
        'activities': [
          {
            ...manifest['activities'][0],
            'bytes': body.length,
            'sha256': sha256.convert(body).toString(),
          },
          manifest['activities'][1],
        ],
      };
      failAt = 65536;
      offsets.clear();
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      expect((await manager.state(10))!['state'], 'waitingConnection');
      expect((await manager.state(10))!['installed']['35']['path'], original);
      failAt = null;
      corrupt = true;
      await manager.pump();
      expect((await manager.state(10))!['state'], 'paused');
      expect(await File(original).exists(), true);
      expect(offsets, [0, 65536, 65536]);
      expect((await manager.state(10))!['installed']['35']['path'], original);
      corrupt = false;
      await manager.command(10, 'queued');
      await settle();
      expect((await manager.state(10))!['state'], 'complete');
      expect(await File(original).exists(), true);
    },
  );
  test(
    'Wi-Fi default waits; mobile permission resumes; removal preserves progress and purchases',
    () async {
      networks = [ConnectivityResult.mobile];
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      expect((await manager.state(10))!['state'], 'waitingWifi');
      expect(offsets, isEmpty);
      await manager.allowMobile(10);
      await settle();
      expect((await manager.state(10))!['state'], 'complete');
      await store.setSetting('purchase:10', 'receipt');
      await store.setSetting('progress:10', {'pending': true});
      await manager.remove(10, resources: {35});
      expect((await manager.state(10))!['installed'], isEmpty);
      expect(await store.setting('purchase:10'), 'receipt');
      expect(await store.setting('progress:10'), {'pending': true});
    },
  );
  test(
    'completed partial survives crash and is committed without a network read',
    () async {
      networks = [ConnectivityResult.none];
      await manager.enqueue(10, manifest, {35}, availableBytes: 100000000);
      await settle();
      final folder = Directory(
        '${dir.path}/learning/${await manager.binding()}/10/${manifest['version']}',
      );
      await folder.create(recursive: true);
      await File(
        '${folder.path}/35-${manifest['activities'][0]['sha256']}.html.part',
      ).writeAsBytes(body);
      networks = [ConnectivityResult.wifi];
      await manager.pump();
      expect((await manager.state(10))!['state'], 'complete');
      expect(offsets, isEmpty);
    },
  );
  test('storage checks and account binding reject unsafe enqueue', () async {
    await expectLater(
      manager.enqueue(10, manifest, {35}, availableBytes: 100),
      throwsStateError,
    );
    await store.setSetting('studentId', 'f' * 32);
    expect(await manager.state(10), isNull);
    await expectLater(
      manager.enqueue(10, manifest, {35}, availableBytes: 100000000),
      throwsStateError,
    );
  });
}
