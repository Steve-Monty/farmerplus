import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:farmerplus_mobile/settings.dart';
import 'package:farmerplus_mobile/community.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/services.dart';
import 'package:farmerplus_mobile/ui.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/main.dart' show HomePage;
import 'package:farmerplus_mobile/miniapps.dart' show AppStorePage;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async {
    final font = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  late FarmStore store;
  late Directory dir;
  late SyncEngine sync;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (_) async => ['none'],
        );
    dir = await Directory.systemTemp.createTemp('settings-profile-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    sync = SyncEngine(store);
    await store.setSetting('gpsCountry', 'South Africa');
    await store.setSetting('accountName', 'farmer.test');
    await store.setSetting('primaryActivity', 'Maize');
    await store.setSetting('areaUnit', 'ha');
  });
  tearDown(() async {
    sync.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });

  Widget app(
    Widget child, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: farmTheme(brightness),
    builder: (c, w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: w!,
    ),
    home: child,
  );

  testWidgets('shared design fits narrow screens and exports review evidence', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(391, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final entry in <String, Widget>{
      'home': HomePage(store: store, sync: sync, reminders: Reminders()),
      'settings': SettingsPage(
        store: store,
        sync: sync,
        reminders: Reminders(),
      ),
      'app-store': AppStorePage(store: store, onOpen: (_) {}),
    }.entries) {
      final key = GlobalKey();
      await tester.pumpWidget(
        app(RepaintBoundary(key: key, child: entry.value)),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('docs/evidence/app-design-20260929')
          ..createSync(recursive: true);
        await File(
          '${folder.path}/${entry.key}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    }
  });

  testWidgets(
    'profile draft restores every field and preferences apply only on Save',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(ProfilePage(store: store)));
      await settle(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'New farmer');
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last,
      );
      dropdown.onChanged!('ac');
      await settle(tester);
      expect(await tester.runAsync(() => store.setting('areaUnit')), 'ha');
      expect(await tester.runAsync(() => store.records('profile')), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pumpWidget(app(ProfilePage(store: store)));
      await settle(tester);
      expect(find.text('New farmer'), findsOneWidget);
      expect(find.text('Email address (optional)'), findsNothing);
      expect(
        find.text('Your unsaved draft has been restored.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Save changes'));
      await settle(tester);
      final rows = await tester.runAsync(() => store.records('profile'));
      expect(rows!.single['data']['name'], 'New farmer');
      expect(rows.single['data']['primaryActivity'], 'Maize');
      expect(await tester.runAsync(() => store.setting('areaUnit')), 'ac');
      expect(
        await tester.runAsync(() => store.setting('profileDraft')),
        isNull,
      );
      expect(find.text('Saved on this phone'), findsOneWidget);
      expect(find.text('Profile waiting to sync'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    },
  );

  testWidgets('profile keeps a previously saved email without editing it', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.save('profile', {
        'email': 'existing@example.test',
        'name': 'Existing farmer',
      }),
    );
    await tester.pumpWidget(app(ProfilePage(store: store)));
    await settle(tester);
    expect(find.text('Email address (optional)'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'Updated farmer');
    await settle(tester);
    await tester.tap(find.text('Save changes'));
    await settle(tester);
    final records = await tester.runAsync(() => store.records('profile'));
    expect(records!.single['data']['email'], 'existing@example.test');
    expect(records.single['data']['name'], 'Updated farmer');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('cooperative disclosure Cancel never approves sharing', (
    tester,
  ) async {
    bool? accepted;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () async {
                accepted = await reviewSharing(c, {
                  'name': 'Example cooperative',
                  'purpose': 'Membership services',
                  'category': 'cooperatives',
                  'fields': ['name', 'country'],
                });
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Preferred name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });

  testWidgets(
    'Settings logout confirms and preserves pending records on cancel',
    (tester) async {
      await tester.runAsync(() => store.save('profile', {'name': 'Kept'}));
      await tester.pumpWidget(
        app(SettingsPage(store: store, sync: sync, reminders: Reminders())),
      );
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Log out'), 250);
      await settle(tester);
      await tester.ensureVisible(find.text('Log out'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await settle(tester);
      expect(find.text('Log out with unsynced changes?'), findsOneWidget);
      await tester.tap(find.text('Stay signed in'));
      await settle(tester);
      expect(
        (await tester.runAsync(
          () => store.records('profile'),
        ))!.single['data']['name'],
        'Kept',
      );
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    },
  );

  for (final variant in [
    'profile',
    'profile-dark',
    'profile-large',
    'settings',
    'sharing',
    'home',
  ]) {
    testWidgets('$variant renders at phone size without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = Size(
        variant == 'profile-large' ? 320 : 390,
        844,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (variant == 'sharing') {
        await tester.runAsync(
          () => store.install(catalogue.firstWhere((a) => a.id == 'coop')),
        );
      }
      final service = CommunityService(store, sync);
      final boundary = GlobalKey();
      final page = variant == 'home'
          ? HomePage(store: store, sync: sync, reminders: Reminders())
          : variant == 'settings'
          ? SettingsPage(store: store, sync: sync, reminders: Reminders())
          : variant == 'sharing'
          ? PageFrame(
              'Data sharing',
              children: [
                ShareDataSettings(service: service, onManageCoop: () {}),
              ],
            )
          : ProfilePage(store: store);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: app(
            page,
            brightness: variant == 'profile-dark'
                ? Brightness.dark
                : Brightness.light,
            scale: variant == 'profile-large' ? 1.6 : 1,
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      if (variant == 'home') {
        expect(find.byTooltip('Log out'), findsOneWidget);
        await tester.tap(find.byTooltip('Log out'));
        await settle(tester);
        expect(find.text('Log out with unsynced changes?'), findsOneWidget);
        await tester.tap(find.text('Stay signed in'));
        await settle(tester);
      }
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          '../artifacts/settings-profile-20260916/$variant.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.drag(find.byType(ListView).first, const Offset(0, -1100));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      service.dispose();
      AccountAccess.unlocked.value = null;
    });
  }
}
