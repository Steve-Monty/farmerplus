import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class CourseDownloadStorage {
  static const _databaseName = 'farmerplus-learning-v1';
  static const _storeName = 'resources';
  final String filesPath;
  CourseDownloadStorage(this.filesPath);

  String reference(String key) => key;

  Future<JSAny?> _request(web.IDBRequest request) {
    final result = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      if (!result.isCompleted) result.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(
          StateError(request.error?.message ?? 'Browser storage failed.'),
        );
      }
    }).toJS;
    return result.future;
  }

  Future<void> _transaction(web.IDBTransaction transaction) {
    final result = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!result.isCompleted) result.complete();
    }).toJS;
    transaction.onabort = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(
          StateError('Browser storage transaction aborted.'),
        );
      }
    }).toJS;
    transaction.onerror = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(StateError('Browser storage transaction failed.'));
      }
    }).toJS;
    return result.future;
  }

  Future<web.IDBDatabase> _open() {
    final result = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!result.isCompleted) {
        result.complete(request.result as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(
          StateError(
            request.error?.message ?? 'Browser storage is unavailable.',
          ),
        );
      }
    }).toJS;
    return result.future;
  }

  Future<String?> _get(String key) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName.toJS, 'readonly');
      final value = await _request(
        transaction.objectStore(_storeName).get(key.toJS),
      );
      await _transaction(transaction);
      return value == null ? null : (value as JSString).toDart;
    } finally {
      database.close();
    }
  }

  Future<void> _put(String key, String value) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName.toJS, 'readwrite');
      transaction.objectStore(_storeName).put(value.toJS, key.toJS);
      await _transaction(transaction);
    } finally {
      database.close();
    }
  }

  Future<int> partialLength(String key) async {
    final value = await _get('$key.part');
    return value == null || value.isEmpty ? 0 : base64Decode(value).length;
  }

  Future<void> resetPartial(String key) => _put('$key.part', '');

  Future<void> appendPartial(String key, List<int> bytes) async {
    final current = await _get('$key.part');
    final joined = <int>[
      if (current != null && current.isNotEmpty) ...base64Decode(current),
      ...bytes,
    ];
    await _put('$key.part', base64Encode(joined));
  }

  Future<List<int>> readPartial(String key) async {
    final value = await _get('$key.part');
    if (value == null) {
      throw StateError('The partial course download is missing.');
    }
    return value.isEmpty ? <int>[] : base64Decode(value);
  }

  Future<String> commitPartial(String key) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName.toJS, 'readwrite');
      final store = transaction.objectStore(_storeName);
      final value = await _request(store.get('$key.part'.toJS));
      if (value == null) {
        transaction.abort();
        throw StateError('The partial course download is missing.');
      }
      store.put(value, key.toJS);
      store.delete('$key.part'.toJS);
      await _transaction(transaction);
      return key;
    } finally {
      database.close();
    }
  }

  Future<bool> exists(String reference) async => await _get(reference) != null;

  Future<List<int>> read(String reference) async {
    final value = await _get(reference);
    if (value == null) {
      throw StateError('The saved course resource is missing.');
    }
    return base64Decode(value);
  }

  Future<void> removeCourse(
    String binding,
    int courseId, {
    Set<int>? resources,
    bool partialsOnly = false,
  }) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName.toJS, 'readwrite');
      final store = transaction.objectStore(_storeName);
      final rawKeys = await _request(store.getAllKeys());
      final keys = rawKeys == null
          ? <JSAny?>[]
          : (rawKeys as JSArray<JSAny?>).toDart;
      final prefix = '$binding/$courseId/';
      for (final raw in keys) {
        final key = raw?.dartify();
        if (key is! String) continue;
        if (!key.startsWith(prefix)) continue;
        if (partialsOnly && !key.endsWith('.part')) continue;
        final name = key.split('/').last.replaceFirst(RegExp(r'\.part$'), '');
        final resourceId = int.tryParse(name.split('-').first);
        if (resources == null || resources.contains(resourceId)) {
          store.delete(key.toJS);
        }
      }
      await _transaction(transaction);
    } finally {
      database.close();
    }
  }
}
