import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/app/darwin_host_api.g.dart' as darwin_host;
import 'package:xconnect/services/tuning/client_tuning.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';
import 'package:xconnect/utils/native_bridge.dart';

final _platform = Platform.operatingSystem;

Map<String, dynamic> _document() => <String, dynamic>{
      'version': 1,
      'revision': 'r1',
      'defaults': <String, dynamic>{
        'tunnel': <String, dynamic>{'goMemoryLimitMB': 64, 'goGCPercent': 40},
      },
      'platforms': <String, dynamic>{
        _platform: <String, dynamic>{
          'tunnel': <String, dynamic>{'goGCPercent': 30},
        },
      },
      'nodes': <String, dynamic>{
        'jp-1': <String, dynamic>{
          'tunnel': <String, dynamic>{'goMemoryLimitMB': 0},
          'xhttp': <String, dynamic>{'scMaxEachPostBytes': 500000},
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    XhttpAdvancedConfig.modeCustomized = false;
    XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized = false;
    ClientTuning.profileForTesting = null;
  });

  test('tunnel limits accept 0 or 32-256 MiB and a 20-200 GC percent', () {
    ClientTuningValues values(Object? limit, Object? gc) =>
        ClientTuningValues.fromJson(<String, dynamic>{
          'tunnel': <String, dynamic>{
            'goMemoryLimitMB': limit,
            'goGCPercent': gc,
          },
        });
    expect(values(0, 20).goMemoryLimitMB, 0);
    expect(values(32, 20).goMemoryLimitMB, 32);
    expect(values(256, 200).goMemoryLimitMB, 256);
    expect(values(256, 200).goGCPercent, 200);
    for (final invalid in <Object?>[31, 257, -1, '64', 64.5, null]) {
      expect(values(invalid, 40).goMemoryLimitMB, isNull, reason: '$invalid');
    }
    for (final invalid in <Object?>[0, 19, 201, '40']) {
      expect(values(64, invalid).goGCPercent, isNull, reason: '$invalid');
    }
  });

  test('tunnel tuning layers defaults, platform and node, and survives cache',
      () async {
    final profile = ClientTuningProfile.fromJson(_document())!;
    final cached =
        ClientTuningProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())))!;
    for (final p in <ClientTuningProfile>[profile, cached]) {
      final base = p.resolve(platform: _platform);
      expect(base.goMemoryLimitMB, 64);
      expect(base.goGCPercent, 30);
      final node = p.resolve(platform: _platform, nodeId: 'jp-1');
      expect(node.goMemoryLimitMB, 0);
      expect(node.goGCPercent, 30);
    }
  });

  test('the Darwin profile carries node-specific Go tuning only when tuned',
      () async {
    final untuned = await NativeBridge.buildDefaultTunnelProfileForTesting(
      configPath: '/tmp/node.runtime.json',
      nodeId: 'jp-1',
    );
    expect(untuned.nodeId, 'jp-1');
    expect(untuned.goMemoryLimitMB, isNull);
    expect(untuned.goGCPercent, isNull);

    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_document());
    final tuned = await NativeBridge.buildDefaultTunnelProfileForTesting(
      configPath: '/tmp/node.runtime.json',
      nodeId: 'jp-1',
    );
    expect(tuned.goMemoryLimitMB, 0);
    expect(tuned.goGCPercent, 30);
    final other = await NativeBridge.buildDefaultTunnelProfileForTesting(
      configPath: '/tmp/other.runtime.json',
      nodeId: 'us-1',
    );
    expect(other.goMemoryLimitMB, 64);
  });

  test('Pigeon round-trips the new profile and metrics fields', () {
    final profile = darwin_host.TunnelProfile(
      mtu: 1500,
      tun46Setting: 0,
      defaultNicSupport6: false,
      dnsServers4: <String>['1.1.1.1'],
      dnsServers6: <String>[],
      ipv4Addresses: <String>['10.0.0.2'],
      ipv4SubnetMasks: <String>['255.255.255.0'],
      ipv4IncludedRoutes: <darwin_host.TunnelRouteV4>[],
      ipv4ExcludedRoutes: <darwin_host.TunnelRouteV4>[],
      ipv6Addresses: <String>[],
      ipv6NetworkPrefixLengths: <int>[],
      ipv6IncludedRoutes: <darwin_host.TunnelRouteV6>[],
      ipv6ExcludedRoutes: <darwin_host.TunnelRouteV6>[],
      configPath: '/tmp/node.runtime.json',
      nodeId: 'jp-1',
      goMemoryLimitMB: 0,
      goGCPercent: 30,
    );
    final decoded = darwin_host.TunnelProfile.decode(profile.encode());
    expect(decoded.nodeId, 'jp-1');
    expect(decoded.goMemoryLimitMB, 0);
    expect(decoded.goGCPercent, 30);
    expect(decoded.configPath, '/tmp/node.runtime.json');

    final untunedDecoded =
        darwin_host.TunnelProfile.decode(darwin_host.TunnelProfile(
      mtu: 1500,
      tun46Setting: 0,
      defaultNicSupport6: false,
      dnsServers4: <String>[],
      dnsServers6: <String>[],
      ipv4Addresses: <String>[],
      ipv4SubnetMasks: <String>[],
      ipv4IncludedRoutes: <darwin_host.TunnelRouteV4>[],
      ipv4ExcludedRoutes: <darwin_host.TunnelRouteV4>[],
      ipv6Addresses: <String>[],
      ipv6NetworkPrefixLengths: <int>[],
      ipv6IncludedRoutes: <darwin_host.TunnelRouteV6>[],
      ipv6ExcludedRoutes: <darwin_host.TunnelRouteV6>[],
      configPath: '/tmp/x.json',
    ).encode());
    expect(untunedDecoded.goMemoryLimitMB, isNull);
    expect(untunedDecoded.nodeId, isNull);

    final metrics = darwin_host.TunnelMetricsSnapshot.decode(
      darwin_host.TunnelMetricsSnapshot(
        footprintBytes: 40 << 20,
        peakFootprintBytes: 48 << 20,
        goSysBytes: 20 << 20,
        goNumGC: 12,
        goMemoryLimitBytes: 0x7fffffffffffffff,
        goGCPercent: 30,
      ).encode(),
    );
    expect(metrics.peakFootprintBytes, 48 << 20);
    expect(metrics.goMemoryLimitBytes, 0x7fffffffffffffff);
    expect(metrics.goGCPercent, 30);

    final tuning = darwin_host.TunnelRuntimeTuning.decode(
        darwin_host.TunnelRuntimeTuning(goGCPercent: 30).encode());
    expect(tuning.goGCPercent, 30);
    expect(tuning.goMemoryLimitMB, isNull);
    final saved = darwin_host.SavedTunnelProfile.decode(
        darwin_host.SavedTunnelProfile(configPath: '/p', nodeId: 'jp-1')
            .encode());
    expect(saved.nodeId, 'jp-1');
  });

  test('withdrawing tuning rewrites the persisted runtime config in place', () {
    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_document());
    final runtime = <String, dynamic>{
      'dns': VpnConfig.buildSecureDnsConfig(),
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': <String, dynamic>{
            'vnext': <dynamic>[
              <String, dynamic>{'address': '203.0.113.7', 'port': 443},
            ],
          },
          'streamSettings': <String, dynamic>{
            'network': 'xhttp',
            'xhttpSettings': <String, dynamic>{
              'path': '/split',
              'extra': <String, dynamic>{'xmux': <String, dynamic>{}},
            },
          },
        },
      ],
    };
    VpnConfig.applyXhttpAdvancedSettings(runtime, nodeId: 'jp-1');
    final persisted = jsonEncode(runtime);
    expect(persisted, contains('500000'));

    ClientTuning.profileForTesting = null; // 404 or sign-out
    final rewritten =
        NativeBridge.rewritePersistedTunnelConfig(persisted, nodeId: 'jp-1');
    expect(rewritten, isNotNull);
    final config = jsonDecode(rewritten!) as Map<String, dynamic>;
    final outbound = (config['outbounds'] as List).first as Map;
    final extra = ((outbound['streamSettings'] as Map)['xhttpSettings']
        as Map)['extra'] as Map;
    expect(extra.containsKey('scMaxEachPostBytes'), isFalse);
    expect(config.containsKey(VpnConfig.tuningOverridesKey), isFalse);
    // The pinned node address is untouched.
    expect(((outbound['settings'] as Map)['vnext'] as List).first['address'],
        '203.0.113.7');
    // Already current: nothing to rewrite.
    expect(NativeBridge.rewritePersistedTunnelConfig(rewritten, nodeId: 'jp-1'),
        isNull);
  });

  test(
      'rewritePersistedTunnelConfig preserves synced routing rules and domainStrategy',
      () {
    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_document());
    final runtime = <String, dynamic>{
      'dns': VpnConfig.buildSecureDnsConfig(),
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': <String, dynamic>{
            'vnext': <dynamic>[
              <String, dynamic>{'address': '203.0.113.7', 'port': 443},
            ],
          },
          'streamSettings': <String, dynamic>{
            'network': 'xhttp',
            'xhttpSettings': <String, dynamic>{
              'path': '/split',
              'extra': <String, dynamic>{'xmux': <String, dynamic>{}},
            },
          },
        },
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'AsIs',
        'rules': <dynamic>[],
      },
    };
    final tierRules = <Map<String, dynamic>>[
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
    VpnConfig.applySyncedRoutingConfig(
      runtime,
      routingRules: tierRules,
      domainStrategy: 'IPIfNonMatch',
    );
    VpnConfig.applyXhttpAdvancedSettings(runtime, nodeId: 'jp-1');
    final persisted = jsonEncode(runtime);

    ClientTuning.profileForTesting = null;
    final rewritten =
        NativeBridge.rewritePersistedTunnelConfig(persisted, nodeId: 'jp-1');
    expect(rewritten, isNotNull);
    final decoded = jsonDecode(rewritten!) as Map<String, dynamic>;
    final routing = decoded['routing'] as Map<String, dynamic>;
    expect(routing['domainStrategy'], 'IPIfNonMatch');
    expect(routing['rules'], containsAllInOrder(tierRules));
    expect(decoded[VpnConfig.syncedRoutingMetadataKey], isNotNull);
    expect(NativeBridge.rewritePersistedTunnelConfig(rewritten, nodeId: 'jp-1'),
        isNull);
  });
}
