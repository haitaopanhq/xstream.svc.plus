import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/sqlite_node_store.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

const _standardVlessUri =
    'vless://11111111-1111-4111-8111-111111111111@edge.example:443'
    '?type=xhttp&security=tls&sni=edge.example&path=%2Fsplit#StandardNode';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUpAll(() async {
    support =
        await Directory.systemTemp.createTemp('xconnect-vpn-synced-routing-');
    GlobalApplicationConfig.localConfigPathOverride =
        '${support.path}/vpn_nodes.json';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'macos/Runner/Configs/AppInfo.xcconfig') {
        return ByteData.sublistView(Uint8List.fromList(
          utf8.encode('PRODUCT_BUNDLE_IDENTIFIER=plus.svc.xconnect'),
        ));
      }
      return null;
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
  });

  setUp(() async {
    SqliteNodeStore.resetForTesting();
    await VpnConfig.importFromJson('[]');
  });

  tearDownAll(() async {
    SqliteNodeStore.resetForTesting();
    GlobalApplicationConfig.localConfigPathOverride = null;
    await support.delete(recursive: true);
  });

  test('VpnNode serializes and deserializes routingPool and pricingGroup', () {
    final node = VpnNode(
      name: 'jp-plus',
      countryCode: 'JP',
      configPath: '/tmp/jp.json',
      serviceName: 'xconnect.sync.jp',
      routingPool: 'plus',
      pricingGroup: 'pro',
    );
    final restored = VpnNode.fromJson(node.toJson());
    expect(restored.routingPool, 'plus');
    expect(restored.pricingGroup, 'pro');

    final snakeRestored = VpnNode.fromJson(<String, dynamic>{
      'name': 'sg-team',
      'countryCode': 'SG',
      'configPath': '/tmp/sg.json',
      'serviceName': 'xconnect.sync.sg',
      'routing_pool': ' team ',
      'pricing_group': ' enterprise ',
    });
    expect(snakeRestored.routingPool, 'team');
    expect(snakeRestored.pricingGroup, 'enterprise');
  });

  test(
      'manual parseVlessUri, generateFromVlessUri and tryGenerateXrayJsonFromVlessUri remain config-agnostic',
      () async {
    final profile = VpnConfig.parseVlessUri(_standardVlessUri);
    expect(profile.name, 'StandardNode');
    expect(profile.domain, 'edge.example');
    expect(profile.network, 'xhttp');

    final generatedRaw =
        await VpnConfig.tryGenerateXrayJsonFromVlessUri(_standardVlessUri);
    expect(generatedRaw, isNotNull);
    final generated = jsonDecode(generatedRaw!) as Map<String, dynamic>;
    final routing = generated['routing'] as Map<String, dynamic>;
    expect(routing['domainStrategy'], 'AsIs');
    expect(generated.containsKey(VpnConfig.syncedRoutingMetadataKey), isFalse);
    final rules = routing['rules'] as List<dynamic>;
    expect(
      rules.any((r) =>
          r is Map &&
          r['domain'] is List &&
          (r['domain'] as List).contains('geosite:cn')),
      isFalse,
    );

    final saved = await VpnConfig.generateFromVlessUri(
      vlessUri: _standardVlessUri,
      password: '',
      bundleId: 'plus.svc.xconnect',
      setMessage: (_) {},
      logMessage: (_) {},
    );
    expect(saved, isTrue);
    final savedNode = VpnConfig.getNodeByName('StandardNode');
    expect(savedNode, isNotNull);
    expect(savedNode!.routingPool, isNull);
    expect(savedNode.pricingGroup, isNull);
  });

  test(
      'applySyncedRoutingConfig is idempotent and orders tier rules before catch-all',
      () async {
    final raw =
        await VpnConfig.tryGenerateXrayJsonFromVlessUri(_standardVlessUri);
    final config = jsonDecode(raw!) as Map<String, dynamic>;
    final baseRuleCount =
        ((config['routing'] as Map)['rules'] as List<dynamic>).length;

    final tierRules = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'field',
        'domain': <String>['geosite:category-ads-all'],
        'outboundTag': 'block',
      },
      <String, dynamic>{
        'type': 'field',
        'domain': <String>['geosite:cn'],
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
        'outboundTag': 'proxy',
      },
    ];

    final firstChanged = VpnConfig.applySyncedRoutingConfig(
      config,
      routingRules: tierRules,
      domainStrategy: 'IPIfNonMatch',
      routingPool: 'plus',
      pricingGroup: 'pro',
    );
    expect(firstChanged, isTrue);
    expect((config['routing'] as Map)['domainStrategy'], 'IPIfNonMatch');
    final rulesAfterFirst =
        (config['routing'] as Map)['rules'] as List<dynamic>;
    expect(rulesAfterFirst, hasLength(baseRuleCount + 3));
    expect(rulesAfterFirst.last, {'type': 'field', 'outboundTag': 'proxy'});

    // Re-applying with equivalent rules (different key order) is a no-op.
    final reorderedKeysRules = <Map<String, dynamic>>[
      <String, dynamic>{
        'outboundTag': 'block',
        'domain': <String>['geosite:category-ads-all'],
        'type': 'field',
      },
      <String, dynamic>{
        'outboundTag': 'direct',
        'domain': <String>['geosite:cn'],
        'type': 'field',
      },
      <String, dynamic>{
        'outboundTag': 'proxy',
        'type': 'field',
      },
    ];
    final secondChanged = VpnConfig.applySyncedRoutingConfig(
      config,
      routingRules: reorderedKeysRules,
      domainStrategy: 'IPIfNonMatch',
    );
    expect(secondChanged, isFalse);
    expect(
      ((config['routing'] as Map)['rules'] as List<dynamic>),
      hasLength(baseRuleCount + 3),
    );

    // Updating rules replaces prior synced rules without duplicating.
    final updatedRules = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'field',
        'ip': <String>['geoip:cn'],
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'proxy',
      },
    ];
    final thirdChanged = VpnConfig.applySyncedRoutingConfig(
      config,
      routingRules: updatedRules,
      domainStrategy: 'IPIfNonMatch',
    );
    expect(thirdChanged, isTrue);
    final rulesAfterThird =
        (config['routing'] as Map)['rules'] as List<dynamic>;
    expect(rulesAfterThird, hasLength(baseRuleCount + 2));
    expect(
      rulesAfterThird.any((r) =>
          r is Map &&
          r['domain'] is List &&
          (r['domain'] as List).contains('geosite:cn')),
      isFalse,
    );
    expect(
      rulesAfterThird.last,
      {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
    );
  });

  test(
      'generateSyncedXrayJsonConfig layers tier rules and buildSecureDnsRoutingConfig preserves domainStrategy and rule ordering',
      () async {
    final syncedJson = await VpnConfig.generateSyncedXrayJsonConfig(
      _standardVlessUri,
      routingPool: 'team',
      pricingGroup: 'enterprise',
      domainStrategy: 'IPIfNonMatch',
      routingRules: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'field',
          'outboundTag': 'proxy',
        },
        <String, dynamic>{
          'type': 'field',
          'domain': <String>['geosite:cn'],
          'outboundTag': 'direct',
        },
        <String, dynamic>{
          'type': 'field',
          'ip': <String>['geoip:cn', 'fc00::/7'],
          'outboundTag': 'direct',
        },
      ],
    );
    expect(syncedJson, isNotNull);
    final decoded = jsonDecode(syncedJson!) as Map<String, dynamic>;
    final routing = decoded['routing'] as Map<String, dynamic>;
    expect(routing['domainStrategy'], 'IPIfNonMatch');

    // Re-running buildSecureDnsRoutingConfig (as connect preparation does)
    // must preserve IPIfNonMatch and keep tier rules before catch-all.
    final rebuilt = VpnConfig.buildSecureDnsRoutingConfig(
      routing,
      enableTunnelMode: true,
    );
    expect(rebuilt['domainStrategy'], 'IPIfNonMatch');
    final rebuiltRules = rebuilt['rules'] as List<dynamic>;
    final cnDomainIndex = rebuiltRules.indexWhere((r) =>
        r is Map &&
        r['domain'] is List &&
        (r['domain'] as List).contains('geosite:cn'));
    final cnIpIndex = rebuiltRules.indexWhere((r) =>
        r is Map && r['ip'] is List && (r['ip'] as List).contains('geoip:cn'));
    final catchAllIndex = rebuiltRules.indexWhere((r) =>
        r is Map &&
        r['outboundTag'] == 'proxy' &&
        r['domain'] == null &&
        r['ip'] == null &&
        r['inboundTag'] == null &&
        r['port'] == null);
    expect(cnDomainIndex, greaterThanOrEqualTo(0));
    expect(cnIpIndex, greaterThanOrEqualTo(0));
    expect(catchAllIndex, greaterThan(cnDomainIndex));
    expect(catchAllIndex, greaterThan(cnIpIndex));

    // When domainStrategy is omitted, buildSecureDnsRoutingConfig defaults to AsIs.
    final defaultRebuilt = VpnConfig.buildSecureDnsRoutingConfig(
      <String, dynamic>{'rules': <dynamic>[]},
      enableTunnelMode: true,
    );
    expect(defaultRebuilt['domainStrategy'], 'AsIs');
  });
}
