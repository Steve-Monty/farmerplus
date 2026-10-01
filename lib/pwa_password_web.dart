import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<List<int>> deriveOfflinePassword(
  String material,
  List<int> salt,
  int rounds,
) async {
  final subtle = web.window.crypto.subtle;
  final passwordBytes = Uint8List.fromList(utf8.encode(material));
  final key = await subtle
      .importKey(
        'raw',
        passwordBytes.toJS,
        'PBKDF2'.toJS,
        false,
        <JSString>['deriveBits'.toJS].toJS,
      )
      .toDart;
  final parameters = <String, Object>{
    'name': 'PBKDF2',
    'salt': Uint8List.fromList(salt).toJS,
    'iterations': rounds,
    'hash': 'SHA-256',
  }.jsify()!;
  final bits = await subtle.deriveBits(parameters, key, 256).toDart;
  return bits.toDart.asUint8List();
}
