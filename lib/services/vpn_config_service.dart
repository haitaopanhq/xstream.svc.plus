// lib/services/vpn_config_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../utils/global_config.dart';
import '../utils/native_bridge.dart';
import '../utils/tun_config_guard.dart';
import '../utils/validators.dart';
import '../templates/xray_config_template.dart';
import '../templates/xray_service_macos_template.dart';
import '../templates/xray_service_linux_template.dart';
import '../templates/xray_service_windows_template.dart';
import 'sqlite_node_store.dart';
import 'dns/dns_control_plane.dart';
import 'session/network_access_policy.dart';
import 'tunnel_endpoint_resolver.dart';
import 'tuning/client_tuning.dart';

class VlessUriProfile {
  final String name;
  final String domain;
  final String port;
  final String uuid;
  final String protocol;
  final String network;
  final String security;
  final String? sni;
  final String? fingerprint;
  final String? flow;
  final String? host;
  final String? path;
  final String? mode;
  final List<String> alpn;

  const VlessUriProfile({
    required this.name,
    required this.domain,
    required this.port,
    required this.uuid,
    this.protocol = 'vless',
    this.network = 'tcp',
    this.security = 'tls',
    this.sni,
    this.fingerprint,
    this.flow,
    this.host,
    this.path,
    this.mode,
    this.alpn = const [],
  });
}

class XhttpAdvancedConfigApplyResult {
  final bool foundXhttp;
  final bool changed;

  const XhttpAdvancedConfigApplyResult({
    required this.foundXhttp,
    required this.changed,
  });
}

class VpnNode {
  bool get isManaged =>
      serviceName == 'xconnect.desktop.sync' ||
      serviceName.startsWith('xconnect.sync.') ||
      managedOwner != null ||
      managedTeamId != null ||
      managedNodeId != null;

  String name;
  String countryCode;
  String configPath;

  /// Cross-platform service identifier
  ///
  /// - macOS: LaunchAgent plist file name
  /// - Linux: systemd service name
  /// - Windows: SC service name
  String serviceName;
  String protocol;
  String transport;
  String security;
  bool enabled;
  String? managedOwner;
  String? managedTeamId;
  String? managedNodeId;
  String? routingPool;
  String? pricingGroup;

  VpnNode({
    required this.name,
    required this.countryCode,
    required this.configPath,
    required this.serviceName,
    this.protocol = '',
    this.transport = '',
    this.security = '',
    this.enabled = true,
    this.managedOwner,
    this.managedTeamId,
    this.managedNodeId,
    this.routingPool,
    this.pricingGroup,
  }) {
    checkNotEmpty(name, 'name');
    checkNotEmpty(countryCode, 'countryCode');
    checkNotEmpty(configPath, 'configPath');
    checkNotEmpty(serviceName, 'serviceName');
  }

  static String? _nullableField(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  factory VpnNode.fromJson(Map<String, dynamic> json) {
    final name = json['name'] ?? '';
    final countryCode = json['countryCode'] ?? '';
    final configPath = json['configPath'] ?? '';
    final serviceName = json['serviceName'] ?? json['plistName'] ?? '';
    final protocol = json['protocol'] ?? '';
    final transport = json['transport'] ?? '';
    final security = json['security'] ?? '';

    checkNotEmpty(name, 'name');
    checkNotEmpty(countryCode, 'countryCode');
    checkNotEmpty(configPath, 'configPath');
    checkNotEmpty(serviceName, 'serviceName');

    return VpnNode(
      name: name,
      countryCode: countryCode,
      configPath: configPath,
      serviceName: serviceName,
      protocol: protocol,
      transport: transport,
      security: security,
      enabled: json['enabled'] ?? true,
      managedOwner: json['managedOwner'] as String?,
      managedTeamId: json['managedTeamId'] as String?,
      managedNodeId: json['managedNodeId'] as String?,
      routingPool: _nullableField(json['routingPool'] ?? json['routing_pool']),
      pricingGroup:
          _nullableField(json['pricingGroup'] ?? json['pricing_group']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'countryCode': countryCode,
      'configPath': configPath,
      'serviceName': serviceName,
      'protocol': protocol,
      'transport': transport,
      'security': security,
      'enabled': enabled,
      'managedOwner': managedOwner,
      'managedTeamId': managedTeamId,
      'managedNodeId': managedNodeId,
      'routingPool': routingPool,
      'pricingGroup': pricingGroup,
    };
  }
}

class VpnConfig {
  static const legacyCompatibilityNodeName = 'tky-proxy.svc.plus';
  static const _regionalNodeCodes = ['jp', 'ph', 'sg', 'us'];
  static const _tunInboundTag = 'tun-in';
  static const _socksInboundTag = 'socks-in';
  static const _httpInboundTag = 'http-in';
  static const _dnsDirectPrimaryTag = 'dns-direct-primary';
  static const _dnsDirectSecondaryTag = 'dns-direct-secondary';
  static const _dnsProxyPrimaryTag = 'dns-proxy-primary';
  static const _dnsProxySecondaryTag = 'dns-proxy-secondary';

  static List<VpnNode> _nodes = [];

  static bool get _requiresServiceDefinition {
    return !(Platform.isIOS || Platform.isAndroid);
  }

  static Future<String> getConfigPath() async {
    return await GlobalApplicationConfig.getLocalConfigPath();
  }

  static Future<void> load() async {
    List<VpnNode> fromLocal = [];

    // SQLite is the primary source of truth.
    try {
      final fromDb = await SqliteNodeStore.loadNodes();
      if (fromDb.isNotEmpty) {
        final loaded = fromDb.map((e) => VpnNode.fromJson(e)).toList();
        _nodes = loaded
            .where((node) => !isLegacyCompatibilityNodeName(node.name))
            .toList();
        final restoredRegions = await _restoreRegionalConfigs();
        if (_nodes.length != loaded.length || restoredRegions) {
          await saveToFile();
        }
        return;
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load sqlite nodes: $e');
    }

    try {
      final path = await GlobalApplicationConfig.getLocalConfigPath();
      final file = File(path);
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final List<dynamic> jsonList = json.decode(jsonStr);
        fromLocal = jsonList.map((e) => VpnNode.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load local vpn_nodes.json: $e');
    }

    _nodes = fromLocal
        .where((node) => !isLegacyCompatibilityNodeName(node.name))
        .toList();
    final restoredRegions = await _restoreRegionalConfigs();
    if (_nodes.isNotEmpty ||
        _nodes.length != fromLocal.length ||
        restoredRegions) {
      try {
        await saveToFile();
      } catch (e) {
        debugPrint('⚠️ Failed to migrate vpn_nodes.json to sqlite: $e');
      }
    }
  }

  static bool isLegacyCompatibilityNodeName(String name) =>
      name.trim().toLowerCase() == legacyCompatibilityNodeName;

  /// Re-register regional configs left on disk when an older sync pruned only
  /// their SQLite rows. Explicit node deletion removes the config file too, so
  /// this only recovers regions that still have a usable saved config.
  static Future<bool> _restoreRegionalConfigs() async {
    if (NetworkAccessPolicy.instance.dedicated) return false;
    var changed = false;
    final configDirectory = await GlobalApplicationConfig.getConfigsPath();
    for (final code in _regionalNodeCodes) {
      final file = File('$configDirectory/node-$code-config.json');
      if (!await file.exists()) continue;

      final existingByName = _nodes.indexWhere(
        (node) => node.name.toLowerCase() == code,
      );
      if (existingByName >= 0) continue;

      Map<String, dynamic> root;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        root = decoded;
      } catch (_) {
        continue;
      }
      final outbounds = root['outbounds'];
      if (outbounds is! List) continue;
      Map? proxy;
      for (final outbound in outbounds) {
        if (outbound is Map && outbound['tag'] == 'proxy') {
          proxy = outbound;
          break;
        }
      }
      if (proxy == null) continue;
      final stream = proxy['streamSettings'];
      final existingByPath = _nodes.indexWhere(
        (node) => File(node.configPath).absolute.path == file.absolute.path,
      );
      final existing = existingByPath >= 0 ? _nodes[existingByPath] : null;
      if (existingByPath >= 0) {
        _nodes.removeAt(existingByPath);
      }
      _nodes.add(
        VpnNode(
          name: code,
          countryCode: code.toUpperCase(),
          configPath: file.path,
          serviceName: existing?.serviceName ??
              await GlobalApplicationConfig.serviceNameForRegion(code),
          protocol: proxy['protocol'] as String? ?? '',
          transport: stream is Map ? stream['network'] as String? ?? '' : '',
          security: stream is Map ? stream['security'] as String? ?? '' : '',
          enabled: existing?.enabled ?? true,
        ),
      );
      changed = true;
    }
    return changed;
  }

  static List<VpnNode> get allNodes => List.unmodifiable(_nodes);
  static bool canUseNode(VpnNode node) => NetworkAccessPolicy.instance.canUse(
        serviceName: node.serviceName,
        nodeOwner: node.managedOwner,
        nodeTeamId: node.managedTeamId,
        nodeId: node.managedNodeId,
      );
  static List<VpnNode> get nodes {
    final visible = _nodes.where(canUseNode).toList();
    // Preserve user import order within each source; automatic account sync
    // must not displace custom connections as the default selection.
    return [
      ...visible.where((node) => !node.isManaged),
      ...visible.where((node) => node.isManaged),
    ];
  }

  static VpnNode? getNodeByName(String name) {
    checkNotEmpty(name, 'name');
    try {
      return _nodes.firstWhere((e) => e.name == name);
    } catch (_) {
      return null;
    }
  }

  static void addNode(VpnNode node) {
    checkNotEmpty(node.name, 'node.name');
    if (isLegacyCompatibilityNodeName(node.name)) return;
    _nodes.add(node);
  }

  static void removeNode(String name) {
    checkNotEmpty(name, 'name');
    _nodes.removeWhere((e) => e.name == name);
  }

  static void updateNode(VpnNode updated) {
    checkNotEmpty(updated.name, 'updated.name');
    if (isLegacyCompatibilityNodeName(updated.name)) {
      removeNode(updated.name);
      return;
    }
    final index = _nodes.indexWhere((e) => e.name == updated.name);
    if (index != -1) {
      _nodes[index] = updated;
    }
  }

  static String exportToJson() {
    return json.encode(_nodes.map((e) => e.toJson()).toList());
  }

  static Future<String> saveToFile() async {
    final path = await GlobalApplicationConfig.getLocalConfigPath();
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(exportToJson());
    try {
      await SqliteNodeStore.replaceAll(_nodes.map((e) => e.toJson()).toList());
    } catch (e) {
      debugPrint('⚠️ Failed to persist sqlite nodes: $e');
    }
    return path;
  }

  static Future<void> importFromJson(String jsonStr) async {
    checkNotEmpty(jsonStr, 'jsonStr');
    final List<dynamic> jsonList = json.decode(jsonStr);
    _nodes = jsonList
        .map((e) => VpnNode.fromJson(e))
        .where((node) => !isLegacyCompatibilityNodeName(node.name))
        .toList();
    await saveToFile();
  }

  static Future<void> deleteNodeFiles(VpnNode node) async {
    checkNotEmpty(node.name, 'node.name');
    checkNotEmpty(node.configPath, 'node.configPath');
    checkNotEmpty(node.serviceName, 'node.serviceName');
    try {
      final jsonFile = File(node.configPath);
      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }

      final servicePath = await GlobalApplicationConfig.getServicePath(
        node.serviceName,
      );
      final serviceFile = File(servicePath);
      if (await serviceFile.exists()) {
        await serviceFile.delete();
      }

      removeNode(node.name);
      await saveToFile();
      try {
        await SqliteNodeStore.deleteNode(node.name);
      } catch (e) {
        debugPrint('⚠️ 删除 sqlite 节点失败: $e');
      }
    } catch (e) {
      debugPrint('⚠️ 删除节点文件失败: $e');
    }
  }

  static Future<void> generateDefaultNodes({
    required String password,
    required Function(String) setMessage,
    required Function(String) logMessage,
  }) async {
    checkNotNull(setMessage, 'setMessage');
    checkNotNull(logMessage, 'logMessage');
    final bundleId = await GlobalApplicationConfig.getBundleId();

    const port = '1443';
    const uuid = '18d270a9-533d-4b13-b3f1-e7f55540a9b2';
    const nodes = [
      {'name': 'Global-Node', 'domain': 'trial-connector.onwalk.net'},
    ];

    for (final node in nodes) {
      await generateContent(
        nodeName: node['name']!,
        domain: node['domain']!,
        port: port,
        uuid: uuid,
        password: password,
        bundleId: bundleId,
        setMessage: setMessage,
        logMessage: logMessage,
      );
    }

    // Reload nodes from file to keep in-memory list in sync
    await load();
  }

  static Future<bool> generateContent({
    required String nodeName,
    required String domain,
    required String port,
    required String uuid,
    required String password,
    required String bundleId,
    required Function(String) setMessage,
    required Function(String) logMessage,
    String protocol = 'vless',
    String network = 'tcp',
    String security = 'tls',
    String? sni,
    String? fingerprint = 'chrome',
    String? flow = 'xtls-rprx-vision',
    String? host,
    String? path,
    String? mode,
    List<String> alpn = const [],
    bool enableSocksProxy = true,
    bool enableHttpProxy = true,
    bool enableTunnelMode = true,
    void Function(String)? onSaved,
  }) async {
    checkNotEmpty(nodeName, 'nodeName');
    checkNotEmpty(domain, 'domain');
    checkNotEmpty(port, 'port');
    checkNotEmpty(uuid, 'uuid');

    checkNotEmpty(bundleId, 'bundleId');
    checkNotNull(setMessage, 'setMessage');
    checkNotNull(logMessage, 'logMessage');
    checkNotEmpty(protocol, 'protocol');
    checkNotEmpty(network, 'network');
    checkNotEmpty(security, 'security');
    final normalizedProtocol = protocol.trim().toLowerCase();
    final normalizedNetwork = network.trim().toLowerCase();
    final normalizedSecurity = security.trim().toLowerCase();
    // Each user import owns its files, even when names share a prefix or
    // collide with a managed profile. Never overwrite an existing connection.
    final originalName = nodeName;
    var suffix = 2;
    if (isLegacyCompatibilityNodeName(nodeName)) {
      nodeName = '$originalName (${suffix++})';
    }
    while (getNodeByName(nodeName) != null) {
      nodeName = '$originalName (${suffix++})';
    }
    final random = Random.secure();
    final code =
        'custom-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final prefix = await GlobalApplicationConfig.getXrayConfigPath();
    final xrayConfigPath = '${prefix}node-$code-config.json';

    final generatedXrayConfigContent = await _generateXrayJsonConfig(
      domain,
      port,
      uuid,
      setMessage,
      logMessage,
      protocol: normalizedProtocol,
      network: normalizedNetwork,
      security: normalizedSecurity,
      sni: sni,
      fingerprint: fingerprint,
      flow: flow,
      host: host,
      path: path,
      mode: mode,
      alpn: alpn,
      enableSocksProxy: enableSocksProxy,
      enableHttpProxy: enableHttpProxy,
      enableTunnelMode: enableTunnelMode,
    );
    if (generatedXrayConfigContent.isEmpty) return false;
    final guarded = guardTunInterfaceFieldsForWrite(generatedXrayConfigContent);
    final xrayConfigContent = guarded.json;
    if (guarded.removedFields > 0) {
      logMessage(
        '⚠️ Removed ${guarded.removedFields} invalid tun interface field(s) before writing config.json',
      );
    }

    final serviceName = await GlobalApplicationConfig.serviceNameForRegion(
      code,
    );
    final servicePath = await GlobalApplicationConfig.getServicePath(
      serviceName,
    );

    var serviceContent = await _generateServiceContent(
      code,
      bundleId,
      xrayConfigPath,
      serviceName,
    );
    if (serviceContent.isEmpty) {
      if (_requiresServiceDefinition) return false;
      serviceContent = '# XConnect mobile node marker for $nodeName\n';
    }

    final vpnNodesConfigPath =
        await GlobalApplicationConfig.getLocalConfigPath();
    final vpnNodesConfigContent = await _generateVpnNodesJsonContent(
      nodeName,
      originalName.split('-').first.toUpperCase(),
      serviceName,
      xrayConfigPath,
      setMessage,
      logMessage,
      protocol: normalizedProtocol,
      transport: normalizedNetwork,
      security: normalizedSecurity,
    );

    try {
      final writeResult = await NativeBridge.writeConfigFiles(
        xrayConfigPath: xrayConfigPath,
        xrayConfigContent: xrayConfigContent,
        servicePath: servicePath,
        serviceContent: serviceContent,
        vpnNodesConfigPath: vpnNodesConfigPath,
        vpnNodesConfigContent: vpnNodesConfigContent,
        password: password,
      );
      if (!writeResult.toLowerCase().startsWith('success')) {
        throw StateError(writeResult);
      }

      await SqliteNodeStore.replaceAll(
        (jsonDecode(vpnNodesConfigContent) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
      // Reload nodes from file so that the in-memory list stays updated
      await load();
      setMessage('✅ 配置已保存: $xrayConfigPath');
      logMessage('配置已成功保存并生成');
      onSaved?.call(nodeName);
      return true;
    } catch (e) {
      setMessage('生成配置失败: $e');
      logMessage('生成配置失败: $e');
      return false;
    }
  }

  static VlessUriProfile parseVlessUri(
    String rawUri, {
    String? fallbackNodeName,
  }) {
    checkNotEmpty(rawUri, 'rawUri');
    final trimmed = rawUri.trim();
    final uri = Uri.parse(trimmed);
    if (uri.scheme.toLowerCase() != 'vless') {
      throw const FormatException('Only vless:// links are supported');
    }

    final uuid = uri.userInfo.trim();
    final domain = uri.host.trim();
    if (uuid.isEmpty || domain.isEmpty) {
      throw const FormatException('Invalid vless:// link');
    }

    final query = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      query[key.toLowerCase()] = value.trim();
    });

    final uriName = Uri.decodeComponent(uri.fragment).trim();
    final nameCandidate = _firstNonEmpty(uriName, fallbackNodeName, domain);
    final network = _firstNonEmpty(query['type'], 'tcp').toLowerCase();
    final security = _firstNonEmpty(query['security'], 'tls').toLowerCase();
    final alpn = (query['alpn'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return VlessUriProfile(
      name: nameCandidate,
      domain: domain,
      port: uri.hasPort ? uri.port.toString() : '443',
      uuid: uuid,
      network: network,
      security: security,
      sni: _nullableValue(query['sni']),
      fingerprint: _nullableValue(query['fp'] ?? query['fingerprint']),
      flow: _nullableValue(query['flow']),
      host: _nullableValue(query['host']),
      path: _normalizePath(_nullableValue(query['path'])),
      mode: _nullableValue(query['mode']),
      alpn: alpn,
    );
  }

  static Future<bool> generateFromVlessUri({
    required String vlessUri,
    String? fallbackNodeName,
    required String password,
    required String bundleId,
    required Function(String) setMessage,
    required Function(String) logMessage,
    bool enableSocksProxy = true,
    bool enableHttpProxy = true,
    bool enableTunnelMode = true,
    void Function(String)? onSaved,
  }) async {
    final profile = parseVlessUri(vlessUri, fallbackNodeName: fallbackNodeName);
    return await generateContent(
      nodeName: profile.name,
      onSaved: onSaved,
      domain: profile.domain,
      port: profile.port,
      uuid: profile.uuid,
      password: password,
      bundleId: bundleId,
      setMessage: setMessage,
      logMessage: logMessage,
      protocol: profile.protocol,
      network: profile.network,
      security: profile.security,
      sni: profile.sni,
      fingerprint: profile.fingerprint,
      flow: profile.flow,
      host: profile.host,
      path: profile.path,
      mode: profile.mode,
      alpn: profile.alpn,
      enableSocksProxy: enableSocksProxy,
      enableHttpProxy: enableHttpProxy,
      enableTunnelMode: enableTunnelMode,
    );
  }

  static Future<String?> tryGenerateXrayJsonFromVlessUri(
    String vlessUri,
  ) async {
    try {
      final profile = parseVlessUri(vlessUri);
      final logs = <String>[];
      final json = await _generateXrayJsonConfig(
        profile.domain,
        profile.port,
        profile.uuid,
        (_) {},
        (msg) => logs.add(msg),
        protocol: profile.protocol,
        network: profile.network,
        security: profile.security,
        sni: profile.sni,
        fingerprint: profile.fingerprint,
        flow: profile.flow,
        host: profile.host,
        path: profile.path,
        mode: profile.mode,
        alpn: profile.alpn,
      );
      if (json.trim().isEmpty) return null;
      return json;
    } catch (_) {
      return null;
    }
  }

  /// Top-level metadata key recording server-synced routing overrides so
  /// repeated syncs remain idempotent without mutating manual imports.
  static const syncedRoutingMetadataKey = 'xconnectSyncedRouting';

  /// Generates Xray JSON for a synced node by layering optional server-supplied
  /// tier routing rules and `domainStrategy` onto the standard VLESS config.
  static Future<String?> generateSyncedXrayJsonConfig(
    String vlessUri, {
    List<dynamic> routingRules = const [],
    String? domainStrategy,
    String? routingPool,
    String? pricingGroup,
    Map<dynamic, dynamic>? routing,
  }) async {
    final baseJson = await tryGenerateXrayJsonFromVlessUri(vlessUri);
    if (baseJson == null || baseJson.trim().isEmpty) return null;
    final hasStrategy = (domainStrategy ?? '').trim().isNotEmpty;
    if (routingRules.isEmpty && !hasStrategy && routing == null) {
      return baseJson;
    }
    try {
      final decoded = jsonDecode(baseJson);
      if (decoded is! Map) return baseJson;
      final config = _deepNormalizeMap(decoded);
      final changed = applySyncedRoutingConfig(
        config,
        routingRules: routingRules,
        domainStrategy: domainStrategy,
        routingPool: routingPool,
        pricingGroup: pricingGroup,
        routing: routing,
      );
      if (!changed) return baseJson;
      return const JsonEncoder.withIndent('  ').convert(config);
    } catch (_) {
      return baseJson;
    }
  }

  /// Idempotently applies server-supplied client routing rules and
  /// `domainStrategy` onto [config], keeping specific/tier rules ordered
  /// before any catch-all rule and avoiding rule duplication across re-syncs.
  static bool applySyncedRoutingConfig(
    Map<String, dynamic> config, {
    List<dynamic> routingRules = const [],
    String? domainStrategy,
    String? routingPool,
    String? pricingGroup,
    Map<dynamic, dynamic>? routing,
  }) {
    final routingParam = routing == null ? null : _deepNormalizeMap(routing);
    final effectiveDomainStrategy = _firstNonEmptyNullable(
      domainStrategy,
      routingParam?['domainStrategy'] as String? ??
          routingParam?['domain_strategy'] as String?,
    );
    final rawIncomingRules = routingRules.isNotEmpty
        ? routingRules
        : (routingParam?['rules'] as List<dynamic>? ??
            routingParam?['routing_rules'] as List<dynamic>? ??
            routingParam?['routingRules'] as List<dynamic>? ??
            const <dynamic>[]);
    final normalizedIncomingRules = rawIncomingRules
        .whereType<Map>()
        .map((rule) => _deepNormalizeMap(rule))
        .where((rule) => rule.isNotEmpty)
        .toList();

    final prevMetaRaw = config[syncedRoutingMetadataKey];
    final prevMeta = prevMetaRaw is Map ? _deepNormalizeMap(prevMetaRaw) : null;
    if (normalizedIncomingRules.isEmpty &&
        effectiveDomainStrategy == null &&
        prevMeta == null) {
      return false;
    }

    final beforeRouting = _canonicalJsonKey(config['routing']);
    final beforeMeta = _canonicalJsonKey(config[syncedRoutingMetadataKey]);

    final currentRouting = config['routing'] is Map
        ? _deepNormalizeMap(config['routing'] as Map)
        : <String, dynamic>{};
    final existingRawRules = List<dynamic>.from(
      currentRouting['rules'] as List<dynamic>? ?? const <dynamic>[],
    );

    final prevRuleKeys = <String>{};
    if (prevMeta != null && prevMeta['rules'] is List) {
      for (final rule in prevMeta['rules'] as List) {
        if (rule is Map) {
          prevRuleKeys.add(_canonicalJsonKey(rule));
        }
      }
    }

    final baseSpecificRules = <dynamic>[];
    final baseCatchAllRules = <dynamic>[];
    final seenKeys = <String>{};
    for (final rawRule in existingRawRules) {
      final normalizedRule =
          rawRule is Map ? _deepNormalizeMap(rawRule) : rawRule;
      if (normalizedRule is Map) {
        final key = _canonicalJsonKey(normalizedRule);
        if (prevRuleKeys.contains(key)) {
          continue;
        }
        if (!seenKeys.add(key)) {
          continue;
        }
      }
      if (_isCatchAllRoutingRule(normalizedRule)) {
        baseCatchAllRules.add(normalizedRule);
      } else {
        baseSpecificRules.add(normalizedRule);
      }
    }

    final syncedSpecificRules = <Map<String, dynamic>>[];
    final syncedCatchAllRules = <Map<String, dynamic>>[];
    final appliedRules = <Map<String, dynamic>>[];
    for (final rule in normalizedIncomingRules) {
      final key = _canonicalJsonKey(rule);
      appliedRules.add(rule);
      if (!seenKeys.add(key)) {
        continue;
      }
      if (_isCatchAllRoutingRule(rule)) {
        syncedCatchAllRules.add(rule);
      } else {
        syncedSpecificRules.add(rule);
      }
    }

    currentRouting['rules'] = <dynamic>[
      ...baseSpecificRules,
      ...syncedSpecificRules,
      ...baseCatchAllRules,
      ...syncedCatchAllRules,
    ];

    String? originalDomainStrategy =
        prevMeta?['originalDomainStrategy'] as String?;
    if (effectiveDomainStrategy != null) {
      originalDomainStrategy ??=
          _firstNonEmptyNullable(currentRouting['domainStrategy'] as String?);
      currentRouting['domainStrategy'] = effectiveDomainStrategy;
    } else if (prevMeta != null) {
      final prevAppliedStrategy =
          _firstNonEmptyNullable(prevMeta['domainStrategy'] as String?);
      final currentStrategy =
          _firstNonEmptyNullable(currentRouting['domainStrategy'] as String?);
      if (prevAppliedStrategy != null &&
          currentStrategy == prevAppliedStrategy) {
        currentRouting['domainStrategy'] = originalDomainStrategy ?? 'AsIs';
      }
    }

    final nextMeta = (appliedRules.isEmpty && effectiveDomainStrategy == null)
        ? null
        : <String, dynamic>{
            if (effectiveDomainStrategy != null)
              'domainStrategy': effectiveDomainStrategy,
            if (originalDomainStrategy != null)
              'originalDomainStrategy': originalDomainStrategy,
            if (appliedRules.isNotEmpty) 'rules': appliedRules,
          };

    final routingChanged = _canonicalJsonKey(currentRouting) != beforeRouting;
    final metaChanged = _canonicalJsonKey(nextMeta) != beforeMeta;
    if (!routingChanged && !metaChanged) {
      return false;
    }

    config['routing'] = currentRouting;
    if (nextMeta == null) {
      config.remove(syncedRoutingMetadataKey);
    } else {
      config[syncedRoutingMetadataKey] = nextMeta;
    }
    return true;
  }

  static String? _firstNonEmptyNullable(String? first, [String? second]) {
    if (first != null && first.trim().isNotEmpty) return first.trim();
    if (second != null && second.trim().isNotEmpty) return second.trim();
    return null;
  }

  static Map<String, dynamic> _deepNormalizeMap(Map<dynamic, dynamic> raw) {
    final result = <String, dynamic>{};
    raw.forEach((key, value) {
      if (key == null) return;
      result[key.toString()] = _deepNormalizeValue(value);
    });
    return result;
  }

  static dynamic _deepNormalizeValue(Object? value) {
    if (value is Map) {
      return _deepNormalizeMap(value);
    }
    if (value is List) {
      return value.map(_deepNormalizeValue).toList();
    }
    return value;
  }

  static Object? _canonicalizeForJson(Object? value) {
    if (value is Map) {
      final entries = value.entries
          .map((e) => MapEntry(e.key.toString(), _canonicalizeForJson(e.value)))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return Map<String, dynamic>.fromEntries(entries);
    }
    if (value is List) {
      return value.map(_canonicalizeForJson).toList();
    }
    return value;
  }

  static String _canonicalJsonKey(Object? value) =>
      jsonEncode(_canonicalizeForJson(value));

  static bool _isCatchAllRoutingRule(Object? rule) {
    if (rule is! Map) return false;
    final type = rule['type'];
    if (type != null && type != 'field') return false;
    final outboundTag = rule['outboundTag'];
    final balancerTag = rule['balancerTag'];
    final hasTarget =
        (outboundTag is String && outboundTag.trim().isNotEmpty) ||
            (balancerTag is String && balancerTag.trim().isNotEmpty);
    if (!hasTarget) return false;

    for (final listKey in const [
      'domain',
      'ip',
      'source',
      'user',
      'inboundTag',
      'protocol',
    ]) {
      final value = rule[listKey];
      if (value is List && value.isNotEmpty) {
        return false;
      }
    }

    final attrs = rule['attrs'];
    if (attrs is Map && attrs.isNotEmpty) return false;
    if (attrs is String && attrs.trim().isNotEmpty) return false;

    for (final portKey in const ['port', 'sourcePort']) {
      final port = rule[portKey];
      if (port == null) continue;
      final normalized = port.toString().trim();
      if (normalized.isNotEmpty &&
          normalized != '0-65535' &&
          normalized != '1-65535') {
        return false;
      }
    }

    final network = rule['network'];
    if (network is String && network.trim().isNotEmpty) {
      final parts = network
          .split(',')
          .map((p) => p.trim().toLowerCase())
          .where((p) => p.isNotEmpty)
          .toSet();
      if (!(parts.contains('tcp') && parts.contains('udp'))) {
        return false;
      }
    }

    return true;
  }

  static Future<String> _generateXrayJsonConfig(
    String domain,
    String port,
    String uuid,
    Function(String) setMessage,
    Function(String) logMessage, {
    String protocol = 'vless',
    String network = 'tcp',
    String security = 'tls',
    String? sni,
    String? fingerprint = 'chrome',
    String? flow = 'xtls-rprx-vision',
    String? host,
    String? path,
    String? mode,
    List<String> alpn = const [],
    bool enableSocksProxy = true,
    bool enableHttpProxy = true,
    bool enableTunnelMode = true,
  }) async {
    checkNotEmpty(domain, 'domain');
    checkNotEmpty(port, 'port');
    checkNotEmpty(uuid, 'uuid');
    checkNotNull(setMessage, 'setMessage');
    checkNotNull(logMessage, 'logMessage');

    // Generate inbounds configuration based on proxy and tunnel settings
    final inboundsConfig = generateInboundsConfig(
      enableSocksProxy: enableSocksProxy,
      enableHttpProxy: enableHttpProxy,
      enableTunnelMode: enableTunnelMode,
    );

    try {
      final replaced = defaultXrayJsonTemplate
          .replaceAll('<SERVER_DOMAIN>', domain)
          .replaceAll('<PORT>', port)
          .replaceAll('<UUID>', uuid)
          .replaceAll('<FLOW>', DnsConfig.normalizeVisionFlow(flow))
          .replaceAll('<INBOUNDS_CONFIG>', inboundsConfig);

      final jsonObj = Map<String, dynamic>.from(jsonDecode(replaced));
      final outbounds = List<dynamic>.from(
        (jsonObj['outbounds'] as List<dynamic>? ?? const []),
      );
      final proxyIndex = outbounds.indexWhere((e) {
        if (e is! Map) return false;
        return e['tag'] == 'proxy';
      });
      if (proxyIndex < 0) {
        throw const FormatException('Invalid xray outbound template');
      }

      final proxyOutbound = Map<String, dynamic>.from(
        outbounds[proxyIndex] as Map,
      );
      outbounds[proxyIndex] = proxyOutbound;
      jsonObj['outbounds'] = outbounds;
      final normalizedNetwork = network.trim().toLowerCase();
      final normalizedSecurity = security.trim().toLowerCase();
      final requestedAlpn = alpn
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
      final effectiveTlsAlpn = normalizedNetwork == 'xhttp'
          ? List<String>.from(XhttpAdvancedConfig.alpn.value)
          : requestedAlpn;
      final effectiveXhttpMode = normalizedNetwork == 'xhttp'
          ? XhttpAdvancedConfig.mode.value
          : _nullableValue(mode);

      proxyOutbound['protocol'] = protocol;
      final settings = Map<String, dynamic>.from(
        proxyOutbound['settings'] as Map? ?? const {},
      );
      proxyOutbound['settings'] = settings;
      final vnext = List<dynamic>.from(
        settings['vnext'] as List<dynamic>? ?? const [],
      );
      if (vnext.isEmpty) {
        throw const FormatException('Invalid vnext template');
      }

      final firstVnext = Map<String, dynamic>.from(vnext.first as Map);
      vnext[0] = firstVnext;
      settings['vnext'] = vnext;
      firstVnext['address'] = domain;
      firstVnext['port'] = int.tryParse(port) ?? 443;

      final users = List<dynamic>.from(
        firstVnext['users'] as List<dynamic>? ?? const [],
      );
      if (users.isEmpty) {
        throw const FormatException('Invalid users template');
      }
      final firstUser = Map<String, dynamic>.from(users.first as Map);
      users[0] = firstUser;
      firstVnext['users'] = users;
      firstUser['id'] = uuid;
      firstUser['encryption'] = 'none';
      final supportsVisionFlow = _supportsVisionFlow(
        protocol: protocol,
        network: normalizedNetwork,
        security: normalizedSecurity,
      );
      final effectiveFlow =
          supportsVisionFlow ? DnsConfig.normalizeVisionFlow(flow) : '';
      if (effectiveFlow.isNotEmpty) {
        firstUser['flow'] = effectiveFlow;
      } else {
        firstUser.remove('flow');
      }

      final streamSettings = Map<String, dynamic>.from(
        proxyOutbound['streamSettings'] as Map? ?? const {},
      );
      proxyOutbound['streamSettings'] = streamSettings;
      streamSettings['network'] = normalizedNetwork;
      streamSettings['security'] = normalizedSecurity;
      streamSettings.remove('xhttpSettings');

      if (normalizedSecurity == 'tls') {
        final tlsSettings = Map<String, dynamic>.from(
          streamSettings['tlsSettings'] as Map? ?? const {},
        );
        tlsSettings['allowInsecure'] = false;
        tlsSettings['serverName'] = _firstNonEmpty(sni, domain);
        if (_hasValue(fingerprint)) {
          tlsSettings['fingerprint'] = fingerprint!.trim();
        } else {
          tlsSettings.remove('fingerprint');
        }
        if (effectiveTlsAlpn.isNotEmpty) {
          tlsSettings['alpn'] = effectiveTlsAlpn;
        } else {
          tlsSettings.remove('alpn');
        }
        streamSettings['tlsSettings'] = tlsSettings;
      } else {
        streamSettings.remove('tlsSettings');
      }

      if (normalizedNetwork == 'xhttp') {
        final xhttpSettings = <String, dynamic>{
          'path': _firstNonEmpty(_normalizePath(path), '/'),
          'host': _firstNonEmpty(host, domain),
          'extra': <String, dynamic>{
            'xmux': <String, dynamic>{
              'maxConcurrency': XhttpAdvancedConfig.xmuxMaxConcurrency.value,
              'hMaxRequestTimes':
                  XhttpAdvancedConfig.defaultXmuxHMaxRequestTimes,
              'hMaxReusableSecs':
                  XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs,
            },
          },
        };
        if (_hasValue(effectiveXhttpMode)) {
          xhttpSettings['mode'] = effectiveXhttpMode!.trim();
        }
        streamSettings['xhttpSettings'] = xhttpSettings;
      }

      applySecureDnsConfig(
        jsonObj,
        enableTunnelMode: enableTunnelMode,
        forceBlockQuic: !(supportsVisionFlow &&
            effectiveFlow.toLowerCase() == 'xtls-rprx-vision-udp443'),
      );
      // FakeDNS is not part of the control plane. Strip any block an imported
      // template carries, or Xray would answer from a fake pool this app no
      // longer declares a resolver for.
      jsonObj.remove('fakeDns');

      logMessage(
        'DNS control plane applied: '
        'direct=${DnsConfig.directResolversForXray().join(", ")} '
        'proxy=${DnsConfig.proxyResolversForXray().join(", ")} '
        'directDomains=${DnsConfig.directDomainSet.length}',
      );

      final formatted = const JsonEncoder.withIndent('  ').convert(jsonObj);
      logMessage('✅ XrayJson 配置内容生成完成');
      return formatted;
    } catch (e) {
      setMessage('❌ XrayJson 生成失败: $e');
      logMessage('XrayJson 错误: $e');
      return '';
    }
  }

  static Future<String> _generateServiceContent(
    String nodeCode,
    String bundleId,
    String configPath,
    String serviceName,
  ) async {
    checkNotEmpty(nodeCode, 'nodeCode');
    checkNotEmpty(bundleId, 'bundleId');
    checkNotEmpty(configPath, 'configPath');
    checkNotEmpty(serviceName, 'serviceName');
    try {
      switch (Platform.operatingSystem) {
        case 'macos':
          final xrayPath = await GlobalApplicationConfig.getXrayExePath();
          return await renderXrayPlist(
            bundleId: bundleId,
            name: nodeCode.toLowerCase(),
            configPath: configPath,
            xrayPath: xrayPath,
          );
        case 'linux':
          final xrayPath = await GlobalApplicationConfig.getXrayExePath();
          return renderXrayService(xrayPath: xrayPath, configPath: configPath);
        case 'windows':
          final xrayPath = await GlobalApplicationConfig.getXrayExePath();
          return renderXrayServiceWindows(
            serviceName: serviceName.replaceAll('.schtasks', ''),
            xrayPath: xrayPath,
            configPath: configPath,
          );
        default:
          return '';
      }
    } catch (e) {
      return '';
    }
  }

  static Future<String> _generateVpnNodesJsonContent(
    String nodeName,
    String nodeCode,
    String serviceName,
    String xrayConfigPath,
    Function(String) setMessage,
    Function(String) logMessage, {
    String protocol = 'vless',
    String transport = 'tcp',
    String security = 'tls',
  }) async {
    checkNotEmpty(nodeName, 'nodeName');
    checkNotEmpty(nodeCode, 'nodeCode');
    checkNotEmpty(serviceName, 'serviceName');
    checkNotEmpty(xrayConfigPath, 'xrayConfigPath');
    checkNotNull(setMessage, 'setMessage');
    checkNotNull(logMessage, 'logMessage');

    // 创建新的 VPN 节点
    final newVpnNode = VpnNode(
      name: nodeName,
      countryCode: nodeCode,
      serviceName: serviceName,
      configPath: xrayConfigPath,
      protocol: protocol,
      transport: transport,
      security: security,
      enabled: true,
    );

    // 获取现有节点列表
    var currentNodes = List<VpnNode>.from(_nodes);

    // 检查是否已存在同名节点，如果存在则更新，否则添加
    final existingIndex = currentNodes.indexWhere(
      (node) => node.name == nodeName,
    );
    if (existingIndex != -1) {
      currentNodes[existingIndex] = newVpnNode;
      logMessage('更新现有节点: $nodeName');
    } else {
      currentNodes.add(newVpnNode);
      logMessage('添加新节点: $nodeName');
    }

    // 生成完整的 JSON 内容
    final vpnNodesJsonContent = json.encode(
      currentNodes.map((e) => e.toJson()).toList(),
    );
    logMessage('✅ vpn_nodes.json 内容生成完成，总节点数: ${currentNodes.length}');
    return vpnNodesJsonContent;
  }

  static String _firstNonEmpty(
    String? first, [
    String? second,
    String fallback = '',
  ]) {
    if (first != null && first.trim().isNotEmpty) {
      return first.trim();
    }
    if (second != null && second.trim().isNotEmpty) {
      return second.trim();
    }
    return fallback;
  }

  static String? _nullableValue(String? value) {
    if (value == null) return null;
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  static bool _hasValue(String? value) {
    return value != null && value.trim().isNotEmpty;
  }

  static String? _normalizePath(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final normalized = value.trim();
    if (normalized.startsWith('/')) return normalized;
    return '/$normalized';
  }

  /// Top-level profile key recording each XHTTP value that came from
  /// control-plane tuning together with what the profile held before it, so
  /// withdrawing an override restores the original value. Xray ignores
  /// unknown top-level keys.
  static const tuningOverridesKey = 'xconnectTuning';

  /// XHTTP mode for [nodeId]: the user's saved choice, otherwise tuning,
  /// otherwise the local default.
  static String effectiveXhttpMode({String? nodeId}) =>
      XhttpAdvancedConfig.modeCustomized
          ? XhttpAdvancedConfig.mode.value
          : ClientTuning.effective(nodeId: nodeId).xhttpMode ??
              XhttpAdvancedConfig.mode.value;

  /// xmux maxConcurrency for [nodeId], resolved like [effectiveXhttpMode].
  static String effectiveXmuxMaxConcurrency({String? nodeId}) =>
      XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized
          ? XhttpAdvancedConfig.xmuxMaxConcurrency.value
          : ClientTuning.effective(nodeId: nodeId).xmuxMaxConcurrency ??
              XhttpAdvancedConfig.xmuxMaxConcurrency.value;

  /// Control-plane tuning for [nodeId] fills in what the user has not set in
  /// settings. Tuned upload and reuse limits are written inside `extra`,
  /// because Xray replaces every XHTTP field except host, path and mode with
  /// it, and are recorded under [tuningOverridesKey]. When tuning stops
  /// sending a field (a 404, a sign-out or a document without it), the
  /// recorded original comes back; a value changed outside tuning since it
  /// was applied is kept as the new original.
  static XhttpAdvancedConfigApplyResult applyXhttpAdvancedSettings(
    Map<String, dynamic> config, {
    String? nodeId,
  }) {
    final tuning = ClientTuning.effective(nodeId: nodeId);
    final mode = effectiveXhttpMode(nodeId: nodeId);
    final maxConcurrency = effectiveXmuxMaxConcurrency(nodeId: nodeId);
    final tunedFields = <String, String?>{
      'scMaxEachPostBytes': tuning.scMaxEachPostBytes,
      'scMinPostsIntervalMs': tuning.scMinPostsIntervalMs,
      'xmux.hMaxRequestTimes': tuning.xmuxHMaxRequestTimes,
      'xmux.hMaxReusableSecs': tuning.xmuxHMaxReusableSecs,
    };
    final rawOutbounds = config['outbounds'];
    if (rawOutbounds is! List) {
      return const XhttpAdvancedConfigApplyResult(
        foundXhttp: false,
        changed: false,
      );
    }

    final overridesBefore = jsonEncode(config[tuningOverridesKey]);
    final rawOverrides = config[tuningOverridesKey];
    final previousOverrides =
        rawOverrides is Map && rawOverrides['xhttp'] is Map
            ? Map<String, dynamic>.from(rawOverrides['xhttp'] as Map)
            : const <String, dynamic>{};
    final overrides = <String, dynamic>{};
    var foundXhttp = false;
    var changed = false;
    final outbounds = List<dynamic>.from(rawOutbounds);
    for (var index = 0; index < outbounds.length; index++) {
      final rawOutbound = outbounds[index];
      if (rawOutbound is! Map || rawOutbound['tag'] != 'proxy') continue;

      final outbound = Map<String, dynamic>.from(rawOutbound);
      final streamSettings = Map<String, dynamic>.from(
        outbound['streamSettings'] as Map? ?? const {},
      );
      if ((streamSettings['network'] as String? ?? '').toLowerCase() !=
          'xhttp') {
        continue;
      }

      foundXhttp = true;
      final before = jsonEncode(outbound);
      final xhttpSettings = Map<String, dynamic>.from(
        streamSettings['xhttpSettings'] as Map? ?? const {},
      );
      xhttpSettings['mode'] = mode;

      final extra = Map<String, dynamic>.from(
        xhttpSettings['extra'] as Map? ?? const {},
      );
      final xmux = Map<String, dynamic>.from(extra['xmux'] as Map? ?? const {});
      xmux['maxConcurrency'] = maxConcurrency;
      for (final field in tunedFields.entries) {
        final inXmux = field.key.startsWith('xmux.');
        final target = inXmux ? xmux : extra;
        final key = inXmux ? field.key.substring(5) : field.key;
        final current = target[key];
        final record = previousOverrides[field.key];
        // Unwind our own earlier override; anything else is the original.
        final original =
            record is Map && jsonEncode(record['value']) == jsonEncode(current)
                ? record['original']
                : current;
        final tuned = field.value;
        if (tuned != null) {
          target[key] = tuned;
          overrides[field.key] = <String, dynamic>{
            'value': tuned,
            'original': original,
          };
        } else if (original == null) {
          target.remove(key);
        } else {
          target[key] = original;
        }
      }
      final hMaxRequestTimes = xmux['hMaxRequestTimes'];
      if (hMaxRequestTimes == null ||
          (hMaxRequestTimes is String && hMaxRequestTimes.trim().isEmpty)) {
        xmux['hMaxRequestTimes'] =
            XhttpAdvancedConfig.defaultXmuxHMaxRequestTimes;
      }
      final hMaxReusableSecs = xmux['hMaxReusableSecs'];
      if (hMaxReusableSecs == null ||
          (hMaxReusableSecs is String && hMaxReusableSecs.trim().isEmpty)) {
        xmux['hMaxReusableSecs'] =
            XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs;
      }
      extra['xmux'] = xmux;
      xhttpSettings['extra'] = extra;
      streamSettings['xhttpSettings'] = xhttpSettings;

      if ((streamSettings['security'] as String? ?? '').toLowerCase() ==
          'tls') {
        final tlsSettings = Map<String, dynamic>.from(
          streamSettings['tlsSettings'] as Map? ?? const {},
        );
        final alpn = List<String>.from(XhttpAdvancedConfig.alpn.value);
        if (alpn.isEmpty) {
          tlsSettings.remove('alpn');
        } else {
          tlsSettings['alpn'] = alpn;
        }
        streamSettings['tlsSettings'] = tlsSettings;
      }

      outbound['streamSettings'] = streamSettings;
      outbounds[index] = outbound;
      if (jsonEncode(outbound) != before) changed = true;
    }
    config['outbounds'] = outbounds;
    if (overrides.isEmpty) {
      config.remove(tuningOverridesKey);
    } else {
      config[tuningOverridesKey] = <String, dynamic>{'xhttp': overrides};
    }
    if (jsonEncode(config[tuningOverridesKey]) != overridesBefore) {
      changed = true;
    }
    return XhttpAdvancedConfigApplyResult(
      foundXhttp: foundXhttp,
      changed: changed,
    );
  }

  static Future<XhttpAdvancedConfigApplyResult>
      applyXhttpAdvancedSettingsToFile(String configPath,
          {String? nodeId}) async {
    checkNotEmpty(configPath, 'configPath');
    final file = File(configPath);
    if (!await file.exists()) {
      throw FileSystemException('Xray config file does not exist', configPath);
    }

    final raw = await file.readAsString();
    final config = jsonDecode(raw) as Map<String, dynamic>;
    final result = applyXhttpAdvancedSettings(config, nodeId: nodeId);
    if (result.changed) {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config),
      );
    }
    return result;
  }

  static Future<XhttpAdvancedConfigApplyResult>
      applyXhttpAdvancedSettingsToNode(String nodeName) async {
    checkNotEmpty(nodeName, 'nodeName');
    final node = getNodeByName(nodeName);
    if (node == null) {
      throw StateError('Unknown node: $nodeName');
    }
    return applyXhttpAdvancedSettingsToFile(
      node.configPath,
      nodeId: node.managedNodeId,
    );
  }

  /// Production runs never log per-connection detail: it costs CPU and memory
  /// in the Packet Tunnel. Profiles saved by older versions at debug or info
  /// are lowered on every connect; quieter levels are kept. `--debug` runs
  /// leave the profile as written.
  static void applyRuntimeLogLevel(Map<String, dynamic> config) {
    if (GlobalState.debugMode.value) return;
    final log = Map<String, dynamic>.from(config['log'] as Map? ?? const {});
    final level = (log['loglevel'] as String? ?? '').trim().toLowerCase();
    if (level.isNotEmpty && level != 'debug' && level != 'info') return;
    log['loglevel'] = 'warning';
    config['log'] = log;
  }

  static DnsControlPlane _secureDnsControlPlane() => DnsConfig.controlPlane(
        dnsDirectPrimaryTag: _dnsDirectPrimaryTag,
        dnsDirectSecondaryTag: _dnsDirectSecondaryTag,
        dnsProxyPrimaryTag: _dnsProxyPrimaryTag,
        dnsProxySecondaryTag: _dnsProxySecondaryTag,
      );

  /// Only the generated XConnect layout can safely give TUN traffic priority
  /// over its existing application rules. Imported routing graphs keep their
  /// original semantics.
  static bool supportsTrafficRouting(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    if (outbounds is! List || outbounds.length < 4 || outbounds.length > 5) {
      return false;
    }
    const expected = {
      'proxy': 'vless',
      'direct': 'freedom',
      'block': 'blackhole',
      'dns': 'dns',
      BusinessDnsPolicy.outboundTag: 'dns',
    };
    var index = 0;
    for (final outbound in outbounds) {
      final entry = expected.entries.elementAt(index++);
      if (outbound is! Map ||
          outbound['tag'] != entry.key ||
          outbound['protocol'] != entry.value) {
        return false;
      }
    }

    final proxy = outbounds.first as Map;
    final stream = proxy['streamSettings'];
    if (stream is! Map || stream['security'] != 'tls') return false;
    final tls = stream['tlsSettings'];
    if (tls is! Map || tls['allowInsecure'] == true) return false;

    final routing = config['routing'];
    if (routing is! Map ||
        routing.keys.any((key) => key != 'rules' && key != 'domainStrategy') ||
        (routing['domainStrategy'] != null &&
            routing['domainStrategy'] != 'AsIs')) {
      return false;
    }
    final rules = routing['rules'];
    if (rules is! List) return false;
    final policy = RoutePolicy(
      domainSets: _secureDnsControlPlane().routePolicy.domainSets,
      forceTunnelDnsToProxy: true,
    );
    final generated = policy.buildSecureDnsRules(
      enableTunnelMode: true,
      blockQuic: true,
      tunInboundTag: _tunInboundTag,
      directResolverInboundTags: [_dnsDirectPrimaryTag, _dnsDirectSecondaryTag],
      proxyResolverInboundTags: [_dnsProxyPrimaryTag, _dnsProxySecondaryTag],
    );
    // Add all-vpn variant rules (where cnDomains is absent)
    final allVpnRules = policy.buildSecureDnsRules(
      enableTunnelMode: true,
      blockQuic: true,
      tunInboundTag: _tunInboundTag,
      directResolverInboundTags: [_dnsDirectPrimaryTag, _dnsDirectSecondaryTag],
      proxyResolverInboundTags: [_dnsProxyPrimaryTag, _dnsProxySecondaryTag],
      routeAllTunnelTraffic: true,
    );
    for (final r in allVpnRules) {
      if (!generated.any((g) => mapEquals(g, r))) {
        generated.add(r);
      }
    }
    generated.add({
      ...generated.first,
      'outboundTag': BusinessDnsPolicy.outboundTag,
    });
    generated.add({
      ...generated.firstWhere((rule) => listEquals(rule['inboundTag'] as List?,
          [_dnsProxyPrimaryTag, _dnsProxySecondaryTag])),
      'inboundTag': [
        _dnsProxyPrimaryTag,
        _dnsProxySecondaryTag,
        ResolverServerPolicy.proxyFallbackTag
      ],
    });
    // Recognize legacy generated rule shapes (pre-split system+apple domains,
    // legacy combined direct domains, and intermediate global traffic tag)
    generated.add(<String, dynamic>{
      'type': 'field',
      'domain': DnsConfig.legacyDirectDomains,
      'outboundTag': 'direct',
    });
    generated.add(<String, dynamic>{
      'type': 'field',
      'domain': DnsConfig.directDomainSet,
      'outboundTag': 'direct',
    });
    generated.add(<String, dynamic>{
      'type': 'field',
      'inboundTag': <String>[_tunInboundTag],
      'network': 'tcp,udp',
      'outboundTag': 'proxy',
      'ruleTag': RoutePolicy.globalTrafficRuleTag,
    });
    return rules.every((rule) =>
        rule is Map &&
        generated.any((candidate) =>
            candidate.length == rule.length &&
            candidate.entries.every((entry) {
              final actual = rule[entry.key];
              final expected = entry.value;
              return expected is List
                  ? actual is List && listEquals(expected, actual)
                  : expected == actual;
            })));
  }

  /// Checks whether a routing configuration is currently routing all tunnel
  /// traffic (i.e. Global Proxy, where Chinese mainland direct rules are omitted).
  static bool isRoutingAllTunnelTraffic(Map<String, dynamic> routing) {
    final rules = routing['rules'];
    if (rules is! List) return false;
    return !rules.any((rule) =>
        rule is Map &&
        rule['outboundTag'] == 'direct' &&
        rule['domain'] is List &&
        ((rule['domain'] as List).contains('domain:cn') ||
            (rule['domain'] as List).contains(r'regexp:^.*\.cn$') ||
            (rule['domain'] as List).contains('geosite:cn') ||
            (rule['domain'] as List).contains('domain:baidu.com')));
  }

  /// Extracts the tunnel DNS outbound tag from the port 53 UDP/TCP TUN rule.
  static String? findTunnelDnsOutboundTag(Map<String, dynamic> routing) {
    final rules = routing['rules'];
    if (rules is! List) return null;
    for (final rule in rules) {
      if (rule is Map &&
          rule['port'] == '53' &&
          (rule['network'] == 'udp' ||
              rule['network'] == 'tcp,udp' ||
              rule['network'] == null) &&
          rule['inboundTag'] is List &&
          ((rule['inboundTag'] as List).contains(_tunInboundTag) ||
              (rule['inboundTag'] as List).contains('tun'))) {
        return rule['outboundTag'] as String?;
      }
    }
    return null;
  }

  /// Control-plane tuning may replace the DoH upstream timeout
  /// ([ResolverServerPolicy.dohTimeoutMs] by default) and turn on parallel
  /// queries; resolver addresses and routing are never tunable.
  static Map<String, dynamic> buildSecureDnsConfig() {
    final config = _secureDnsControlPlane().dnsPolicy.toXrayDnsConfig();
    final tuning = ClientTuning.effective();
    final timeoutMs = tuning.dohTimeoutMs;
    if (timeoutMs != null) {
      for (final server in config['servers'] as List) {
        if (server is Map && server.containsKey('timeoutMs')) {
          server['timeoutMs'] = timeoutMs;
        }
      }
    }
    if (tuning.dnsParallelQuery == true) {
      config['enableParallelQuery'] = true;
    }
    return config;
  }

  /// Used both for new profiles and when an existing profile is prepared for
  /// reconnect. Only the dedicated outbound is managed here; node transports,
  /// DNS server addresses supplied to the OS, and user outbounds are retained.
  static void applySecureDnsConfig(
    Map<String, dynamic> config, {
    required bool enableTunnelMode,
    bool? forceBlockQuic,
    bool routeAllTunnelTraffic = false,
  }) {
    final outbounds = List<dynamic>.from(config['outbounds'] as List? ?? []);
    final reserved = outbounds.where(
      (value) => value is Map && value['tag'] == BusinessDnsPolicy.outboundTag,
    );
    bool isManaged(Object? value) {
      if (value is! Map ||
          value['protocol'] != 'dns' ||
          value['proxySettings'] is! Map ||
          (value['proxySettings'] as Map)['tag'] != 'proxy') {
        return false;
      }
      final settings = value['settings'];
      if (settings is! Map || settings['rules'] is! List) return false;
      final rules = settings['rules'] as List;
      return rules.isNotEmpty &&
          rules.last is Map &&
          (rules.last as Map)['action'] == 'direct' &&
          rules.any(
            (rule) =>
                rule is Map &&
                rule['action'] == 'hijack' &&
                rule['qType'] == 1 &&
                rule['domain'] == null,
          );
    }

    // A conflicting user outbound must never be overwritten.
    final hasConflict = reserved.any((value) => !isManaged(value));
    final controlPlane = _secureDnsControlPlane();
    final enabled = !hasConflict &&
        enableTunnelMode &&
        DnsConfig.dohEnabled &&
        controlPlane.routePolicy.forceTunnelDnsToProxy &&
        outbounds.any((value) => value is Map && value['tag'] == 'proxy');

    final exceptions = <String>{
      ...BusinessDnsPolicy.localDomains,
      ...DnsConfig.directDomainSet,
    };
    final routing = config['routing'];
    if (routing is Map && routing['rules'] is List) {
      for (final rule in routing['rules'] as List) {
        if (rule is Map &&
            rule['outboundTag'] == 'direct' &&
            rule['domain'] is List) {
          exceptions.addAll((rule['domain'] as List).whereType<String>());
        }
      }
    }
    for (final outbound in outbounds) {
      if (outbound is! Map ||
          !TunnelEndpointResolver.dialingProtocols.contains(
            outbound['protocol'],
          )) {
        continue;
      }
      final settings = outbound['settings'];
      if (settings is! Map) continue;
      for (final key in const ['vnext', 'servers']) {
        final entries = settings[key];
        if (entries is! List) continue;
        for (final entry in entries) {
          if (entry is! Map || entry['address'] is! String) continue;
          final address = (entry['address'] as String)
              .trim()
              .toLowerCase()
              .replaceFirst(RegExp(r'\.$'), '');
          if (address.isNotEmpty && InternetAddress.tryParse(address) == null) {
            exceptions.add('full:$address');
          }
        }
      }
    }
    outbounds.removeWhere(
      (value) =>
          value is Map &&
          value['tag'] == BusinessDnsPolicy.outboundTag &&
          isManaged(value),
    );
    if (enabled) {
      outbounds.add(BusinessDnsPolicy.buildOutbound(exceptions.toList()));
    }
    config['outbounds'] = outbounds;
    config['dns'] = buildSecureDnsConfig();
    config['routing'] = buildSecureDnsRoutingConfig(
      routing,
      enableTunnelMode: enableTunnelMode,
      forceBlockQuic: forceBlockQuic,
      tunnelDnsOutboundTag: enabled ? BusinessDnsPolicy.outboundTag : 'proxy',
      removeBusinessDnsRule: !hasConflict,
      routeAllTunnelTraffic: routeAllTunnelTraffic,
    );
  }

  static Map<String, dynamic> buildSecureDnsRoutingConfig(
    Object? existingRouting, {
    required bool enableTunnelMode,
    bool? forceBlockQuic,
    bool routeAllTunnelTraffic = false,
    String tunnelDnsOutboundTag = 'proxy',
    bool removeBusinessDnsRule = false,
  }) {
    final controlPlane = _secureDnsControlPlane();
    final routing = existingRouting is Map
        ? Map<String, dynamic>.from(existingRouting)
        : <String, dynamic>{};
    final rawRules = List<dynamic>.from(
      routing['rules'] as List<dynamic>? ?? const [],
    );
    // Remove existing injected secure rules to make it idempotent
    final existingRules = rawRules.where((rule) {
      if (rule is! Map) return true;
      final type = rule['type'];
      final outboundTag = rule['outboundTag'];
      final inboundTag = rule['inboundTag'];
      if (rule['ruleTag'] == RoutePolicy.globalTrafficRuleTag &&
          type == 'field' &&
          outboundTag == 'proxy' &&
          rule['network'] == 'tcp,udp' &&
          listEquals(
              inboundTag is List ? inboundTag : null, [_tunInboundTag])) {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'block' &&
          rule['network'] == 'udp' &&
          rule['port'] == '443') {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'block' &&
          rule['protocol'] is List &&
          (rule['protocol'] as List).contains('quic')) {
        return false;
      }
      if (type == 'field' && outboundTag == 'proxy' && rule['port'] == '53') {
        return false;
      }
      if (removeBusinessDnsRule &&
          type == 'field' &&
          outboundTag == BusinessDnsPolicy.outboundTag &&
          rule['port'] == '53' &&
          inboundTag is List &&
          inboundTag.length == 1 &&
          inboundTag.single == _tunInboundTag) {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'direct' &&
          inboundTag is List &&
          inboundTag.contains(_dnsDirectPrimaryTag)) {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'proxy' &&
          inboundTag is List &&
          inboundTag.contains(_dnsProxyPrimaryTag)) {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'direct' &&
          rule['ip'] != null &&
          rule['ip'] is List &&
          ((rule['ip'] as List).contains('fc00::/7') ||
              (rule['ip'] as List).contains('10.0.0.0/8') ||
              (rule['ip'] as List).contains('192.168.0.0/16') ||
              (rule['ip'] as List).contains('geoip:private')) &&
          !(rule['ip'] as List).any(
              (e) => e is String && e.startsWith('geoip:') && e != 'geoip:private')) {
        return false;
      }
      if (type == 'field' &&
          outboundTag == 'direct' &&
          rule['domain'] != null &&
          rule['domain'] is List &&
          ((rule['domain'] as List).contains('full:localhost') ||
              (rule['domain'] as List).contains('domain:cn') ||
              (rule['domain'] as List).contains(r'regexp:^.*\.cn$') ||
              (rule['domain'] as List).contains('domain:baidu.com') ||
              (rule['domain'] as List).contains('domain:apple.com')) &&
          !(rule['domain'] as List)
              .any((e) => e is String && e.startsWith('geosite:'))) {
        return false;
      }
      if (enableTunnelMode &&
          routeAllTunnelTraffic &&
          type == 'field' &&
          outboundTag == 'direct' &&
          rule['domain'] != null &&
          !(rule['domain'] as List)
              .any((e) => e is String && e.startsWith('geosite:'))) {
        return false;
      }
      return true;
    }).toList();

    final secureDnsRules = controlPlane.routePolicy.buildSecureDnsRules(
      enableTunnelMode: enableTunnelMode,
      blockQuic: forceBlockQuic ?? !GlobalState.http3Passthrough.value,
      tunInboundTag: _tunInboundTag,
      directResolverInboundTags: <String>[
        _dnsDirectPrimaryTag,
        _dnsDirectSecondaryTag,
      ],
      proxyResolverInboundTags: controlPlane.dnsPolicy.proxyResolvers
          .map((resolver) => resolver.tag)
          .toList(),
      tunnelDnsOutboundTag: tunnelDnsOutboundTag,
      routeAllTunnelTraffic: enableTunnelMode && routeAllTunnelTraffic,
    );
    final existingDomainStrategy = routing['domainStrategy'];
    routing['domainStrategy'] = existingDomainStrategy is String &&
            existingDomainStrategy.trim().isNotEmpty
        ? existingDomainStrategy.trim()
        : 'AsIs';
    final specificRules = <dynamic>[];
    final catchAllRules = <dynamic>[];
    for (final rule in existingRules) {
      if (_isCatchAllRoutingRule(rule)) {
        catchAllRules.add(rule);
      } else {
        specificRules.add(rule);
      }
    }
    routing['rules'] = <dynamic>[
      ...secureDnsRules,
      ...specificRules,
      ...catchAllRules,
    ];
    return routing;
  }

  static bool _supportsVisionFlow({
    required String? protocol,
    required String? network,
    required String? security,
  }) {
    return protocol?.trim().toLowerCase() == 'vless' &&
        network?.trim().toLowerCase() == 'tcp' &&
        security?.trim().toLowerCase() == 'tls';
  }

  static bool proxyOutboundSupportsUdp443(Map<String, dynamic> proxyOutbound) {
    if (proxyOutbound['protocol'] != 'vless') return false;
    final streamSettings = proxyOutbound['streamSettings'] as Map?;
    if (streamSettings == null) return false;
    if (!_supportsVisionFlow(
      protocol: proxyOutbound['protocol'] as String?,
      network: streamSettings['network'] as String?,
      security: streamSettings['security'] as String?,
    )) {
      return false;
    }
    final settings = proxyOutbound['settings'] as Map?;
    final vnext = settings?['vnext'] as List?;
    if (vnext == null || vnext.isEmpty) return false;
    final firstVnext = vnext.first as Map?;
    final users = firstVnext?['users'] as List?;
    if (users == null || users.isEmpty) return false;
    final firstUser = users.first as Map?;
    final flow = firstUser?['flow'] as String?;
    return flow?.trim().toLowerCase() == 'xtls-rprx-vision-udp443';
  }

  static Map<String, dynamic> normalizeProxyOutboundFlow(
    Map<String, dynamic> proxyOutbound,
  ) {
    if (proxyOutbound['protocol'] != 'vless') return proxyOutbound;
    final streamSettings = proxyOutbound['streamSettings'] as Map?;
    if (streamSettings == null) return proxyOutbound;
    final network = streamSettings['network'] as String?;
    final security = streamSettings['security'] as String?;

    final settings = proxyOutbound['settings'] as Map?;
    if (settings == null) return proxyOutbound;
    final vnext = settings['vnext'] as List?;
    if (vnext == null || vnext.isEmpty) return proxyOutbound;

    final firstVnext = vnext.first as Map;
    final users = firstVnext['users'] as List?;
    if (users == null || users.isEmpty) return proxyOutbound;

    final firstUser = users.first as Map;
    if (!_supportsVisionFlow(
      protocol: proxyOutbound['protocol'] as String?,
      network: network,
      security: security,
    )) {
      firstUser.remove('flow');
      return proxyOutbound;
    }

    final currentFlow = firstUser['flow'] as String?;

    final newFlow = DnsConfig.normalizeVisionFlow(currentFlow);
    if (newFlow.isNotEmpty) {
      firstUser['flow'] = newFlow;
    } else {
      firstUser.remove('flow');
    }
    return proxyOutbound;
  }

  /// Generate inbounds configuration based on proxy and tunnel settings
  static String generateInboundsConfig({
    bool enableSocksProxy = true,
    bool enableHttpProxy = true,
    bool enableTunnelMode = true,
  }) {
    final inbounds = <Map<String, dynamic>>[];

    // SOCKS proxy configuration
    if (enableSocksProxy) {
      inbounds.add({
        "listen": "127.0.0.1",
        "port": 1080,
        "tag": _socksInboundTag,
        "protocol": "socks",
        "settings": {"udp": true},
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"],
        },
      });
    }

    // HTTP proxy configuration
    if (enableHttpProxy) {
      inbounds.add({
        "listen": "127.0.0.1",
        "port": 1081,
        "tag": _httpInboundTag,
        "protocol": "http",
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"],
        },
      });
    }

    // Tunnel mode configuration
    if (enableTunnelMode) {
      inbounds.add({
        "tag": _tunInboundTag,
        "protocol": "tun",
        "settings": tunnelInboundSettingsForOperatingSystem(
          Platform.operatingSystem,
        ),
        "sniffing": {
          "enabled": GlobalState.sniffingEnabled.value,
          "routeOnly": tunnelSniffingRouteOnlyForOperatingSystem(
            Platform.operatingSystem,
          ),
          "destOverride": <String>["http", "tls", "quic"],
        },
      });
    }

    return const JsonEncoder.withIndent('  ').convert(inbounds);
  }

  /// Desktop tunnel interfaces use stable names so the native runtime can
  /// verify that the engine created its system-level interface before the UI
  /// reports a connected tunnel. Apple platforms receive their interface from
  /// the Packet Tunnel provider and intentionally keep their existing shape.
  static Map<String, dynamic> tunnelInboundSettingsForOperatingSystem(
    String operatingSystem,
  ) {
    final settings = <String, dynamic>{'mtu': 1500};
    // Windows Wintun creates an adapter, not an address/DNS configuration.
    // Xray applies gateway prefixes as local interface addresses. Keep DNS
    // aligned with the selected system tunnel resolvers. Linux retains its
    // existing configuration contract.
    const systemRoutedTunnelSettings = <String, dynamic>{
      'autoSystemRoutingTable': <String>['0.0.0.0/0', '::/0'],
      'autoOutboundsInterface': 'auto',
    };
    switch (operatingSystem) {
      case 'windows':
        settings.addAll(<String, dynamic>{
          'name': 'XConnect',
          'gateway': <String>['198.18.0.1/30', 'fdfe:dcba:9876::1/126'],
          'dns': DnsConfig.systemTunnelDnsServers4(),
          ...systemRoutedTunnelSettings,
        });
      case 'linux':
        settings.addAll(<String, dynamic>{
          'name': 'xconnect-tun0',
          ...systemRoutedTunnelSettings,
        });
    }
    return settings;
  }

  /// Desktop TUN needs the sniffed destination to replace the original IP so
  /// gVisor receives response traffic for proxied TCP/UDP flows. Apple Packet
  /// Tunnel providers keep the existing route-only behavior.
  static bool tunnelSniffingRouteOnlyForOperatingSystem(
    String operatingSystem,
  ) {
    return operatingSystem != 'windows' && operatingSystem != 'linux';
  }
}
