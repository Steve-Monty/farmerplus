import 'dart:convert';
import 'package:sqflite/sqflite.dart';

const businessKinds = {'season', 'stock', 'stockmove', 'harvest', 'sale'};
Future<void> validateBusiness(
  DatabaseExecutor tx,
  String id,
  String kind,
  Map<String, dynamic> data,
  bool deleted,
) async {
  if (!deleted && {'pin', 'calculation', 'diary', 'task'}.contains(kind)) {
    Map<String, dynamic>? linkedArea;
    if (data['fieldId'] != null && data['fieldId'] != '') {
      final rows = await tx.query(
        'records',
        where: 'id=? AND kind=? AND deleted=0',
        whereArgs: [data['fieldId'], 'field'],
      );
      if (rows.isEmpty) {
        throw StateError('The selected farm area is unavailable.');
      }
      linkedArea = jsonDecode(rows.first['data'] as String);
      data['farmId'] ??= linkedArea!['farmId'];
      if (linkedArea!['farmId'] != data['farmId']) {
        throw StateError('Choose an area in the selected farm.');
      }
    }
    if (data['farmId'] != null && data['farmId'] != '') {
      final rows = await tx.query(
        'records',
        where: 'id=? AND kind=? AND deleted=0',
        whereArgs: [data['farmId'], 'farm'],
      );
      if (rows.isEmpty) throw StateError('The selected farm is unavailable.');
    }
    if (kind == 'pin') {
      // Places belong to a farm. Resolve older area-linked drafts before
      // removing that association; registration pins may have no farm.
      data.remove('fieldId');
      for (final key in ['lat', 'lon']) {
        final v = data[key];
        if (v is! num || !v.isFinite || v.abs() > (key == 'lat' ? 85 : 180)) {
          throw StateError('Enter valid map coordinates.');
        }
      }
    }
  }
  if (!businessKinds.contains(kind) && !{'farm', 'field'}.contains(kind)) {
    return;
  }
  if (deleted && {'farm', 'field', 'season'}.contains(kind)) {
    final reference = {
      'farm': 'farmId',
      'field': 'fieldId',
      'season': 'seasonId',
    }[kind]!;
    for (final row in await tx.query(
      'records',
      where: 'deleted=0 AND id<>?',
      whereArgs: [id],
    )) {
      if (jsonDecode(row['data'] as String)[reference] == id) {
        throw StateError(
          'Remove or reassign related records before deleting this $kind.',
        );
      }
    }
  }
  if (!businessKinds.contains(kind)) return;
  if (!deleted) {
    if ({'stock', 'harvest', 'season'}.contains(kind) &&
        (data['name'] is! String ||
            (data['name'] as String).trim().isEmpty ||
            (data['name'] as String).length > 200)) {
      throw StateError('Enter a record name of 1–200 characters.');
    }
    for (final key in ['date', 'start', 'expiry']) {
      final value = data[key];
      if (value != null && value != '') {
        final parsed = value is String ? DateTime.tryParse(value) : null;
        if (parsed == null ||
            parsed.toIso8601String().substring(0, 10) != value) {
          throw StateError('Use a valid calendar date.');
        }
      }
    }
  }
  final previous = await tx.query('records', where: 'id=?', whereArgs: [id]);
  final prior = previous.isEmpty
      ? null
      : jsonDecode(previous.first['data'] as String);
  if (prior != null && {'stockmove', 'sale'}.contains(kind)) {
    final field = kind == 'stockmove' ? 'stockId' : 'harvestId';
    if (prior[field] != data[field] || prior['farmId'] != data['farmId']) {
      throw StateError(
        'A saved movement must keep its original item and farm.',
      );
    }
  }
  if (!deleted &&
      {'stock', 'harvest'}.contains(kind) &&
      (data['unit'] is! String || (data['unit'] as String).trim().isEmpty)) {
    throw StateError('Choose a unit.');
  }
  Future<Map<String, dynamic>> parent(String? key, String expected) async {
    final rows = await tx.query(
      'records',
      where: 'id=? AND kind=? AND deleted=0',
      whereArgs: [key, expected],
    );
    if (rows.isEmpty) {
      throw StateError('The related $expected record is unavailable.');
    }
    return jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> related(
    String type,
    String key,
    String value,
  ) async =>
      (await tx.query(
            'records',
            where: 'kind=? AND deleted=0 AND id<>?',
            whereArgs: [type, id],
          ))
          .map((r) => jsonDecode(r['data'] as String) as Map<String, dynamic>)
          .where((r) => r[key] == value)
          .toList();
  double number(String key, {bool zero = false}) {
    final v = data[key];
    if (v is! num || !v.isFinite || (!zero && v <= 0) || (zero && v < 0)) {
      throw StateError('Enter a valid ${key.replaceAll('Price', ' price')}.');
    }
    return v.toDouble();
  }

  if (!deleted) {
    await parent(data['farmId'], 'farm');
    if (data['fieldId'] != null && data['fieldId'] != '') {
      final field = await parent(data['fieldId'], 'field');
      if (field['farmId'] != data['farmId']) {
        throw StateError('Choose a field in this farm.');
      }
    }
    if (data['seasonId'] != null && data['seasonId'] != '') {
      final season = await parent(data['seasonId'], 'season');
      if (season['farmId'] != data['farmId']) {
        throw StateError('Choose a season in this farm.');
      }
      if (season['fieldId'] != null &&
          season['fieldId'] != '' &&
          season['fieldId'] != data['fieldId']) {
        throw StateError('Choose the field assigned to this season.');
      }
    }
  }
  if (kind == 'stock') {
    final moves = await related('stockmove', 'stockId', id);
    if (deleted && moves.isNotEmpty) {
      throw StateError('Remove stock movements before deleting this item.');
    }
    final old = await tx.query('records', where: 'id=?', whereArgs: [id]);
    if (old.isNotEmpty && moves.isNotEmpty) {
      final prior = jsonDecode(old.first['data'] as String);
      if (prior['unit'] != data['unit'] || prior['farmId'] != data['farmId']) {
        throw StateError('An item with movements must keep its unit and farm.');
      }
    }
  }
  if (kind == 'stockmove') {
    final item = await parent(data['stockId'], 'stock');
    if (item['farmId'] != data['farmId']) {
      throw StateError('This stock item belongs to another farm.');
    }
    final delta = data['delta'];
    if (delta is! num || !delta.isFinite || delta == 0) {
      throw StateError('Enter a non-zero stock quantity.');
    }
    final moves = await related('stockmove', 'stockId', data['stockId']);
    final balance =
        moves.fold<double>(0, (a, b) => a + (b['delta'] as num).toDouble()) +
        (deleted ? 0 : delta.toDouble());
    if (balance < -.00000001) {
      throw StateError('This movement would use more stock than is recorded.');
    }
  }
  if (kind == 'harvest') {
    final sales = await related('sale', 'harvestId', id);
    if (prior != null &&
        sales.isNotEmpty &&
        (prior['unit'] != data['unit'] || prior['farmId'] != data['farmId'])) {
      throw StateError('Keep the unit and farm of a harvest with sales.');
    }
    if (deleted && sales.isNotEmpty) {
      throw StateError('Remove linked sales before deleting this harvest.');
    }
    if (!deleted) {
      final quantity = number('quantity');
      final sold = sales.fold<double>(
        0,
        (a, b) => a + (b['quantity'] as num).toDouble(),
      );
      if (sold > quantity + .00000001) {
        throw StateError(
          'Harvest quantity cannot be smaller than linked sales.',
        );
      }
    }
  }
  if (kind == 'sale' && !deleted) {
    final harvest = await parent(data['harvestId'], 'harvest');
    if (harvest['farmId'] != data['farmId']) {
      throw StateError('This harvest belongs to another farm.');
    }
    final quantity = number('quantity');
    number('unitPrice', zero: true);
    if (!{'Paid', 'Unpaid'}.contains(data['payment'])) {
      throw StateError('Choose Paid or Unpaid.');
    }
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(data['currency'] ?? '')) {
      throw StateError('Choose a three-letter currency code.');
    }
    final sales = await related('sale', 'harvestId', data['harvestId']);
    final sold =
        sales.fold<double>(0, (a, b) => a + (b['quantity'] as num).toDouble()) +
        quantity;
    if (sold > (harvest['quantity'] as num) + .00000001) {
      throw StateError('The sale exceeds the unsold harvest quantity.');
    }
    data['unit'] = harvest['unit'];
    data['total'] = (quantity * (data['unitPrice'] as num) * 100).round() / 100;
  }
  if (kind == 'season' &&
      !deleted &&
      !{'Planned', 'Active', 'Closed'}.contains(data['status'])) {
    throw StateError('Choose a season status.');
  }
}
