import 'package:geolocator/geolocator.dart';

bool get desktopBrowser => false;
Future<Position> freshBrowserPosition() =>
    throw UnsupportedError('Browser only');
