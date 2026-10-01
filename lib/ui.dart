import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

const paper = Color(0xfff4f8fb),
    ink = Color(0xff102e43),
    green = Color(0xff5636d1);
ThemeData farmTheme([Brightness brightness = Brightness.light]) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: green,
        brightness: brightness,
        surface: brightness == Brightness.light
            ? paper
            : const Color(0xff111a33),
      ).copyWith(
        primary: green,
        onPrimary: Colors.white,
        onSurface: brightness == Brightness.light ? ink : Colors.white,
        onSurfaceVariant: brightness == Brightness.light
            ? const Color(0xff566780)
            : const Color(0xffc2cbdc),
        outline: const Color(0xffb0bbce),
        primaryContainer: const Color(0xffede6ff),
      );
  return ThemeData(
    fontFamily: 'Roboto',
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xffe4edf4)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xffdce6ed), space: 28),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xffedf1f7),
      selectedColor: const Color(0xffefe8ff),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontSize: 29,
        fontWeight: FontWeight.w800,
        letterSpacing: -.7,
      ),
      titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 76,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xfff9fbff),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
  );
}

class PageFrame extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? bottom;
  final bool showArtwork;
  const PageFrame(
    this.title, {
    super.key,
    required this.children,
    this.actions,
    this.bottom,
    this.showArtwork = true,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: Navigator.of(context).canPop()
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: IconButton.filledTonal(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            )
          : null,
      title: Row(
        children: [
          if (showArtwork) ...[
            AppArtwork(id: artworkId(title), size: 40),
            const SizedBox(width: 12),
          ],
          Flexible(child: Text(title)),
        ],
      ),
      actions: [
        ...?actions,
        IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ],
    ),
    body: ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(
        dragDevices: PointerDeviceKind.values.toSet(),
      ),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: children
                  .map(
                    (child) =>
                        child is ListTile ? SurfaceCard(child: child) : child,
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    ),
    bottomNavigationBar: bottom,
  );
}

Widget heading(BuildContext c, String text) => Padding(
  padding: const EdgeInsets.only(top: 24, bottom: 12),
  child: Text(text, style: Theme.of(c).textTheme.titleLarge),
);
Widget note(String text, {IconData icon = Icons.info_outline}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 22),
      const SizedBox(width: 12),
      Expanded(child: Text(text)),
    ],
  ),
);
Widget gap([double height = 16]) => SizedBox(height: height);
Future<void> guarded(BuildContext c, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Bad state: ', '')),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }
}

Future<void> openPage(BuildContext c, Widget page) async {
  await Navigator.of(c).push(MaterialPageRoute(builder: (_) => page));
}

String stamp(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '');
  if (date == null) return 'Never';
  final d = date.toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String artworkId(String title) => title.toLowerCase().contains('stock')
    ? 'stock'
    : title.toLowerCase().contains('harvest')
    ? 'harvest'
    : title.toLowerCase().contains('diary')
    ? 'diary'
    : title.toLowerCase().contains('planner')
    ? 'planner'
    : title.toLowerCase().contains('calculator')
    ? 'calculator'
    : title.toLowerCase().contains('guide')
    ? 'guides'
    : title.toLowerCase().contains('coop')
    ? 'coop'
    : title.toLowerCase().contains('animal')
    ? 'my-animals'
    : title.toLowerCase().contains('farm') ||
          title.toLowerCase().contains('field')
    ? 'farm'
    : title.toLowerCase().contains('learn') ||
          title.toLowerCase().contains('course')
    ? 'learning'
    : title.toLowerCase().contains('wallet')
    ? 'wallet'
    : title.toLowerCase().contains('inbox')
    ? 'inbox'
    : title.toLowerCase().contains('store')
    ? 'store'
    : 'settings';

class AppArtwork extends StatelessWidget {
  final String id;
  final double size;
  const AppArtwork({super.key, required this.id, this.size = 76});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
        child: Image.asset(
          'assets/app-icons/${id == 'my-animals' ? 'animals' : id}.png',
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) => CustomPaint(painter: _AppPainter(id)),
        ),
    ),
  );
}

class _AppPainter extends CustomPainter {
  final String id;
  _AppPainter(this.id);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 80, size.height / 80);
    final palettes = <String, List<Color>>{
      'store': [const Color(0xff09d4ff), const Color(0xff0864ee)],
      'farm': [const Color(0xff03ab83), const Color(0xff007e9b)],
      'wallet': [const Color(0xff7d92ff), const Color(0xff5b24e9)],
      'inbox': [const Color(0xffffac94), const Color(0xffff365d)],
      'learning': [const Color(0xffda63ff), const Color(0xff8300d8)],
      'settings': [const Color(0xffa6accf), const Color(0xff4c5c89)],
      'diary': [const Color(0xff00a4bd), const Color(0xff0074bf)],
      'planner': [const Color(0xfff24569), const Color(0xffbd35a7)],
      'calculator': [const Color(0xffffaa17), const Color(0xffef6533)],
      'stock': [const Color(0xffb77712), const Color(0xff805320)],
      'harvest': [const Color(0xff5d961e), const Color(0xff19735d)],
      'guides': [const Color(0xff187e96), const Color(0xff284876)],
    };
    final colors =
        palettes[id] ?? [const Color(0xff426ce8), const Color(0xff283970)];
    final rect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 80, 80),
      const Radius.circular(23),
    );
    canvas.drawShadow(
      Path()..addRRect(rect),
      Colors.black.withValues(alpha: .4),
      5,
      true,
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(const Rect.fromLTWH(0, 0, 80, 80)),
    );
    canvas.drawRRect(
      rect.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: .7),
    );
    canvas.clipRRect(rect);
    canvas.drawCircle(
      const Offset(72, 3),
      34,
      Paint()..color = Colors.white.withValues(alpha: .12),
    );
    void box(double x, double y, double w, double h, Color c, [double r = 5]) {
      final shape = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, h),
        Radius.circular(r),
      );
      canvas.drawShadow(
        Path()..addRRect(shape),
        Colors.black.withValues(alpha: .28),
        2,
        true,
      );
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(c, Colors.white, .30)!,
              c,
              Color.lerp(c, Colors.black, .12)!,
            ],
          ).createShader(shape.outerRect),
      );
      canvas.drawRRect(
        shape.deflate(.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7
          ..color = Colors.white.withValues(alpha: .55),
      );
    }

    void path(List<Offset> points, Color c) {
      final p = Path()..addPolygon(points, true);
      canvas.drawPath(p, Paint()..color = c);
    }

    const white = Color(0xffffffff),
        yellow = Color(0xffffdf53),
        mint = Color(0xff78f2bd),
        pink = Color(0xffff91cc);
    if (id == 'settings') {
      canvas.save();
      canvas.translate(40, 40);
      for (var i = 0; i < 8; i++) {
        canvas.rotate(0.7853981634);
        box(-5, -29, 10, 16, const Color(0xffdce7ed), 3);
      }
      canvas.drawCircle(
        Offset.zero,
        23,
        Paint()..color = const Color(0xffdce7ed),
      );
      canvas.drawCircle(
        Offset.zero,
        12,
        Paint()..color = const Color(0xff536d83),
      );
      canvas.drawCircle(
        Offset.zero,
        7,
        Paint()..color = const Color(0xffb8d4e5),
      );
      canvas.restore();
    } else if (id == 'coop') {
      for (final x in [22.0, 40.0, 58.0]) {
        canvas.drawCircle(
          Offset(x, x == 40 ? 25 : 32),
          7,
          Paint()..color = white,
        );
        box(x - 8, x == 40 ? 35 : 42, 16, 19, white, 8);
      }
      path([
        const Offset(40, 66),
        const Offset(27, 57),
        const Offset(40, 51),
        const Offset(53, 57),
      ], mint);
    } else if (id == 'my-animals') {
      path([
        const Offset(22, 32),
        const Offset(13, 18),
        const Offset(31, 25),
        const Offset(49, 25),
        const Offset(67, 18),
        const Offset(58, 32),
        const Offset(54, 55),
        const Offset(47, 65),
        const Offset(33, 65),
        const Offset(26, 55),
      ], white);
      box(29, 45, 22, 16, mint, 7);
      canvas.drawCircle(
        const Offset(31, 36),
        2.5,
        Paint()..color = colors.last,
      );
      canvas.drawCircle(
        const Offset(49, 36),
        2.5,
        Paint()..color = colors.last,
      );
      canvas.drawCircle(const Offset(35, 53), 2, Paint()..color = colors.last);
      canvas.drawCircle(const Offset(45, 53), 2, Paint()..color = colors.last);
    } else if (id == 'store') {
      final stroke = Paint()
        ..color = white
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(28, 59), const Offset(48, 23), stroke);
      canvas.drawLine(const Offset(32, 23), const Offset(53, 59), stroke);
      canvas.drawLine(const Offset(20, 49), const Offset(60, 49), stroke);
    } else if (id == 'farm') {
      final stroke = Paint()
        ..color = white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(
        Path()
          ..moveTo(16, 39)
          ..lineTo(38, 21)
          ..lineTo(61, 39),
        stroke,
      );
      box(24, 39, 29, 23, white, 2);
      box(35, 47, 9, 15, colors.last, 1);
      canvas.drawPath(
        Path()
          ..moveTo(49, 29)
          ..quadraticBezierTo(46, 15, 64, 15)
          ..quadraticBezierTo(66, 29, 49, 29),
        Paint()..color = mint,
      );
    } else if (id == 'wallet') {
      canvas.save();
      canvas.translate(40, 30);
      canvas.rotate(-.15);
      box(-20, -8, 40, 21, yellow, 4);
      canvas.restore();
      box(18, 29, 45, 34, white, 6);
      box(48, 39, 20, 15, const Color(0xffb6c5ff), 5);
      canvas.drawCircle(
        const Offset(55, 46),
        2.5,
        Paint()..color = colors.last,
      );
    } else if (id == 'inbox') {
      canvas.drawCircle(const Offset(40, 37), 24, Paint()..color = white);
      path([
        const Offset(20, 48),
        const Offset(16, 65),
        const Offset(34, 57),
      ], white);
      final handset = Paint()
        ..color = const Color(0xffff5670)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(
        Path()
          ..moveTo(31, 27)
          ..cubicTo(26, 38, 40, 51, 50, 47),
        handset,
      );
      canvas.drawLine(const Offset(30, 26), const Offset(34, 31), handset);
      canvas.drawLine(const Offset(46, 43), const Offset(51, 47), handset);
    } else if (id == 'learning') {
      canvas.drawPath(
        Path()
          ..moveTo(39, 27)
          ..quadraticBezierTo(25, 18, 16, 25)
          ..lineTo(16, 57)
          ..quadraticBezierTo(29, 52, 39, 64)
          ..close(),
        Paint()..color = white,
      );
      canvas.drawPath(
        Path()
          ..moveTo(43, 27)
          ..quadraticBezierTo(55, 18, 65, 25)
          ..lineTo(65, 57)
          ..quadraticBezierTo(53, 52, 43, 64)
          ..close(),
        Paint()..color = white,
      );
    } else if (id == 'planner') {
      box(18, 21, 44, 43, white, 7);
      box(18, 21, 44, 12, yellow, 5);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          box(
            25 + x * 11.0,
            39 + y * 11.0,
            6,
            6,
            x == 1 && y == 0 ? colors.first : const Color(0xffb7c5ff),
            2,
          );
        }
      }
    } else if (id == 'diary') {
      box(21, 15, 39, 51, white, 5);
      box(17, 15, 9, 51, yellow, 3);
      for (var i = 0; i < 3; i++) {
        box(32, 28 + i * 10.0, 20, 3, const Color(0xff89b8dd), 1);
      }
      canvas.save();
      canvas.translate(56, 44);
      canvas.rotate(.5);
      box(-3, -8, 7, 29, pink, 2);
      canvas.restore();
    } else if (id == 'stock') {
      box(17, 35, 46, 30, white, 4);
      box(15, 29, 50, 10, yellow, 2);
      box(35, 29, 10, 22, colors.last, 1);
      box(28, 14, 25, 12, mint, 3);
    } else if (id == 'harvest') {
      box(18, 40, 45, 25, yellow, 5);
      canvas.drawCircle(const Offset(30, 36), 11, Paint()..color = white);
      canvas.drawCircle(const Offset(50, 34), 12, Paint()..color = mint);
      box(38, 15, 4, 16, white, 2);
      box(21, 48, 39, 3, colors.last, 1);
    } else if (id == 'guides') {
      box(16, 20, 22, 40, white, 4);
      box(42, 20, 22, 40, white, 4);
      for (var y = 0; y < 3; y++) {
        box(21, 30 + y * 8.0, 12, 2, colors.first, 1);
        box(47, 30 + y * 8.0, 12, 2, colors.first, 1);
      }
      box(37, 22, 6, 42, yellow, 2);
    } else if (id == 'calculator') {
      box(21, 13, 39, 55, white, 7);
      box(27, 20, 27, 13, colors.last, 3);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          box(
            27 + x * 10.0,
            41 + y * 11.0,
            6,
            6,
            x == 2 ? colors.first : const Color(0xffbecbdf),
            2,
          );
        }
      }
    } else {
      canvas.drawCircle(const Offset(40, 40), 22, Paint()..color = white);
      canvas.drawCircle(const Offset(40, 40), 10, Paint()..color = mint);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 3, 74, 37),
        const Radius.circular(20),
      ),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: .25),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(const Rect.fromLTWH(3, 3, 74, 37)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppPainter old) => old.id != id;
}

/// Shared opaque reading surface; glass stays on wallpaper/navigation.
class SurfaceCard extends StatelessWidget {
  final Widget child;
  const SurfaceCard({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0b244971),
          blurRadius: 24,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xffe4edf4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

class AppBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool accent;
  const AppBadge(this.label, this.icon, {super.key, this.accent = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: accent ? const Color(0xfff0e9ff) : const Color(0xffeff3f8),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: accent ? green : ink),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: accent ? green : ink),
        ),
      ],
    ),
  );
}
