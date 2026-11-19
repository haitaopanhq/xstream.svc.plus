import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/sqlite_node_store.dart';
import 'package:xconnect/services/sync/xray_config_writer.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('XrayConfigWriter.isReplaceableFallbackNode', () {
    test('does not prune region nodes created by sync', () {
      for (final name in ['jp', 'ph', 'sg', 'us']) {
        final node = VpnNode(
          name: name,
          countryCode: name.toUpperCase(),
          configPath: '/tmp/$name.json',
          serviceName: 'xconnect.desktop.sync',
        );
        expect(
          XrayConfigWriter.isReplaceableFallbackNode(node, 'US-Connect'),
          isFalse,
        );
      }
    });

    test('replaces only the generic fallback sync node', () {
      final fallback = VpnNode(
        name: 'Desktop Sync',
        countryCode: 'SYNC',
        configPath: '/tmp/fallback.json',
        serviceName: 'xconnect.desktop.sync',
      );
      expect(
        XrayConfigWriter.isReplaceableFallbackNode(fallback, 'US-Connect'),
        isTrue,
      );
      expect(
        XrayConfigWriter.isReplaceableFallbackNode(fallback, 'Desktop Sync'),
        isFalse,
      );
    });
  });

  group('XrayConfigWriter.extractOutboundIdentity', () {
    test('extracts stable identity from proxy outbound', () {
      const json = '''
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "57.183.19.25",
            "port": 443,
            "users": [
              { "id": "18d270a9-533d-4b13-b3f1-e7f55540a9b2" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "jp-xhttp.svc.plus"
        }
      }
    }
  ]
}
''';

      final identity = XrayConfigWriter.extractOutboundIdentity(json);

      expect(
        identity,
        'vless|57.183.19.25|443|18d270a9-533d-4b13-b3f1-e7f55540a9b2|xhttp|tls|jp-xhttp.svc.plus',
      );
    });

    test('returns null when proxy outbound is missing', () {
      const json = '{"outbounds":[{"tag":"direct","protocol":"freedom"}]}';
      expect(XrayConfigWriter.extractOutboundIdentity(json), isNull);
    });
  });

  group('XrayConfigWriter SHA-256 diff & owner in-place updates', () {
    late Directory support;

    setUpAll(() async {
      support = await Directory.systemTemp.createTemp('xconnect-writer-test-');
      GlobalApplicationConfig.localConfigPathOverride =
          '${support.path}/vpn_nodes.json';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => support.path,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SqliteNodeStore.resetForTesting();
    });

    setUp(() async {
      await VpnConfig.importFromJson('[]');
    });

    tearDownAll(() async {
      SqliteNodeStore.resetForTesting();
      GlobalApplicationConfig.localConfigPathOverride = null;
      await support.delete(recursive: true);
    });

    test('writeConfigForNodeWithResult reports modified via SHA-256 diff',
        () async {
      final configA = jsonEncode(<String, dynamic>{
        'outbounds': [
          <String, dynamic>{
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': '1.2.3.4',
                  'port': 443,
                  'users': [
                    {'id': '11111111-1111-4111-8111-111111111111'}
                  ],
                }
              ],
            },
          }
        ],
      });
      final configB = jsonEncode(<String, dynamic>{
        'outbounds': [
          <String, dynamic>{
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': '5.6.7.8',
                  'port': 443,
                  'users': [
                    {'id': '11111111-1111-4111-8111-111111111111'}
                  ],
                }
              ],
            },
          }
        ],
      });

      final first = await XrayConfigWriter.writeConfigForNodeWithResult(
        json: configA,
        nodeName: 'JP',
        countryCode: 'jp',
        nodeId: 'node-jp',
        owner: 'https://accounts.example|user@example',
        teamId: 'team-1',
      );
      expect(first.modified, isTrue);
      expect(await File(first.path).exists(), isTrue);

      final second = await XrayConfigWriter.writeConfigForNodeWithResult(
        json: configA,
        nodeName: 'JP',
        countryCode: 'jp',
        nodeId: 'node-jp',
        owner: 'https://accounts.example|user@example',
        teamId: 'team-1',
      );
      expect(second.modified, isFalse);
      expect(second.path, first.path);

      final third = await XrayConfigWriter.writeConfigForNodeWithResult(
        json: configB,
        nodeName: 'JP',
        countryCode: 'jp',
        nodeId: 'node-jp',
        owner: 'https://accounts.example|user@example',
        teamId: 'team-1',
      );
      expect(third.modified, isTrue);
      expect(third.path, first.path);
    });

    test(
        'registerNode updates metadata in place without duplicates when owner is present',
        () async {
      const owner = 'https://accounts.example|user@example';
      final path1 = await XrayConfigWriter.writeConfigForNode(
        json: '{"outbounds":[{"tag":"proxy","protocol":"vless"}]}',
        nodeName: 'Tokyo',
        countryCode: 'jp',
        nodeId: 'node-jp',
        owner: owner,
        teamId: 'team-a',
      );
      final name1 = await XrayConfigWriter.registerNode(
        configPath: path1,
        nodeName: 'Tokyo',
        countryCode: 'jp',
        protocol: 'vless',
        transport: 'tcp',
        security: 'tls',
        nodeId: 'node-jp',
        owner: owner,
        teamId: 'team-a',
        routingPool: 'free',
        pricingGroup: 'tier-free',
      );
      expect(name1, 'Tokyo');
      expect(VpnConfig.allNodes, hasLength(1));

      // Re-register with updated teamId, routingPool, pricingGroup, and path.
      final path2 = await XrayConfigWriter.writeConfigForNode(
        json: '{"outbounds":[{"tag":"proxy","protocol":"vless"}]}',
        nodeName: 'Tokyo',
        countryCode: 'jp',
        nodeId: 'node-jp',
        owner: owner,
        teamId: 'team-b',
      );
      final name2 = await XrayConfigWriter.registerNode(
        configPath: path2,
        nodeName: 'Tokyo',
        countryCode: 'jp',
        protocol: 'vless',
        transport: 'xhttp',
        security: 'tls',
        nodeId: 'node-jp',
        owner: owner,
        teamId: 'team-b',
        routingPool: 'plus',
        pricingGroup: 'tier-plus',
      );
      expect(name2, 'Tokyo');
      expect(VpnConfig.allNodes, hasLength(1));
      final updated = VpnConfig.allNodes.single;
      expect(updated.managedTeamId, 'team-b');
      expect(updated.transport, 'xhttp');
      expect(updated.routingPool, 'plus');
      expect(updated.pricingGroup, 'tier-plus');
      expect(updated.configPath, path2);

      // Distinct nodeId with same display name must not overwrite node-jp.
      final path3 = await XrayConfigWriter.writeConfigForNode(
        json: '{"outbounds":[{"tag":"proxy","protocol":"vless"}]}',
        nodeName: 'Tokyo',
        countryCode: 'jp',
        nodeId: 'node-jp-2',
        owner: owner,
        teamId: 'team-b',
      );
      final name3 = await XrayConfigWriter.registerNode(
        configPath: path3,
        nodeName: 'Tokyo',
        countryCode: 'jp',
        nodeId: 'node-jp-2',
        owner: owner,
        teamId: 'team-b',
        routingPool: 'team',
      );
      expect(name3, isNot('Tokyo'));
      expect(VpnConfig.allNodes, hasLength(2));
    });
  });
}
