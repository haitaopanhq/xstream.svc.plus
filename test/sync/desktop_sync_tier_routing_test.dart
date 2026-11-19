import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/network_access_policy.dart';
import 'package:xconnect/services/session/session_manager.dart';
import 'package:xconnect/services/sqlite_node_store.dart';
import 'package:xconnect/services/sync/desktop_sync_service.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/app_log_file.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = SessionManager.instance;
  final sync = DesktopSyncService.instance;
  late Directory support;

  final access = <String, dynamic>{
    'mode': 'dedicated',
    'allowed': true,
    'accountId': 'account-tier',
    'teamId': 'team-tier',
    'team': <String, dynamic>{
      'name': 'Tier Team',
      'validUntil':
          DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    },
  };

  setUpAll(() async {
    AppLogFile.enabled = false;
    support = await Directory.systemTemp.createTemp('xconnect-tier-sync-');
    GlobalApplicationConfig.localConfigPathOverride =
        '${support.path}/vpn_nodes.json';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      if (utf8.decode(message!.buffer.asUint8List()) !=
          'macos/Runner/Configs/AppInfo.xcconfig') {
        return null;
      }
      return ByteData.sublistView(
        Uint8List.fromList(
          utf8.encode('PRODUCT_BUNDLE_IDENTIFIER=plus.svc.xconnect'),
        ),
      );
    });
  });

  setUp(() async {
    SqliteNodeStore.resetForTesting();
    GlobalState.activeNodeName.value = '';
    GlobalState.setTunnelModeEnabled(true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'test-session',
      'session.username': 'tier@example',
    });
    session.onSessionReset = null;
    await session.init();
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    await VpnConfig.importFromJson('[]');
  });

  tearDown(() {
    sync.dispose();
    sync.stopTunnelForTesting = null;
    sync.startTunnelForTesting = null;
    sync.stopNodeServiceForTesting = null;
    sync.startNodeServiceForTesting = null;
    sync.refreshIosPacketTunnelProfileForTesting = null;
    GlobalState.activeNodeName.value = '';
    GlobalState.setTunnelModeEnabled(true);
    NetworkAccessPolicy.instance.dedicated = false;
    NetworkAccessPolicy.instance.invalidate(signedIn: false);
  });

  tearDownAll(() async {
    SqliteNodeStore.resetForTesting();
    GlobalApplicationConfig.localConfigPathOverride = null;
    await support.delete(recursive: true);
  });

  group('DesktopSyncService._parseNode', () {
    test('remains backward-compatible when tier and routing fields are absent',
        () {
      final parsed = sync.parseNodeForTesting(<Object?, Object?>{
        'id': 'node-legacy',
        'name': 'Legacy JP',
        'region': 'JP',
        'vless_uri':
            'vless://11111111-1111-4111-8111-111111111111@jp.example:443?type=tcp&security=tls',
      });
      expect(parsed, isNotNull);
      expect(parsed!.id, 'node-legacy');
      expect(parsed.routingPool, isNull);
      expect(parsed.pricingGroup, isNull);
      expect(parsed.domainStrategy, isNull);
      expect(parsed.routingRules, isEmpty);
      expect(parsed.routing, isNull);
    });

    test('parses snake_case, camelCase, pool alias and nested routing object',
        () {
      final fromNested = sync.parseNodeForTesting(<Object?, Object?>{
        'id': 'node-nested',
        'name': 'SG Plus',
        'region': 'sg',
        'pool': 'plus',
        'pricing_group': 'pro-tier',
        'routing': <Object?, Object?>{
          'domainStrategy': 'IPIfNonMatch',
          'rules': <Object?>[
            <Object?, Object?>{
              'type': 'field',
              'domain': <Object?>['geosite:cn'],
              'outboundTag': 'direct',
            },
          ],
        },
        'vless_uri':
            'vless://11111111-1111-4111-8111-111111111111@sg.example:443?type=xhttp&security=tls',
      });
      expect(fromNested, isNotNull);
      expect(fromNested!.routingPool, 'plus');
      expect(fromNested.pricingGroup, 'pro-tier');
      expect(fromNested.domainStrategy, 'IPIfNonMatch');
      expect(fromNested.routingRules, hasLength(1));
      expect(fromNested.routingRules.single['outboundTag'], 'direct');

      final fromFlat = sync.parseNodeForTesting(<Object?, Object?>{
        'id': 'node-flat',
        'name': 'US Team',
        'region': 'us',
        'routingPool': 'team',
        'pricingGroup': 'enterprise',
        'domain_strategy': 'IPIfNonMatch',
        'routing_rules': <Object?>[
          <Object?, Object?>{
            'type': 'field',
            'ip': <Object?>['geoip:private'],
            'outboundTag': 'direct',
          },
        ],
        'vless_uri':
            'vless://11111111-1111-4111-8111-111111111111@us.example:443?type=tcp&security=tls',
      });
      expect(fromFlat, isNotNull);
      expect(fromFlat!.routingPool, 'team');
      expect(fromFlat.pricingGroup, 'enterprise');
      expect(fromFlat.domainStrategy, 'IPIfNonMatch');
      expect(fromFlat.routingRules, hasLength(1));
    });
  });

  group('DesktopSyncService.syncNow tier routing and reload', () {
    List<Map<String, dynamic>> serverNodes({
      String host = 'edge1.example',
      String routingPool = 'plus',
      String pricingGroup = 'pro',
      String domainStrategy = 'IPIfNonMatch',
      List<Map<String, dynamic>>? routingRules,
    }) =>
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'node-jp',
            'name': 'Tokyo Plus',
            'region': 'jp',
            'protocol': 'vless',
            'transport': 'xhttp',
            'security': 'tls',
            'routing_pool': routingPool,
            'pricing_group': pricingGroup,
            'domain_strategy': domainStrategy,
            'routing_rules': routingRules ??
                <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'field',
                    'domain': <String>['geosite:cn'],
                    'outboundTag': 'direct',
                  },
                  <String, dynamic>{
                    'type': 'field',
                    'outboundTag': 'proxy',
                  },
                ],
            'vless_uri':
                'vless://11111111-1111-4111-8111-111111111111@$host:443'
                    '?type=xhttp&security=tls&path=%2Fsplit#TokyoPlus',
          },
        ];

    test(
        'writes synced tier routing, updates in place, and reloads active node on change',
        () async {
      var currentPayload = serverNodes();
      sync.client = MockClient((request) async {
        if (request.url.path.endsWith('/network-access')) {
          return http.Response(jsonEncode(access), 200);
        }
        if (request.url.path.endsWith('/nodes')) {
          return http.Response(jsonEncode(currentPayload), 200);
        }
        return http.Response('', 404);
      });

      final events = <String>[];
      sync.stopTunnelForTesting = () async {
        events.add('stopNodeForTunnel');
        return 'stopped';
      };
      sync.startTunnelForTesting = (name) async {
        events.add('startNodeForTunnel:$name');
        return 'started';
      };
      sync.stopNodeServiceForTesting = (name) async {
        events.add('stopNodeService:$name');
        return 'stopped';
      };
      sync.startNodeServiceForTesting = (name) async {
        events.add('startNodeService:$name');
        return 'started';
      };
      sync.refreshIosPacketTunnelProfileForTesting = () async {
        events.add('refreshIosProfile');
        return 'refreshed';
      };

      // Initial sync while disconnected: writes config and triggers iOS refresh hook.
      expect((await sync.syncNow()).success, isTrue);
      expect(VpnConfig.nodes, hasLength(1));
      final initialNode = VpnConfig.nodes.single;
      expect(initialNode.name, 'Tokyo Plus');
      expect(initialNode.routingPool, 'plus');
      expect(initialNode.pricingGroup, 'pro');
      expect(events, ['refreshIosProfile']);
      events.clear();

      final writtenJson = jsonDecode(
        await File(initialNode.configPath).readAsString(),
      ) as Map<String, dynamic>;
      final writtenRouting = writtenJson['routing'] as Map<String, dynamic>;
      expect(writtenRouting['domainStrategy'], 'IPIfNonMatch');
      final cnRules = (writtenRouting['rules'] as List<dynamic>).where((r) =>
          r is Map &&
          r['domain'] is List &&
          (r['domain'] as List).contains('geosite:cn'));
      expect(cnRules, hasLength(1));

      // Mark node active, re-sync identical payload -> no reload, no duplicates.
      GlobalState.activeNodeName.value = initialNode.name;
      expect((await sync.syncNow()).success, isTrue);
      expect(VpnConfig.allNodes, hasLength(1));
      expect(events, isEmpty);

      // Update server routing/endpoint in TUN mode -> reloads via tunnel stop + start.
      currentPayload = serverNodes(
        host: 'edge2.example',
        routingPool: 'team',
        pricingGroup: 'enterprise',
      );
      expect((await sync.syncNow()).success, isTrue);
      expect(VpnConfig.allNodes, hasLength(1));
      expect(VpnConfig.nodes.single.routingPool, 'team');
      expect(VpnConfig.nodes.single.pricingGroup, 'enterprise');
      expect(events, [
        'stopNodeForTunnel',
        'startNodeForTunnel:Tokyo Plus',
      ]);
      events.clear();

      // Switch to proxy mode and update rules -> reloads via proxy stop + start.
      GlobalState.setTunnelModeEnabled(false);
      currentPayload = serverNodes(
        host: 'edge2.example',
        routingPool: 'team',
        pricingGroup: 'enterprise',
        routingRules: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'field',
            'domain': <String>['geosite:cn', 'geosite:private'],
            'outboundTag': 'direct',
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
          },
        ],
      );
      expect((await sync.syncNow()).success, isTrue);
      expect(events, [
        'stopNodeService:Tokyo Plus',
        'startNodeService:Tokyo Plus',
        'refreshIosProfile',
      ]);
    });
  });
}
