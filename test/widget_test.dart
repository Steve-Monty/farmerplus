import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/main.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/services.dart';
import 'package:farmerplus_mobile/ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  testWidgets(
    'four columns, protected apps and accessible reorder at phone sizes',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (_) async => ['wifi'],
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        (_) async => null,
      );
      FlutterSecureStorage.setMockInitialValues({});
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('farmer_launcher_'),
      ))!;
      final store = (await tester.runAsync(
        () => FarmStore.open(
          factory: databaseFactoryFfiNoIsolate,
          filesPath: dir.path,
        ),
      ))!;
      final sync = SyncEngine(store);
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 180)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }

      await tester.runAsync(
        () => store.setSetting(
          'weatherLastAttempt:v2:weather:current:current',
          DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          theme: farmTheme(),
          home: HomePage(store: store, sync: sync, reminders: Reminders()),
        ),
      );
      await settle();
      for (final name in ['App Store', 'Learning']) {
        expect(find.text(name), findsOneWidget);
      }
      for (final name in ['My Farm', 'Inbox', 'Wallet', 'Settings']) {
        expect(find.byTooltip(name), findsOneWidget);
      }
      expect(find.text('My Wallet'), findsNothing);
      expect(find.byTooltip('Home actions'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester.getTopLeft(find.text('App Store')).dy,
        tester.getTopLeft(find.text('Learning')).dy,
      );
      await tester.binding.setSurfaceSize(const Size(320, 740));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      await settle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('App Store'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await settle();
      final narrowRow = [
        'App Store',
        'Learning',
      ].map((name) => tester.getTopLeft(find.text(name)).dy).toSet();
      expect(narrowRow.length, 1);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.runAsync(() async {
        await store.db.close();
        await dir.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    },
  );
}
