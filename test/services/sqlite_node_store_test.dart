import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xconnect/services/sqlite_node_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUp(() async {
    SqliteNodeStore.resetForTesting();
    support = await Directory.systemTemp.createTemp('xconnect-sqlite-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
  });

  tearDown(() async {
    SqliteNodeStore.resetForTesting();
    await support.delete(recursive: true);
  });

  test(
      'migrates legacy vpn_nodes table with nullable routing_pool and pricing_group',
      () async {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => throw UnsupportedError('Use default linux loader in test'),
      );
    }
    // Create a legacy DB lacking managed_* and routing_pool/pricing_group columns.
    final dbPath = p.join(support.path, 'app.db');
    final legacyDb = sqlite3.open(dbPath);
    legacyDb.execute('''
      CREATE TABLE vpn_nodes (
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
    legacyDb.execute('''
      INSERT INTO vpn_nodes (
        name, country_code, config_path, service_name,
        protocol, transport, security, enabled, updated_at
      ) VALUES (
        'legacy-jp', 'JP', '/tmp/jp.json', 'xconnect.sync.jp',
        'vless', 'tcp', 'tls', 1, 1000
      );
    ''');
    legacyDb.dispose();

    final loadedLegacy = await SqliteNodeStore.loadNodes();
    expect(loadedLegacy, hasLength(1));
    expect(loadedLegacy.single['name'], 'legacy-jp');
    expect(loadedLegacy.single['routingPool'], isNull);
    expect(loadedLegacy.single['pricingGroup'], isNull);

    await SqliteNodeStore.replaceAll([
      <String, dynamic>{
        'name': 'synced-plus',
        'countryCode': 'SG',
        'configPath': '/tmp/sg.json',
        'serviceName': 'xconnect.sync.sg',
        'protocol': 'vless',
        'transport': 'xhttp',
        'security': 'tls',
        'enabled': true,
        'managedOwner': 'https://accounts.example|user@example',
        'managedTeamId': 'team-a',
        'managedNodeId': 'node-sg',
        'routingPool': 'plus',
        'pricingGroup': 'pro-monthly',
      },
      <String, dynamic>{
        'name': 'manual-node',
        'countryCode': 'US',
        'configPath': '/tmp/us.json',
        'serviceName': 'manual.us',
        'protocol': 'vless',
        'transport': 'tcp',
        'security': 'tls',
        'enabled': true,
        'routingPool': null,
        'pricingGroup': null,
      },
    ]);

    SqliteNodeStore.resetForTesting();
    final reloaded = await SqliteNodeStore.loadNodes();
    expect(reloaded, hasLength(2));
    final plusNode = reloaded.firstWhere((n) => n['name'] == 'synced-plus');
    expect(plusNode['routingPool'], 'plus');
    expect(plusNode['pricingGroup'], 'pro-monthly');
    expect(plusNode['managedNodeId'], 'node-sg');

    final manualNode = reloaded.firstWhere((n) => n['name'] == 'manual-node');
    expect(manualNode['routingPool'], isNull);
    expect(manualNode['pricingGroup'], isNull);
  });
}
