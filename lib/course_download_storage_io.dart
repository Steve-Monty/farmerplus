import 'dart:io';

import 'package:path/path.dart' as path;

class CourseDownloadStorage {
  final String filesPath;
  CourseDownloadStorage(this.filesPath);

  String _absolute(String key) {
    final root = path.normalize(path.join(filesPath, 'learning'));
    final candidate = path.normalize(path.join(root, key));
    if (!path.isWithin(root, candidate)) {
      throw StateError('Invalid course download path.');
    }
    return candidate;
  }

  String reference(String key) => _absolute(key);

  String _resolve(String reference) => path.isAbsolute(reference)
      ? path.normalize(reference)
      : _absolute(reference);

  Future<int> partialLength(String key) async {
    final file = File('${_absolute(key)}.part');
    return await file.exists() ? file.length() : 0;
  }

  Future<void> resetPartial(String key) async {
    final file = File('${_absolute(key)}.part');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const []);
  }

  Future<void> appendPartial(String key, List<int> bytes) async {
    final file = File('${_absolute(key)}.part');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  Future<List<int>> readPartial(String key) =>
      File('${_absolute(key)}.part').readAsBytes();

  Future<String> commitPartial(String key) async {
    final partial = File('${_absolute(key)}.part');
    final target = File(_absolute(key));
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
    return target.path;
  }

  Future<bool> exists(String reference) => File(_resolve(reference)).exists();

  Future<List<int>> read(String reference) =>
      File(_resolve(reference)).readAsBytes();

  Future<void> removeCourse(
    String binding,
    int courseId, {
    Set<int>? resources,
    bool partialsOnly = false,
  }) async {
    final root = path.normalize(_absolute('$binding/$courseId'));
    final directory = Directory(root);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final absolute = path.normalize(entity.path);
      if (!path.isWithin(root, absolute)) {
        throw StateError('Invalid course download path.');
      }
      final name = path.basename(absolute);
      if (partialsOnly && !name.endsWith('.part')) continue;
      final resourceId = int.tryParse(name.split('-').first);
      if (resources == null || resources.contains(resourceId)) {
        await entity.delete();
      }
    }
  }
}
