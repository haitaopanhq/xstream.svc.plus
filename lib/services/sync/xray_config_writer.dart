import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../services/vpn_config_service.dart';
import '../../utils/global_config.dart';
import '../../utils/tun_config_guard.dart';

class XrayConfigWriteResult {
  final String path;
  final bool modified;

  const XrayConfigWriteResult({
    required this.path,
    required this.modified,
  });
}

class XrayConfigWriter {
  static const _defaultNodeName = 'Desktop Sync';
  static const _defaultServiceName = 'xconnect.desktop.sync';
  static const _syncServicePrefix = 'xconnect.sync.';
  static const _defaultCountryCode = 'SYNC';

  static Future<String> writeConfig(String json) async {
    final code = _normalizeNodeCode(_defaultCountryCode);
    final fileName = 'node-$code-config.json';
    final path = await GlobalApplicationConfig.getXrayConfigFilePath(fileName);
    final file = File(path);
    await file.create(recursive: true);
    final guarded = guardTunInterfaceFieldsForWrite(json);
    await file.writeAsString(guarded.json);
    return path;
  }

  static Future<String> writeConfigForNode({
    required String json,
    required String nodeName,
    String? countryCode,
    String? nodeId,
    String? owner,
    String? teamId,
  }) async {
    final result = await writeConfigForNodeWithResult(
      json: json,
      nodeName: nodeName,
      countryCode: countryCode,
      nodeId: nodeId,
      owner: owner,
      teamId: teamId,
    );
    return result.path;
  }

  static Future<XrayConfigWriteResult> writeConfigForNodeWithResult({
    required String json,
    required String nodeName,
    String? countryCode,
    String? nodeId,
    String? owner,
    String? teamId,
  }) async {
    final code = await _nodeCode(
      (countryCode ?? '').trim().isNotEmpty ? countryCode! : nodeName,
      nodeId: owner == null ? nodeId : '$owner|$teamId|$nodeId',
    );
    final fileName = 'node-$code-config.json';
    final path = await GlobalApplicationConfig.getXrayConfigFilePath(fileName);
    final file = File(path);
    await file.create(recursive: true);
    final guarded = guardTunInterfaceFieldsForWrite(json);
    final newBytes = utf8.encode(guarded.json);
    final newDigest = (await Sha256().hash(newBytes)).bytes;
    var modified = true;
    if (await file.exists()) {
      try {
        final existingBytes = await file.readAsBytes();
        final existingDigest = (await Sha256().hash(existingBytes)).bytes;
        if (_bytesEqual(existingDigest, newDigest)) {
          modified = false;
        }
      } catch (_) {
        modified = true;
      }
    }
    if (modified) {
      await file.writeAsString(guarded.json);
    }
    return XrayConfigWriteResult(path: path, modified: modified);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<String> registerNode({
    required String configPath,
    String? nodeName,
    String? countryCode,
    String? protocol,
    String? transport,
    String? security,
    String? nodeId,
    String? owner,
    String? teamId,
    String? routingPool,
    String? pricingGroup,
  }) async {
    final normalizedName = (nodeName ?? '').trim().isNotEmpty
        ? nodeName!.trim()
        : _defaultNodeName;
    final normalizedNodeId = (nodeId ?? '').trim();
    final incomingIdentity = await _readOutboundIdentity(configPath);
    final existingByName = VpnConfig.getNodeByName(normalizedName);
    final serviceName =
        '$_syncServicePrefix${await _nodeCode('node', nodeId: owner == null ? nodeId ?? normalizedName : '$owner|$teamId|$nodeId')}';
    final identityMatches = incomingIdentity == null || owner != null
        ? <VpnNode>[]
        : await _findNodesByIdentity(incomingIdentity);
    final ownerMatches = owner == null
        ? <VpnNode>[]
        : _findManagedNodesForOwner(
            owner: owner,
            serviceName: serviceName,
            nodeId: normalizedNodeId,
            configPath: configPath,
            normalizedName: normalizedName,
          );
    final activeNodeName = GlobalState.activeNodeName.value.trim();
    final candidateMatches = owner != null ? ownerMatches : identityMatches;
    VpnNode? existing = candidateMatches.cast<VpnNode?>().firstWhere(
          (node) => (node?.name ?? '') == activeNodeName,
          orElse: () => null,
        );
    existing ??= candidateMatches.cast<VpnNode?>().firstWhere(
          (node) => (node?.serviceName ?? '') != _defaultServiceName,
          orElse: () => null,
        );
    existing ??= candidateMatches.isNotEmpty ? candidateMatches.first : null;
    existing ??= VpnConfig.allNodes.cast<VpnNode?>().firstWhere(
          (node) => node?.serviceName == serviceName,
          orElse: () => null,
        );
    if (owner == null && existingByName?.isManaged == true) {
      existing ??= existingByName;
    }
    var targetNodeName = existing?.name ??
        (existingByName == null
            ? normalizedName
            : '$normalizedName (${nodeId ?? teamId ?? "managed"})');

    if (existing == null) {
      final baseName = targetNodeName;
      var suffix = 2;
      while (VpnConfig.getNodeByName(targetNodeName) != null) {
        targetNodeName = '$baseName (${suffix++})';
      }
    }

    if (candidateMatches.length > 1 && existing != null) {
      for (final duplicate in candidateMatches) {
        if (duplicate.name != existing.name) {
          VpnConfig.removeNode(duplicate.name);
        }
      }
    }

    if (existing == null) {
      final stale = VpnConfig.allNodes
          .where((node) => isReplaceableFallbackNode(node, targetNodeName))
          .map((node) => node.name)
          .toList();
      for (final name in stale) {
        final node = VpnConfig.getNodeByName(name);
        if (node != null) await VpnConfig.deleteNodeFiles(node);
      }
    }

    final node = VpnNode(
      name: targetNodeName,
      countryCode: _normalizeCountryCode(
        countryCode,
        existing?.countryCode ?? _defaultCountryCode,
      ),
      configPath: configPath,
      serviceName:
          owner == null ? existing?.serviceName ?? serviceName : serviceName,
      protocol: _pickValue(protocol, existing?.protocol),
      transport: _pickValue(transport, existing?.transport),
      security: _pickValue(security, existing?.security),
      enabled: existing?.enabled ?? true,
      managedOwner: owner,
      managedTeamId: teamId,
      managedNodeId: nodeId,
      routingPool: _nullableValue(routingPool),
      pricingGroup: _nullableValue(pricingGroup),
    );
    if (existing == null) {
      VpnConfig.addNode(node);
    } else {
      VpnConfig.updateNode(node);
    }
    await VpnConfig.saveToFile();
    return node.name;
  }

  static List<VpnNode> _findManagedNodesForOwner({
    required String owner,
    required String serviceName,
    required String nodeId,
    required String configPath,
    required String normalizedName,
  }) {
    final targetPath = File(configPath).absolute.path;
    return VpnConfig.allNodes.where((node) {
      if (!node.isManaged || node.managedOwner != owner) return false;
      if (node.serviceName == serviceName) return true;
      if (nodeId.isNotEmpty && (node.managedNodeId ?? '').trim() == nodeId) {
        return true;
      }
      if (File(node.configPath).absolute.path == targetPath) return true;
      final existingNodeId = (node.managedNodeId ?? '').trim();
      if (node.name == normalizedName &&
          (nodeId.isEmpty ||
              existingNodeId.isEmpty ||
              existingNodeId == nodeId)) {
        return true;
      }
      return false;
    }).toList();
  }

  static String? _nullableValue(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<void> pruneSyncedNodes(Set<String> retainedNames,
      {String? owner}) async {
    final stale = VpnConfig.allNodes
        .where((node) =>
            node.isManaged &&
            (owner == null || node.managedOwner == owner) &&
            !retainedNames.contains(node.name))
        .map((node) => node.name)
        .toList();
    for (final name in stale) {
      final node = VpnConfig.getNodeByName(name);
      if (node != null) await VpnConfig.deleteNodeFiles(node);
    }
    if (stale.isNotEmpty) await VpnConfig.saveToFile();
  }

  static Future<String> _nodeCode(String raw, {String? nodeId}) async {
    final prefix = _normalizeNodeCode(raw);
    final digest = await Sha256().hash(utf8.encode(nodeId ?? raw));
    final suffix = digest.bytes
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$prefix-$suffix';
  }

  @visibleForTesting
  static bool isReplaceableFallbackNode(VpnNode node, String targetNodeName) =>
      node.serviceName == _defaultServiceName &&
      node.name == _defaultNodeName &&
      node.name != targetNodeName;

  static String _normalizeCountryCode(String? value, String fallback) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return fallback;
    if (raw.length > 12) return raw.substring(0, 12).toUpperCase();
    return raw.toUpperCase();
  }

  static String _pickValue(String? preferred, String? fallback) {
    final primary = (preferred ?? '').trim();
    if (primary.isNotEmpty) return primary.toLowerCase();
    final secondary = (fallback ?? '').trim();
    if (secondary.isNotEmpty) return secondary.toLowerCase();
    return '';
  }

  static String _normalizeNodeCode(String raw) {
    final lower = raw.trim().toLowerCase();
    final normalized = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final compact = normalized.replaceAll(RegExp(r'-+'), '-');
    final trimmed = compact.replaceAll(RegExp(r'^-+|-+$'), '');
    if (trimmed.isEmpty) return 'node';
    if (trimmed.length > 24) return trimmed.substring(0, 24);
    return trimmed;
  }

  static Future<List<VpnNode>> _findNodesByIdentity(String identity) async {
    final matches = <VpnNode>[];
    for (final node in VpnConfig.allNodes.where((node) => node.isManaged)) {
      final nodeIdentity = await _readOutboundIdentity(node.configPath);
      if (nodeIdentity == identity) {
        matches.add(node);
      }
    }
    return matches;
  }

  static Future<String?> _readOutboundIdentity(String configPath) async {
    try {
      final raw = await File(configPath).readAsString();
      return extractOutboundIdentity(raw);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String? extractOutboundIdentity(String rawJson) {
    try {
      final obj = jsonDecode(rawJson);
      if (obj is! Map) return null;
      final outboundsRaw = obj['outbounds'];
      if (outboundsRaw is! List) return null;
      Map<dynamic, dynamic>? proxyOutbound;
      for (final outbound in outboundsRaw) {
        if (outbound is! Map) continue;
        if ((outbound['tag'] as String?) == 'proxy') {
          proxyOutbound = outbound;
          break;
        }
      }
      if (proxyOutbound == null) return null;

      final protocol =
          ((proxyOutbound['protocol'] as String?) ?? '').trim().toLowerCase();
      if (protocol.isEmpty) return null;

      final settings = proxyOutbound['settings'];
      if (settings is! Map) return null;
      final vnext = settings['vnext'];
      if (vnext is! List || vnext.isEmpty || vnext.first is! Map) return null;
      final first = vnext.first as Map;

      final address =
          ((first['address'] as String?) ?? '').trim().toLowerCase();
      final port = (first['port'] as num?)?.toInt();
      if (address.isEmpty || port == null) return null;

      String userId = '';
      final users = first['users'];
      if (users is List && users.isNotEmpty && users.first is Map) {
        userId = (((users.first as Map)['id'] as String?) ?? '')
            .trim()
            .toLowerCase();
      }

      String network = '';
      String security = '';
      String sni = '';
      final streamSettings = proxyOutbound['streamSettings'];
      if (streamSettings is Map) {
        network =
            ((streamSettings['network'] as String?) ?? '').trim().toLowerCase();
        security = ((streamSettings['security'] as String?) ?? '')
            .trim()
            .toLowerCase();

        final tlsSettings = streamSettings['tlsSettings'];
        if (tlsSettings is Map) {
          sni = ((tlsSettings['serverName'] as String?) ?? '')
              .trim()
              .toLowerCase();
        }
        if (sni.isEmpty) {
          final realitySettings = streamSettings['realitySettings'];
          if (realitySettings is Map) {
            sni = ((realitySettings['serverName'] as String?) ?? '')
                .trim()
                .toLowerCase();
          }
        }
      }

      return [
        protocol,
        address,
        '$port',
        userId,
        network,
        security,
        sni,
      ].join('|');
    } catch (_) {
      return null;
    }
  }
}
