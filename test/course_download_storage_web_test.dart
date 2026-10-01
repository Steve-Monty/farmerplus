@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/course_download_storage_web.dart';

void main() {
  test(
    'IndexedDB stages, commits, isolates, resumes and removes resources',
    () async {
      final storage = CourseDownloadStorage('browser');
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final ownerA = 'owner-a-$nonce';
      final ownerB = 'owner-b-$nonce';
      final keyA = '$ownerA/10/v1/35-${'a' * 64}.html';
      final keyB = '$ownerB/10/v1/35-${'b' * 64}.html';
      final first = utf8.encode('first ');
      final second = utf8.encode('second');

      await storage.resetPartial(keyA);
      await storage.appendPartial(keyA, first);
      expect(await storage.partialLength(keyA), first.length);
      await storage.appendPartial(keyA, second);
      expect(await storage.readPartial(keyA), [...first, ...second]);

      final referenceA = await storage.commitPartial(keyA);
      expect(referenceA, keyA);
      expect(await storage.exists(referenceA), true);
      expect(await storage.read(referenceA), [...first, ...second]);

      await storage.resetPartial(keyB);
      await storage.appendPartial(keyB, utf8.encode('other owner'));
      await storage.commitPartial(keyB);
      await storage.removeCourse(ownerA, 10, resources: {35});
      expect(await storage.exists(keyA), false);
      expect(await storage.exists(keyB), true);

      await storage.removeCourse(ownerB, 10);
    },
  );
}
