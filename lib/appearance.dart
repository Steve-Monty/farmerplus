import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'store.dart';
import 'ui.dart' show guarded;

class Wallpaper {
  static Future<bool> pick(FarmStore store) async {
    Uint8List? bytes;
    if (kIsWeb) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      bytes = result?.files.single.bytes;
    } else {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 2400,
        imageQuality: 88,
      );
      bytes = await picked?.readAsBytes();
    }
    if (bytes == null) return false;
    await save(store, bytes);
    return true;
  }

  static Future<void> save(FarmStore store, Uint8List bytes) async {
    if (bytes.length > 8 * 1024 * 1024) {
      throw StateError('Choose a photo smaller than 8 MB.');
    }
    try {
      final codec = await instantiateImageCodec(bytes, targetWidth: 1200);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
    } catch (_) {
      throw StateError('This file is not a supported photo.');
    }
    // Settings stay local. They are never part of record/media sync.
    await store.setSetting('wallpaperPhoto', base64Encode(bytes));
  }

  static Future<void> reset(FarmStore store) =>
      store.setSetting('wallpaperPhoto', null);
}

class FarmBackdrop extends StatelessWidget {
  final double? glassOpacity;
  final String? photo;
  final String preset;
  final Widget child;
  const FarmBackdrop({
    super.key,
    this.glassOpacity,
    this.photo,
    this.preset = 'fields',
    required this.child,
  });
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: preset == 'none'
              ? const ColoredBox(color: Color(0xffe9eee6))
              : preset == 'fields' || preset == 'photo'
              ? Image(
                  image: preset == 'photo' && photo != null
                      ? MemoryImage(base64Decode(photo!)) as ImageProvider
                      : const AssetImage('assets/branding/farm-wallpaper.png'),
                  fit: BoxFit.cover,
                )
              : Image.asset(
                  'assets/wallpapers/${wallpaperChoices.containsKey(preset) ? preset : 'orchard'}.png',
                  fit: BoxFit.cover,
                  cacheWidth: 1024,
                  excludeFromSemantics: true,
                ),
        ),
      ),
      glassOpacity == null
          ? child
          : HomeGlassOpacity(opacity: glassOpacity!, child: child),
    ],
  );
}

const wallpaperChoices = <String, String>{
  'none': 'None',
  'fields': 'Green Fields',
  'orchard': 'Orchard',
  'mountains': 'Mountains',
  'sunrise': 'Sunrise',
  'botanical': 'Soft Botanical',
};

/// Original vector backgrounds: bundled in the app, no network or storage pack.
class LandscapeWallpaper extends CustomPainter {
  final String preset;
  const LandscapeWallpaper(this.preset);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 400, size.height / 800);
    const rect = Rect.fromLTWH(0, 0, 400, 800);
    final sunrise = preset == 'sunrise';
    final botanical = preset == 'botanical';
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: botanical
              ? [const Color(0xffc6d2bd), const Color(0xff637e66)]
              : sunrise
              ? [
                  const Color(0xff8babb0),
                  const Color(0xffefc28c),
                  const Color(0xff70876e),
                ]
              : [
                  const Color(0xffabcbd0),
                  const Color(0xffd8dfc1),
                  const Color(0xff527265),
                ],
        ).createShader(rect),
    );
    if (botanical) {
      for (var stem = 0; stem < 7; stem++) {
        canvas.save();
        canvas.translate(stem * 85 - 90, 870 - (stem % 3) * 90);
        canvas.rotate((stem.isEven ? 1 : -1) * .35);
        final paint = Paint()
          ..color = Color(stem.isEven ? 0x40506d55 : 0x557f986d);
        canvas.drawLine(
          Offset.zero,
          const Offset(0, -670),
          Paint()
            ..color = const Color(0x55708869)
            ..strokeWidth = 3,
        );
        for (var leaf = 1; leaf < 10; leaf++) {
          for (final side in [-1.0, 1.0]) {
            canvas.save();
            canvas.translate(0, -leaf * 65);
            canvas.rotate(side * .75);
            canvas.drawOval(const Rect.fromLTWH(-19, -100, 38, 106), paint);
            canvas.restore();
          }
        }
        canvas.restore();
      }
    } else {
      canvas.drawCircle(
        Offset(sunrise ? 290 : 315, sunrise ? 260 : 150),
        sunrise ? 49 : 30,
        Paint()
          ..color = sunrise ? const Color(0xffffdeb0) : const Color(0xfff1e6b9),
      );
      for (var layer = 0; layer < 5; layer++) {
        final y = 310.0 + layer * 100;
        final path = Path()..moveTo(-30, y + 100);
        if (preset == 'mountains') {
          path.lineTo(80 + layer * 34.0, y - 110);
          path.lineTo(225 + layer * 15.0, y + 15);
          path.lineTo(340, y - 70);
          path.lineTo(450, y + 120);
        } else {
          path.cubicTo(100, y - 45, 210, y + 160, 440, y - 5);
        }
        path.lineTo(440, 850);
        path.lineTo(-30, 850);
        path.close();
        canvas.drawPath(
          path,
          Paint()
            ..color = [
              const Color(0xffa1b9a4),
              const Color(0xff7e9d84),
              const Color(0xff597c66),
              const Color(0xff3e6355),
              const Color(0xff234e43),
            ][layer],
        );
      }
      if (preset == 'orchard') {
        for (var row = 0; row < 4; row++) {
          for (var col = 0; col < 6; col++) {
            final x = col * 91.0 - 45 + (row.isEven ? 40 : 0),
                y = 420 + row * 114.0;
            canvas.drawLine(
              Offset(x, y),
              Offset(x, y + 85),
              Paint()
                ..color = const Color(0xff496151)
                ..strokeWidth = 5,
            );
            canvas.drawOval(
              Rect.fromCenter(center: Offset(x, y), width: 72, height: 86),
              Paint()..color = const Color(0xffa1b87a),
            );
            canvas.drawOval(
              Rect.fromCenter(
                center: Offset(x - 10, y - 10),
                width: 52,
                height: 67,
              ),
              Paint()..color = const Color(0xffb6c78b),
            );
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LandscapeWallpaper oldDelegate) =>
      preset != oldDelegate.preset;
}

class HomeGlassOpacity extends InheritedWidget {
  final double opacity;
  const HomeGlassOpacity({
    super.key,
    required this.opacity,
    required super.child,
  });
  @override
  bool updateShouldNotify(HomeGlassOpacity oldWidget) =>
      opacity != oldWidget.opacity;
}

class LiquidGlass extends StatelessWidget {
  final double? opacity;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  const LiquidGlass({
    super.key,
    required this.child,
    this.opacity,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22102724),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xff041c16).withValues(
                    alpha:
                        opacity ??
                        context
                            .dependOnInheritedWidgetOfExactType<
                              HomeGlassOpacity
                            >()
                            ?.opacity ??
                        173 / 255,
                  ),
                  const Color(0xff071a20).withValues(
                    alpha:
                        opacity ??
                        context
                            .dependOnInheritedWidgetOfExactType<
                              HomeGlassOpacity
                            >()
                            ?.opacity ??
                        173 / 255,
                  ),
                ],
              ),
              border: Border.all(color: const Color(0x88ffffff)),
            ),
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: padding,
                child: DefaultTextStyle(
                  style: const TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 14,
                    height: 1.25,
                    color: Colors.white,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class EditWiggle extends StatefulWidget {
  final bool enabled;
  final Widget child;
  final int seed;
  const EditWiggle({
    super.key,
    required this.enabled,
    required this.child,
    required this.seed,
  });
  @override
  State<EditWiggle> createState() => _EditWiggleState();
}

class EditableDraggable<T extends Object> extends StatefulWidget {
  final T data;
  final bool editing;
  final Widget child, feedback, childWhenDragging;
  final VoidCallback onDragStarted;
  final void Function(DraggableDetails) onDragEnd;
  final void Function(DragUpdateDetails) onDragUpdate;
  const EditableDraggable({
    super.key,
    required this.data,
    required this.editing,
    required this.child,
    required this.feedback,
    required this.childWhenDragging,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onDragUpdate,
  });
  @override
  State<EditableDraggable<T>> createState() => _EditableDraggableState<T>();
}

class _EditableDraggableState<T extends Object>
    extends State<EditableDraggable<T>> {
  bool longGesture = false;
  void start() {
    longGesture = !widget.editing;
    widget.onDragStarted();
  }

  void end(DraggableDetails details) {
    longGesture = false;
    widget.onDragEnd(details);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.editing && !longGesture
      ? Draggable<T>(
          data: widget.data,
          feedback: widget.feedback,
          childWhenDragging: widget.childWhenDragging,
          maxSimultaneousDrags: 1,
          onDragStarted: start,
          onDragEnd: end,
          onDragUpdate: widget.onDragUpdate,
          child: widget.child,
        )
      : LongPressDraggable<T>(
          data: widget.data,
          delay: const Duration(milliseconds: 450),
          hapticFeedbackOnStart: true,
          maxSimultaneousDrags: 1,
          feedback: widget.feedback,
          childWhenDragging: widget.childWhenDragging,
          onDragStarted: start,
          onDragEnd: end,
          onDragUpdate: widget.onDragUpdate,
          child: widget.child,
        );
}

class _EditWiggleState extends State<EditWiggle>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 310),
  );
  @override
  void initState() {
    super.initState();
    update();
  }

  void update() {
    if (widget.enabled) {
      controller.repeat();
    } else {
      controller.stop();
      controller.value = 0;
    }
  }

  @override
  void didUpdateWidget(EditWiggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) update();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder: (_, child) => Transform.rotate(
      angle: widget.enabled
          ? math.sin(controller.value * math.pi * 2 + widget.seed) * .018
          : 0,
      child: child,
    ),
  );
}

class AppearanceSettings extends StatefulWidget {
  final FarmStore store;
  const AppearanceSettings({super.key, required this.store});
  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  String preset = 'fields';
  String? photo;
  bool animate = true, loaded = false;
  bool highContrast = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final p = await widget.store.setting('wallpaperPhoto');
    final selected =
        await widget.store.setting('wallpaperPreset') ??
        (p == null ? 'fields' : 'photo');
    final motion = await widget.store.setting('animateIcons') != false;
    final contrast = await widget.store.setting('homeHighContrast') == true;
    if (mounted) {
      setState(() {
        photo = p;
        preset = selected;
        animate = motion;
        highContrast = contrast;
        loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loaded)
        DropdownButtonFormField<String>(
          key: ValueKey(preset),
          initialValue: preset,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Home wallpaper'),
          items: {...wallpaperChoices, if (photo != null) 'photo': 'Your photo'}
              .entries
              .map(
                (e) => DropdownMenuItem(
                  value: e.key,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: 40,
                          height: 28,
                          child: FarmBackdrop(
                            preset: e.key,
                            photo: photo,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(e.value),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (value) async {
            if (value == null) return;
            setState(() => preset = value);
            await widget.store.setSetting('wallpaperPreset', value);
          },
        ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: 160,
          child: FarmBackdrop(
            glassOpacity: highContrast ? .92 : .60,
            preset: preset,
            photo: photo,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: LiquidGlass(
                  child: const Row(
                    children: [
                      Icon(
                        Icons.wb_sunny_outlined,
                        color: Color(0xffffe19a),
                        size: 32,
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Your home screen\nWallpaper preview',
                          style: TextStyle(height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      TextButton.icon(
        onPressed: () => guarded(context, () async {
          if (await Wallpaper.pick(widget.store)) {
            await widget.store.setSetting('wallpaperPreset', 'photo');
            await load();
          }
        }),
        icon: const Icon(Icons.photo_library_outlined),
        label: const Text('Use your own photo'),
      ),
      SwitchListTile(
        title: const Text('High-contrast Home panels'),
        subtitle: const Text(
          'Standard glass is 60% opaque. Increase contrast for outdoor reading.',
        ),
        value: highContrast,
        onChanged: (v) async {
          setState(() => highContrast = v);
          await widget.store.setSetting('homeHighContrast', v);
        },
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: animate,
        title: const Text('Animate icons while editing'),
        subtitle: const Text(
          'Also respects your phone’s reduced-motion setting.',
        ),
        onChanged: (v) async {
          setState(() => animate = v);
          await widget.store.setSetting('animateIcons', v);
        },
      ),
    ],
  );
}

class FrostPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const FrostPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: .9),
            width: 1.5,
          ),
        ),
        child: Material(color: Colors.transparent, child: child),
      ),
    ),
  );
}
