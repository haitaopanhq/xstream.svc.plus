import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../utils/global_config.dart';

class SqliteNodeStore {
  static Database? _db;

  @visibleForTesting
  static void resetForTesting() {
    _db?.dispose();
    _db = null;
  }

  static void _configureLinuxLibrary() {
    if (Platform.isLinux) {
      // Ubuntu's runtime package exposes the stable SONAME. The unversioned
      // libsqlite3.so name belongs to the development package and is normally
      // absent on end-user systems.
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  }

  static Future<Database> _openDb() async {
    if (_db != null) {
      return _db!;
    }

    final basePath = await GlobalApplicationConfig.getSandboxBasePath();
    final dbPath = p.join(basePath, 'app.db');
    final dbFile = File(dbPath);
    await dbFile.parent.create(recursive: true);

    _configureLinuxLibrary();
    final db = sqlite3.open(dbPath);
    db.execute('''
      CREATE TABLE IF NOT EXISTS vpn_nodes (
        name TEXT PRIMARY KEY,
        country_code TEXT NOT NULL,
        config_path TEXT NOT NULL,
        service_name TEXT NOT NULL,
        protocol TEXT NOT NULL,
        transport TEXT NOT NULL,
        security TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS app_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    final columns =
        db.select('PRAGMA table_info(vpn_nodes)').map((r) => r['name']).toSet();
    for (final column in [
      'managed_owner',
      'managed_team_id',
      'managed_node_id',
      'routing_pool',
      'pricing_group',
    ]) {
      if (!columns.contains(column)) {
        db.execute('ALTER TABLE vpn_nodes ADD COLUMN $column TEXT');
      }
    }
    _db = db;
    return db;
  }

  static Future<List<Map<String, dynamic>>> loadNodes() async {
    final db = await _openDb();
    final rs = db.select('''
      SELECT name, country_code, config_path, service_name,
             protocol, transport, security, enabled,
             managed_owner, managed_team_id, managed_node_id,
             routing_pool, pricing_group
      FROM vpn_nodes
      ORDER BY updated_at DESC, name ASC
    ''');

    return rs.map((row) {
      return <String, dynamic>{
        'name': (row['name'] as String?) ?? '',
        'countryCode': (row['country_code'] as String?) ?? '',
        'configPath': (row['config_path'] as String?) ?? '',
        'serviceName': (row['service_name'] as String?) ?? '',
        'protocol': (row['protocol'] as String?) ?? '',
        'transport': (row['transport'] as String?) ?? '',
        'security': (row['security'] as String?) ?? '',
        'enabled': ((row['enabled'] as int?) ?? 1) == 1,
        'managedOwner': row['managed_owner'],
        'managedTeamId': row['managed_team_id'],
        'managedNodeId': row['managed_node_id'],
        'routingPool': row['routing_pool'],
        'pricingGroup': row['pricing_group'],
      };
    }).toList();
  }

  static Future<void> replaceAll(List<Map<String, dynamic>> nodes) async {
    final db = await _openDb();
    final now = DateTime.now().millisecondsSinceEpoch;

    db.execute('BEGIN TRANSACTION');
    try {
      db.execute('DELETE FROM vpn_nodes');
      final stmt = db.prepare('''
        INSERT INTO vpn_nodes(
          name, country_code, config_path, service_name,
          protocol, transport, security, enabled, updated_at,
          managed_owner, managed_team_id, managed_node_id,
          routing_pool, pricing_group
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (final node in nodes) {
          stmt.execute([
            (node['name'] as String?) ?? '',
            (node['countryCode'] as String?) ?? '',
            (node['configPath'] as String?) ?? '',
            (node['serviceName'] as String?) ?? '',
            (node['protocol'] as String?) ?? '',
            (node['transport'] as String?) ?? '',
            (node['security'] as String?) ?? '',
            ((node['enabled'] as bool?) ?? true) ? 1 : 0,
            now,
            node['managedOwner'],
            node['managedTeamId'],
            node['managedNodeId'],
            node['routingPool'] ?? node['routing_pool'],
            node['pricingGroup'] ?? node['pricing_group'],
          ]);
        }
      } finally {
        stmt.dispose();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static Future<void> deleteNode(String name) async {
    final db = await _openDb();
    db.execute('DELETE FROM vpn_nodes WHERE name = ?', [name]);
  }

  static Future<void> setAppState(String key, String value) async {
    final db = await _openDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute('''
      INSERT INTO app_state(key, value, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value=excluded.value,
        updated_at=excluded.updated_at
    ''', [key, value, now]);
  }

  static Future<String?> getAppState(String key) async {
    final db = await _openDb();
    final rs = db.select(
      'SELECT value FROM app_state WHERE key = ? LIMIT 1',
      [key],
    );
    if (rs.isEmpty) return null;
    return rs.first['value'] as String?;
  }
}
