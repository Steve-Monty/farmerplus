import 'dart:convert';
import 'dart:js_interop';
import 'package:crypto/crypto.dart';

@JS('farmerRegisterMapArchive')
external JSString _registerMapArchive(JSString key, JSString base64Data);

final Map<String, String> _urls = {};

Future<String?> browserMapBlobUrl(String base64Data) async {
  final bytes = base64Decode(base64Data);
  final key = sha256.convert(bytes).toString();
  final existing = _urls[key];
  if (existing != null) return existing;
  // Blob fetches do not implement HTTP byte ranges. Register a local byte
  // source with PMTiles so every range is served from memory without fetch.
  final url = _registerMapArchive(key.toJS, base64Data.toJS).toDart;
  _urls[key] = url;
  return url;
}
