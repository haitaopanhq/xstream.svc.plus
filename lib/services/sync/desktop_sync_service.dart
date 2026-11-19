import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/global_config.dart' show GlobalState;
import '../session/session_manager.dart';
import '../notifications/quota_notifications.dart';
import '../session/network_access_policy.dart';
import '../../utils/native_bridge.dart';
import '../../widgets/log_console.dart' show LogLevel;
import '../tuning/client_tuning.dart';
import '../vpn_config_service.dart';
import 'sync_state.dart';
import 'xray_config_writer.dart';

class DesktopSyncResult {
  final bool success;
  final String message;
  const DesktopSyncResult({required this.success, required this.message});
}

class SyncedNodeMetadata {
  final String id;
  final String name;
  final String? region;
  final String? protocol;
  final String? transport;
  final String? security;
  final String vlessUri;
  final String? routingPool;
  final String? pricingGroup;
  final String? domainStrategy;
  final List<Map<String, dynamic>> routingRules;
  final Map<String, dynamic>? routing;

  const SyncedNodeMetadata({
    required this.id,
    required this.name,
    required this.vlessUri,
    this.region,
    this.protocol,
    this.transport,
    this.security,
    this.routingPool,
    this.pricingGroup,
    this.domainStrategy,
    this.routingRules = const [],
    this.routing,
  });
}

/// Pulls the authoritative regional node list after login and periodically
/// while a session is active. The server owns availability and VLESS details;
/// this service only renders and persists the returned profiles.
class DesktopSyncService {
  DesktopSyncService._();
  static final instance = DesktopSyncService._();

  static const sessionExpiredMessage = 'connectorSessionExpired';
  static const syncUnavailableMessage = 'connectorSyncTemporarilyUnavailable';

  static const _nodesPath = '/api/agent-server/v1/nodes';
  static const _autoInterval = Duration(minutes: 10);
  @visibleForTesting
  late http.Client client = http.Client();
  @visibleForTesting
  Future<String> Function()? stopTunnelForTesting;
  @visibleForTesting
  Future<String> Function(String nodeName)? startTunnelForTesting;
  @visibleForTesting
  Future<String> Function(String nodeName)? stopNodeServiceForTesting;
  @visibleForTesting
  Future<String> Function(String nodeName)? startNodeServiceForTesting;
  @visibleForTesting
  Future<String> Function()? refreshIosPacketTunnelProfileForTesting;
  final syncing = ValueNotifier<bool>(false);
  Timer? _timer;
  Timer? _expiryTimer;
  bool _initialized = false;
  bool _running = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // Session is initialized before node restoration in main().
    SessionManager.instance.onSessionReset = clearManagedConnections;
    await SyncStateStore.instance.init();
    _scheduleAccessExpiry();
    SessionManager.instance.status.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  void dispose() {
    _timer?.cancel();
    _expiryTimer?.cancel();
    SessionManager.instance.onSessionReset = null;
    SessionManager.instance.status.removeListener(_onSessionChanged);
    _initialized = false;
  }

  Future<DesktopSyncResult> syncNow({bool manual = false}) async {
    if (!SessionManager.instance.isLoggedIn) {
      return const DesktopSyncResult(success: false, message: '请先登录');
    }
    if (_running) {
      return const DesktopSyncResult(success: false, message: '同步进行中');
    }
    _running = true;
    syncing.value = true;
    final generation = SessionManager.instance.generation;
    final policy = NetworkAccessPolicy.instance;
    try {
      final session = SessionManager.instance;
      final headers = <String, String>{'Accept': 'application/json'};
      if ((session.sessionToken ?? '').trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${session.sessionToken!.trim()}';
      }
      if ((session.cookie ?? '').trim().isNotEmpty) {
        headers['Cookie'] = session.cookie!.trim();
      }
      var owner = '${session.baseUrl.value}|${session.currentUser.value}';
      var purgeOwner = await policy.snapshotOwner(owner);
      await QuotaNotifications.instance.selectAccount(owner);
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      final accessResponse = await session.getWithSessionRecovery(
          client, session.buildEndpoint('/api/auth/network-access'), headers);
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (accessResponse.statusCode == 401) {
        return await _handleUnauthorized(session, generation, headers,
            '/api/auth/network-access', purgeOwner);
      }
      final accessStop = _explicitStopReason(accessResponse);
      if (accessStop != null) {
        if (accessResponse.statusCode == 200) {
          // Denials may omit the normal allowed-policy fields. Honor their
          // explicit owner when present, otherwise use the saved login binding.
          final denied = jsonDecode(accessResponse.body) as Map;
          final accountId = denied['accountId'];
          if (accountId is String && accountId.trim().isNotEmpty) {
            purgeOwner = '${session.baseUrl.value}|$accountId';
          }
        }
        return await _stopManagedAccess(accessStop, purgeOwner, generation);
      }
      if (accessResponse.statusCode == 404 && !policy.dedicated) {
        await policy.apply({'mode': 'personal', 'allowed': true}, owner);
      } else if (accessResponse.statusCode == 200) {
        final access = jsonDecode(accessResponse.body);
        if (access is! Map<String, dynamic>) {
          throw const FormatException('Invalid network access');
        }
        owner =
            '${session.baseUrl.value}|${access["accountId"] ?? session.currentUser.value}';
        await policy.apply(access, owner);
        purgeOwner = owner;
      } else if (accessResponse.statusCode == 403) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        throw const FormatException('Network access denied');
      } else {
        // A transient service/network failure must not erase the last local
        // managed snapshot. Deletion needs an explicit enforcement code, not
        // a generic HTTP status, empty list or human-readable error message.
        throw FormatException(
          'Network access returned ${accessResponse.statusCode}',
        );
      }
      if (accessResponse.statusCode == 200) {
        await _refreshQuota(session, headers, generation);
      }
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (!policy.allowed) {
        await clearManagedConnections();
        throw const FormatException('Team access is inactive');
      }
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      final response = await session.getWithSessionRecovery(
          client, session.buildEndpoint(_nodesPath), headers);
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (response.statusCode == 401) {
        return await _handleUnauthorized(
            session, generation, headers, _nodesPath, purgeOwner);
      }
      final nodeStop = _explicitStopReason(response);
      if (nodeStop != null) {
        return await _stopManagedAccess(nodeStop, purgeOwner, generation);
      }
      if (response.statusCode == 403) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        const message = '账号没有可用节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }
      if (response.statusCode != 200) {
        // Keep the last successful managed snapshot for offline use. The
        // server can replace it on the next successful manual/automatic sync.
        final message = '节点同步接口返回 ${response.statusCode}';
        await SyncStateStore.instance.recordError(message);
        return DesktopSyncResult(success: false, message: message);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const FormatException('节点同步响应必须是数组');
      }
      final nodes = decoded
          .whereType<Map>()
          .map((item) => _parseNode(item.cast<Object?, Object?>()))
          .whereType<SyncedNodeMetadata>()
          .toList();
      if (nodes.length != decoded.length) {
        throw const FormatException('Invalid managed node snapshot');
      }
      if (nodes.isEmpty) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        const message = '服务端当前没有可用节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }

      // Custom imports remain independent of managed authorization.
      policy.authorizedNodeIds = nodes.map((n) => n.id).toSet();
      if (policy.dedicated) await _stopUnauthorizedActiveNode();
      final retained = <String>{};
      final activeNodeName = GlobalState.activeNodeName.value.trim();
      var anyConfigModified = false;
      var activeConfigUpdated = false;
      String? activeUpdatedNodeName;
      for (final node in nodes) {
        if (generation != session.generation) {
          await clearManagedConnections();
          return const DesktopSyncResult(
            success: false,
            message: 'Session changed',
          );
        }
        final config = await VpnConfig.generateSyncedXrayJsonConfig(
          node.vlessUri,
          routingRules: node.routingRules,
          domainStrategy: node.domainStrategy,
          routingPool: node.routingPool,
          pricingGroup: node.pricingGroup,
          routing: node.routing,
        );
        if (!_isRenderable(config)) {
          throw FormatException('区域节点 ${node.name} 的 VLESS 配置不可用');
        }
        final writeResult = await XrayConfigWriter.writeConfigForNodeWithResult(
          json: config!,
          nodeName: node.name,
          countryCode: node.region,
          nodeId: node.id,
          owner: owner,
          teamId: policy.teamId,
        );
        final name = await XrayConfigWriter.registerNode(
          configPath: writeResult.path,
          nodeName: node.name,
          countryCode: node.region,
          protocol: node.protocol,
          transport: node.transport,
          security: node.security,
          nodeId: node.id,
          owner: owner,
          teamId: policy.teamId,
          routingPool: node.routingPool,
          pricingGroup: node.pricingGroup,
        );
        retained.add(name);
        if (writeResult.modified) {
          anyConfigModified = true;
          if (activeNodeName.isNotEmpty && name == activeNodeName) {
            activeConfigUpdated = true;
            activeUpdatedNodeName = name;
          }
        }
      }
      if (generation != session.generation) {
        await clearManagedConnections();
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      await XrayConfigWriter.pruneSyncedNodes(retained);
      policy.authorizedNodeIds = nodes.map((n) => n.id).toSet();
      policy.pending = false;
      await _refreshClientTuning(
        session,
        headers,
        isCurrent: () => generation == session.generation && session.isLoggedIn,
      );
      // Signing out or switching accounts during the tuning request must not
      // let this older sync report success.
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      await policy.cacheAccess(
        sessionScope: '${session.baseUrl.value}|${session.currentUser.value}',
        isCurrent: () => generation == session.generation && session.isLoggedIn,
      );
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (activeConfigUpdated && activeUpdatedNodeName != null) {
        await _reloadActiveNode(activeUpdatedNodeName);
      } else if (anyConfigModified) {
        await _refreshPersistedIosProfileIfApplicable();
      }
      _scheduleAccessExpiry();
      GlobalState.nodeListRevision.value++;
      if (QuotaNotifications.instance.notice == 'quotaPaused') {
        await QuotaNotifications.instance.update(null);
      }
      await SyncStateStore.instance.recordSuccess(
        nodeCount: nodes.length,
        nodeIds: nodes.map((n) => n.id).join(','),
      );
      addAppLog('区域 VLESS 配置已同步 (${nodes.length} 个节点)');
      return DesktopSyncResult(
        success: true,
        message: '同步成功 (${nodes.length} 个区域)',
      );
    } on TimeoutException {
      return _syncUnavailable(generation);
    } on SocketException {
      return _syncUnavailable(generation);
    } on http.ClientException {
      return _syncUnavailable(generation);
    } on SessionRefreshUnavailableException {
      return _syncUnavailable(generation);
    } catch (error) {
      final message = '同步失败: $error';
      await SyncStateStore.instance.recordError(message);
      return DesktopSyncResult(success: false, message: message);
    } finally {
      _running = false;
      syncing.value = false;
      if (generation != SessionManager.instance.generation &&
          SessionManager.instance.isLoggedIn) {
        unawaited(syncNow());
      }
    }
  }

  // A protected sync endpoint can reject an otherwise valid account session.
  Future<DesktopSyncResult> _handleUnauthorized(
    SessionManager session,
    int generation,
    Map<String, String> headers,
    String endpoint,
    String? purgeOwner,
  ) async {
    addAppLog('连接器同步认证失败: HTTP 401 $endpoint', level: LogLevel.warning);
    http.Response? verification;
    try {
      verification = await session.getWithSessionRecovery(
        client,
        session.buildEndpoint('/api/auth/session'),
        headers,
      );
    } on TimeoutException {
      addAppLog('连接器会话验证超时', level: LogLevel.warning);
    } on Exception {
      addAppLog('连接器会话暂时无法验证', level: LogLevel.warning);
    }
    if (generation != session.generation) {
      return const DesktopSyncResult(
          success: false, message: 'Session changed');
    }

    if (verification != null) {
      final stop = _explicitStopReason(verification);
      if (stop != null) {
        return _stopManagedAccess(stop, purgeOwner, generation);
      }
      if (_isRejectedSession(verification)) {
        await clearManagedConnections();
        if (generation != session.generation) {
          return const DesktopSyncResult(
            success: false,
            message: 'Session changed',
          );
        }
        SyncStateStore.instance.recordTransientError(sessionExpiredMessage);
        return const DesktopSyncResult(
          success: false,
          message: sessionExpiredMessage,
        );
      }
    }
    return _syncUnavailable(generation);
  }

  DesktopSyncResult _syncUnavailable(int generation) {
    if (generation != SessionManager.instance.generation) {
      return const DesktopSyncResult(
          success: false, message: 'Session changed');
    }
    SyncStateStore.instance.recordTransientError(syncUnavailableMessage);
    return const DesktopSyncResult(
      success: false,
      message: syncUnavailableMessage,
    );
  }

  static bool _isRejectedSession(http.Response response) {
    if (response.statusCode != 401) return false;
    try {
      final body = jsonDecode(response.body);
      if (body is! Map) return false;
      const rejected = {
        'invalid_session',
        'session not found',
        'invalid or expired token',
      };
      return rejected.contains(body['code']) ||
          rejected.contains(body['error']);
    } on FormatException {
      return false;
    }
  }

  // Quota status is advisory. Older servers and transient failures must not
  // block node sync or turn an unknown allowance into an exhaustion warning.
  Future<void> _refreshQuota(
    SessionManager session,
    Map<String, String> headers,
    int generation,
  ) async {
    try {
      final response = await client
          .get(
            session.buildEndpoint('/api/account/usage/summary'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (generation != session.generation || response.statusCode != 200) {
        return;
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return;
      final quota = QuotaSnapshot.fromJson(body);
      final store = QuotaNotifications.instance;
      // No quota fields is a legacy response, not proof of recovery.
      if (!quota.unlimited &&
          !quota.paused &&
          (quota.remaining == null || quota.total == null)) {
        return;
      }
      if (store.notice != 'quotaPaused' || quota.notice != 'quotaEmpty') {
        await store.update(
          quota.paused || store.remindersEnabled ? quota.notice : null,
        );
      }
    } catch (_) {
      // Keep the last known status when the optional endpoint is unavailable.
    }
  }

  Future<void> _stopUnauthorizedActiveNode() async {
    final active = GlobalState.activeNodeName.value;
    if (active.trim().isEmpty) return;
    final node = VpnConfig.getNodeByName(active);
    if (node == null || VpnConfig.canUseNode(node)) return;
    await NativeBridge.stopNodeForTunnel();
    await NativeBridge.stopNodeService(active);
    GlobalState.activeNodeName.value = '';
  }

  void _scheduleAccessExpiry() {
    _expiryTimer?.cancel();
    final policy = NetworkAccessPolicy.instance;
    final expiry = policy.expiresAt;
    if (expiry == null) return;
    _expiryTimer = Timer(expiry.difference(DateTime.now()), () {
      policy.invalidate(signedIn: SessionManager.instance.isLoggedIn);
      unawaited(clearManagedConnections());
    });
  }

  /// Withdraw access and server tuning, retaining all managed files/records.
  /// Only explicit enforcement below or a successful replacement can prune.
  Future<void> clearManagedConnections() async {
    _expiryTimer?.cancel();
    final policy = NetworkAccessPolicy.instance;
    policy.invalidate(signedIn: SessionManager.instance.isLoggedIn);
    // Invalidate in-flight tuning requests before any await below.
    final tuningCleared = ClientTuning.clear();
    await policy.clearCachedAccess();
    await _stopUnauthorizedActiveNode();
    await tuningCleared;
    // Withdraw server overrides from the persisted Packet Tunnel profile too.
    unawaited(NativeBridge.refreshPersistedTunnelProfileTuning());
    GlobalState.nodeListRevision.value++;
  }

  /// Suspension is the default. Only these authoritative machine codes permit
  /// deleting the affected account's managed files; custom imports never do.
  static String? _explicitStopReason(http.Response response) {
    if (response.statusCode != 403 &&
        response.statusCode != 429 &&
        response.statusCode != 200) {
      return null;
    }
    try {
      final body = jsonDecode(response.body);
      if (body is! Map) return null;
      if (response.statusCode == 200 && body['allowed'] != false) return null;
      if (QuotaNotifications.isQuotaRejection(response.body)) {
        return 'quotaPaused';
      }
      final code = body['code'] ?? body['error'] ?? body['reason'];
      if (const ['traffic_stopped', 'email_blacklisted'].contains(code)) {
        return code as String;
      }
    } catch (_) {
      // Malformed responses and free-form text are never deletion authority.
    }
    return null;
  }

  Future<DesktopSyncResult> _stopManagedAccess(
    String reason,
    String? owner,
    int generation,
  ) async {
    await clearManagedConnections();
    final session = SessionManager.instance;
    if (generation != session.generation) {
      return const DesktopSyncResult(
        success: false,
        message: 'Session changed',
      );
    }
    // An account whose identity has not been established cannot purge another
    // account's retained snapshot (e.g. switching to a blacklisted account).
    if (owner != null) {
      await XrayConfigWriter.pruneSyncedNodes({}, owner: owner);
      await SyncStateStore.instance.clearNodes();
    }
    if (reason == 'quotaPaused') {
      await QuotaNotifications.instance.update(reason);
    }
    GlobalState.nodeListRevision.value++;
    await SyncStateStore.instance.recordError(reason);
    return DesktopSyncResult(success: false, message: reason);
  }

  /// Best effort: tuning never fails a node sync, and a failed fetch keeps
  /// the last known good tuning. It applies on the next connect, and a change
  /// is written into the persisted Packet Tunnel profile for system relaunch.
  Future<void> _refreshClientTuning(
    SessionManager session,
    Map<String, String> headers, {
    required bool Function() isCurrent,
  }) async {
    final before = jsonEncode(ClientTuning.profile?.toJson());
    try {
      final revision = await ClientTuning.refresh(
        client,
        session.buildEndpoint(ClientTuning.endpointPath),
        headers,
        isCurrent: isCurrent,
      );
      addAppLog(
        revision == null
            ? '服务端未下发连接调优参数，使用内置默认值'
            : '连接调优参数已更新 (revision $revision)，下次连接生效',
      );
      if (jsonEncode(ClientTuning.profile?.toJson()) != before) {
        unawaited(NativeBridge.refreshPersistedTunnelProfileTuning());
      }
    } on ClientTuningStaleException {
      addAppLog('会话已变化，丢弃旧会话的连接调优参数');
    } catch (error) {
      addAppLog('连接调优参数获取失败，继续使用上次的参数: $error', level: LogLevel.warning);
    }
  }

  Future<void> _reloadActiveNode(String nodeName) async {
    try {
      final useTunMode = NativeBridge.isTunMode;
      addAppLog('区域节点配置已更新，正在重载当前连接: $nodeName');
      if (useTunMode) {
        final stopMsg = await (stopTunnelForTesting != null
            ? stopTunnelForTesting!()
            : NativeBridge.stopNodeForTunnel());
        addAppLog('[sync reload] $stopMsg');
        final startMsg = await (startTunnelForTesting != null
            ? startTunnelForTesting!(nodeName)
            : NativeBridge.startNodeForTunnel(nodeName));
        addAppLog('[sync reload] $startMsg');
        if (startMsg.contains('失败') || startMsg.contains('not authorized')) {
          GlobalState.activeNodeName.value = '';
        }
      } else {
        final stopMsg = await (stopNodeServiceForTesting != null
            ? stopNodeServiceForTesting!(nodeName)
            : NativeBridge.stopNodeService(nodeName));
        addAppLog('[sync reload] $stopMsg');
        final startMsg = await (startNodeServiceForTesting != null
            ? startNodeServiceForTesting!(nodeName)
            : NativeBridge.startNodeService(nodeName));
        addAppLog('[sync reload] $startMsg');
        if (startNodeServiceForTesting == null) {
          final running = await NativeBridge.checkNodeStatus(nodeName);
          if (!running) {
            GlobalState.activeNodeName.value = '';
          }
        }
        await _refreshPersistedIosProfileIfApplicable();
      }
    } catch (error) {
      addAppLog('同步后重载活动节点失败: $error', level: LogLevel.warning);
    }
  }

  Future<void> _refreshPersistedIosProfileIfApplicable() async {
    try {
      if (refreshIosPacketTunnelProfileForTesting != null) {
        await refreshIosPacketTunnelProfileForTesting!();
        return;
      }
      if (!Platform.isIOS) return;
      await NativeBridge.refreshPersistedIosPacketTunnelProfile();
    } catch (error) {
      addAppLog('同步后刷新 iOS Packet Tunnel 配置失败: $error',
          level: LogLevel.warning);
    }
  }

  void _onSessionChanged() {
    _timer?.cancel();
    SyncStateStore.instance.clearTransientError(sessionExpiredMessage);
    SyncStateStore.instance.clearTransientError(syncUnavailableMessage);
    if (!SessionManager.instance.isLoggedIn) {
      unawaited(QuotaNotifications.instance.selectAccount(null));
      return;
    }
    unawaited(syncNow());
    _timer = Timer.periodic(_autoInterval, (_) => unawaited(syncNow()));
  }

  @visibleForTesting
  SyncedNodeMetadata? parseNodeForTesting(Map<Object?, Object?> node) =>
      _parseNode(node);

  SyncedNodeMetadata? _parseNode(Map<Object?, Object?> node) {
    String valueFrom(Map<Object?, Object?> source, List<String> keys) {
      for (final key in keys) {
        final raw = source[key];
        if (raw is String && raw.trim().isNotEmpty) return raw.trim();
      }
      return '';
    }

    String? nullableValueFrom(
      Map<Object?, Object?> source,
      List<String> keys,
    ) {
      final found = valueFrom(source, keys);
      return found.isEmpty ? null : found;
    }

    String value(List<String> keys) => valueFrom(node, keys);

    final id = value(['id', 'address']);
    final name = value(['name', 'display_name', 'remark', 'region', 'id']);
    final uri = value([
      'uri_scheme_xhttp',
      'uri_scheme_tcp',
      'vless_uri',
      'uri',
    ]);
    if (id.isEmpty || name.isEmpty || !uri.startsWith('vless://')) return null;

    final rawRouting = node['routing'];
    final routingMap = rawRouting is Map ? _normalizeJsonMap(rawRouting) : null;
    final routingPool = nullableValueFrom(
      node,
      const ['routing_pool', 'routingPool', 'pool'],
    );
    final pricingGroup = nullableValueFrom(
      node,
      const ['pricing_group', 'pricingGroup'],
    );
    final domainStrategy = nullableValueFrom(
          node,
          const ['domain_strategy', 'domainStrategy'],
        ) ??
        (routingMap == null
            ? null
            : nullableValueFrom(
                routingMap,
                const ['domainStrategy', 'domain_strategy'],
              ));
    final routingRules = _extractRoutingRules(
      node,
      routingMap,
    );

    return SyncedNodeMetadata(
      id: id,
      name: name,
      vlessUri: uri,
      region: value(['region', 'country_code']).toLowerCase(),
      protocol: value(['protocol']),
      transport: value(['transport', 'network']),
      security: value(['security']),
      routingPool: routingPool,
      pricingGroup: pricingGroup,
      domainStrategy: domainStrategy,
      routingRules: routingRules,
      routing: routingMap,
    );
  }

  static List<Map<String, dynamic>> _extractRoutingRules(
    Map<Object?, Object?> node,
    Map<String, dynamic>? routingMap,
  ) {
    final candidates = <Object?>[
      node['routing_rules'],
      node['routingRules'],
      routingMap?['rules'],
      routingMap?['routing_rules'],
      routingMap?['routingRules'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List || candidate.isEmpty) continue;
      final normalized = candidate
          .whereType<Map>()
          .map(_normalizeJsonMap)
          .where((rule) => rule.isNotEmpty)
          .toList();
      if (normalized.isNotEmpty) return normalized;
    }
    return const <Map<String, dynamic>>[];
  }

  static Map<String, dynamic> _normalizeJsonMap(Map<Object?, Object?> raw) {
    final result = <String, dynamic>{};
    raw.forEach((key, value) {
      if (key == null) return;
      result[key.toString()] = _normalizeJsonValue(value);
    });
    return result;
  }

  static Object? _normalizeJsonValue(Object? value) {
    if (value is Map) {
      return _normalizeJsonMap(value);
    }
    if (value is List) {
      return value.map(_normalizeJsonValue).toList();
    }
    return value;
  }

  static bool _isRenderable(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['outbounds'] is! List) return false;
      return (decoded['outbounds'] as List).any(
        (item) =>
            item is Map && item['tag'] == 'proxy' && item['protocol'] is String,
      );
    } catch (_) {
      return false;
    }
  }
}
