import 'dart:convert';

import 'package:crypto/crypto.dart';

Future<List<int>> deriveOfflinePassword(
  String material,
  List<int> salt,
  int rounds,
) async {
  final mac = Hmac(sha256, utf8.encode(material));
  var current = mac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = List<int>.from(current);
  for (var round = 1; round < rounds; round++) {
    current = mac.convert(current).bytes;
    for (var i = 0; i < result.length; i++) {
      result[i] ^= current[i];
    }
  }
  return result;
}
