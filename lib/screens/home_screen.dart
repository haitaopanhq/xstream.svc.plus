import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';

import '../../utils/native_bridge.dart';
import '../../utils/global_config.dart' show GlobalState;
import '../../utils/app_logger.dart';
import '../l10n/app_localizations.dart';
import '../../services/permission_guide_service.dart';
import '../../services/desktop/desktop_platform_capabilities.dart';
import '../../services/vpn_config_service.dart';
import '../widgets/permission_guide_dialog.dart';
import '../widgets/log_console.dart' show LogLevel;
import '../utils/app_theme.dart';

/// Whether the home card may present a live connection.
///
/// A selected node is not a tunnel. On packet-tunnel platforms Android
/// answers `vpn_permission_requested` the moment it launches the system
/// consent dialog — a legitimately accepted start that may still end in the
/// OS refusing consent. Keying the card off the node alone is what painted it
/// green on the Pixel 7a with no tun device behind it (2026-09-20), so the
/// tunnel's own state is the authority wherever there is one.
bool hasLiveTunnel({
  required String activeNode,
  required bool requiresPacketTunnelStatus,
  required String packetTunnelStatus,
}) {
  if (activeNode.trim().isEmpty) return false;
  if (!requiresPacketTunnelStatus) return true;
  return packetTunnelStatus == 'connected';
}

/// Whether tapping a node should stop it rather than start it.
///
/// This must agree with what the button says. The card, its colour and the
/// button label all come from [hasLiveTunnel]; branching the action on the
/// selected node alone made the button read 开始连接 while the handler ran a
/// disconnect, so a tunnel that had failed could never be retried — tapping
/// connect just answered "Tunnel disconnected" forever (Pixel 7a, 2026-09-20).
bool shouldStopInsteadOfStart({
  required String activeNode,
  required String tappedNode,
  required bool hasLiveTunnel,
  required bool tunnelPending,
}) {
  if (activeNode != tappedNode) return false;
  return hasLiveTunnel || tunnelPending;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _LatencyVisual {
  final String value;
  final String label;
  final Color color;

  const _LatencyVisual({
    required this.value,
    required this.label,
    required this.color,
  });
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _emptyMetricValue = '— —';
  static final List<Uri> _latencyProbeUris = <Uri>[
    Uri(scheme: 'https', host: 'google.com', path: '/generate_204'),
    Uri(scheme: 'https', host: 'github.com', path: '/'),
    Uri(scheme: 'https', host: 'openai.com', path: '/'),
  ];
  String _activeNode = '';
  String _selectedNode = '';
  String _highlightNode = '';
  bool _showNodeOptions = false;
  bool _isSwitchingNode = false;
  bool _latencyProbeInFlight = false;
  List<VpnNode> vpnNodes = [];
  final Map<String, int> _latencyByNode = {};
  DateTime? _connectedAt;
  Timer? _durationTimer;
  Timer? _statusTimer;
  Timer? _metricsTimer;
  Timer? _latencyTimer;
  Duration _connectedDuration = Duration.zero;
  String _connectedLocation = '-';
  PacketTunnelStatus _packetTunnelStatus = const PacketTunnelStatus(
    status: 'unknown',
    utunInterfaces: [],
  );
  PacketTunnelMetricsSnapshot _packetTunnelMetrics =
      const PacketTunnelMetricsSnapshot();
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  void _showMessage(String msg, {Color? bgColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: bgColor));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GlobalState.nodeListRevision.addListener(_onNodeListRevisionChanged);
    GlobalState.activeNodeName.addListener(_onActiveNodeChanged);
    GlobalState.connectionMode.addListener(_onConnectionModeChanged);
    _initializeConfig();
    _updateMonitoringState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _durationTimer?.cancel();
    _statusTimer?.cancel();
    _metricsTimer?.cancel();
    _latencyTimer?.cancel();
    GlobalState.nodeListRevision.removeListener(_onNodeListRevisionChanged);
    GlobalState.activeNodeName.removeListener(_onActiveNodeChanged);
    GlobalState.connectionMode.removeListener(_onConnectionModeChanged);
    super.dispose();
  }

  Future<void> _initializeConfig() async {
    await VpnConfig.load();
    if (!mounted) return;
    final loaded = List<VpnNode>.from(VpnConfig.nodes);
    if (loaded.isEmpty) {
      setState(() {
        vpnNodes = const [];
        _activeNode = '';
        _highlightNode = '';
        _selectedNode = '';
        _showNodeOptions = false;
        _connectedAt = null;
        _connectedDuration = Duration.zero;
        _connectedLocation = '-';
      });
      _durationTimer?.cancel();
      _durationTimer = null;
      GlobalState.activeNodeName.value = '';
      GlobalState.lastImportedNodeName.value = '';
      _updateMonitoringState();
      return;
    }

    setState(() {
      vpnNodes = loaded;
      _activeNode = GlobalState.activeNodeName.value;
      _highlightNode = GlobalState.lastImportedNodeName.value;
      _selectedNode = _activeNode.isNotEmpty ? _activeNode : _highlightNode;
      _showNodeOptions = false;
    });
    _syncConnectedMeta();
    _scheduleClearHighlight();
    _updateMonitoringState();
    if (_shouldPollPacketTunnelStatus) {
      unawaited(_refreshPacketTunnelStatus());
    }
  }

  Future<void> _onNodeListRevisionChanged() async {
    await _initializeConfig();
  }

  void _onConnectionModeChanged() {
    _updateMonitoringState();
    if (_shouldPollPacketTunnelStatus) {
      unawaited(_refreshPacketTunnelStatus());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    _updateMonitoringState();
  }

  void _onActiveNodeChanged() {
    if (!mounted) return;
    setState(() {
      _activeNode = GlobalState.activeNodeName.value;
      if (_activeNode.isNotEmpty) {
        _selectedNode = _activeNode;
        _highlightNode = _activeNode;
      }
    });
    _syncConnectedMeta();
    _updateMonitoringState();
    if (_shouldPollPacketTunnelStatus) {
      unawaited(_refreshPacketTunnelStatus());
    }
    if (_shouldPollMetrics) {
      unawaited(_refreshPacketTunnelMetrics());
    }
    if (_shouldPollLatency) {
      unawaited(_refreshActiveNodeLatency());
    } else {
      _clearMonitoringData(clearLatency: true);
    }
  }

  DesktopPlatformCapabilities get _desktopCapabilities =>
      DesktopPlatformCapabilities.current;

  bool get _requiresPacketTunnelStatus =>
      Platform.isAndroid ||
      Platform.isIOS ||
      (Platform.isMacOS && NativeBridge.isTunMode) ||
      (_desktopCapabilities.supportsUnifiedTunnelStatus &&
          (Platform.isWindows || Platform.isLinux) &&
          NativeBridge.isTunMode);

  bool get _packetTunnelExplicitlyUnavailable =>
      _packetTunnelStatus.status == 'disconnected' ||
      _packetTunnelStatus.status == 'disconnecting' ||
      _packetTunnelStatus.status == 'invalid' ||
      _packetTunnelStatus.status == 'not_configured';

  bool get _shouldPollPacketTunnelStatus =>
      _appLifecycleState == AppLifecycleState.resumed &&
      _activeNode.isNotEmpty &&
      _requiresPacketTunnelStatus;

  bool get _shouldPollMetrics =>
      _appLifecycleState == AppLifecycleState.resumed &&
      _activeNode.isNotEmpty &&
      ((_requiresPacketTunnelStatus && !_packetTunnelExplicitlyUnavailable) ||
          (!_requiresPacketTunnelStatus &&
              _desktopCapabilities.supportsRuntimeMetrics));

  bool get _shouldPollLatency {
    if (_appLifecycleState != AppLifecycleState.resumed ||
        _activeNode.isEmpty) {
      return false;
    }
    if (Platform.isMacOS && !NativeBridge.isTunMode) {
      return true;
    }
    if (_requiresPacketTunnelStatus) {
      return !_packetTunnelExplicitlyUnavailable;
    }
    return true;
  }

  void _updateMonitoringState() {
    if (_shouldPollPacketTunnelStatus) {
      _startStatusPolling();
    } else {
      _statusTimer?.cancel();
      _statusTimer = null;
    }

    if (_shouldPollMetrics) {
      _startMetricsPolling();
    } else {
      _metricsTimer?.cancel();
      _metricsTimer = null;
    }

    if (_shouldPollLatency) {
      _startLatencyPolling();
    } else {
      _latencyTimer?.cancel();
      _latencyTimer = null;
    }

    if (!_shouldPollMetrics || !_shouldPollLatency) {
      _clearMonitoringData(clearLatency: !_shouldPollLatency);
    }
  }

  void _clearMonitoringData({required bool clearLatency}) {
    final activeNode = _activeNode.trim();
    final hadMetrics = _packetTunnelMetrics.updatedAt != null ||
        _packetTunnelMetrics.downloadBytesPerSecond != null ||
        _packetTunnelMetrics.uploadBytesPerSecond != null ||
        _packetTunnelMetrics.memoryBytes != null ||
        _packetTunnelMetrics.cpuPercent != null;
    final hadLatency = clearLatency &&
        activeNode.isNotEmpty &&
        _latencyByNode.containsKey(activeNode);
    if (!hadMetrics && !hadLatency) {
      return;
    }
    setState(() {
      _packetTunnelMetrics = const PacketTunnelMetricsSnapshot();
      if (hadLatency) {
        _latencyByNode.remove(activeNode);
      }
    });
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    unawaited(_refreshPacketTunnelStatus());
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refreshPacketTunnelStatus());
    });
  }

  Future<void> _refreshPacketTunnelStatus() async {
    if (!_shouldPollPacketTunnelStatus) {
      return;
    }
    final status = await NativeBridge.getPacketTunnelStatus();
    if (!mounted) return;
    final changed = status.status != _packetTunnelStatus.status ||
        status.lastError != _packetTunnelStatus.lastError ||
        status.startedAt != _packetTunnelStatus.startedAt ||
        status.utunInterfaces.join(',') !=
            _packetTunnelStatus.utunInterfaces.join(',');
    if (!changed) {
      return;
    }
    setState(() {
      _packetTunnelStatus = status;
      if (_packetTunnelExplicitlyUnavailable) {
        _packetTunnelMetrics = const PacketTunnelMetricsSnapshot();
        final activeNode = _activeNode.trim();
        if (activeNode.isNotEmpty) {
          _latencyByNode.remove(activeNode);
        }
      }
    });
    _syncConnectedMeta();
    _updateMonitoringState();
  }

  void _syncConnectedMeta() {
    if (_activeNode.isEmpty) {
      _connectedAt = null;
      _connectedDuration = Duration.zero;
      _connectedLocation = '-';
      _durationTimer?.cancel();
      _durationTimer = null;
      return;
    }
    _connectedAt ??= DateTime.now();
    final node = vpnNodes.cast<VpnNode?>().firstWhere(
          (n) => n?.name == _activeNode,
          orElse: () => null,
        );
    _connectedLocation = (node?.countryCode ?? '-').toUpperCase();
    if (_requiresPacketTunnelStatus &&
        _packetTunnelStatus.status != 'connected') {
      _connectedAt = null;
      _connectedDuration = Duration.zero;
      _durationTimer?.cancel();
      _durationTimer = null;
      return;
    }
    _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _connectedAt == null) return;
      setState(() {
        _connectedDuration = DateTime.now().difference(_connectedAt!);
      });
    });
  }

  String _formatDuration(Duration duration) {
    final secs = duration.inSeconds;
    if (secs < 60) return '$secs${context.l10n.get('secondsSuffix')}';
    final mins = secs ~/ 60;
    final rem = secs % 60;
    return '$mins m $rem${context.l10n.get('secondsSuffix')}';
  }

  void _startMetricsPolling() {
    _metricsTimer?.cancel();
    unawaited(_refreshPacketTunnelMetrics());
    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refreshPacketTunnelMetrics());
    });
  }

  void _startLatencyPolling() {
    _latencyTimer?.cancel();
    unawaited(_refreshActiveNodeLatency());
    _latencyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshActiveNodeLatency());
    });
  }

  Future<void> _refreshPacketTunnelMetrics() async {
    if (!_shouldPollMetrics) {
      return;
    }
    final snapshot = await NativeBridge.getPacketTunnelMetrics();
    if (!mounted) return;
    final previous = _packetTunnelMetrics;
    final changed =
        previous.downloadBytesPerSecond != snapshot.downloadBytesPerSecond ||
            previous.uploadBytesPerSecond != snapshot.uploadBytesPerSecond ||
            previous.memoryBytes != snapshot.memoryBytes ||
            previous.cpuPercent != snapshot.cpuPercent ||
            previous.updatedAt != snapshot.updatedAt;
    if (!changed) return;
    setState(() {
      _packetTunnelMetrics = snapshot;
    });
  }

  Future<void> _refreshActiveNodeLatency() async {
    final nodeName = _activeNode.trim();
    if (nodeName.isEmpty || _latencyProbeInFlight || !_shouldPollLatency) {
      return;
    }

    _latencyProbeInFlight = true;
    try {
      final latency = await _probeActiveConnectionLatency();
      if (!mounted || _activeNode.trim() != nodeName) {
        return;
      }
      if (latency == null || latency < 0) {
        if (_latencyByNode.containsKey(nodeName)) {
          setState(() {
            _latencyByNode.remove(nodeName);
          });
        }
        return;
      }
      if (_latencyByNode[nodeName] == latency) {
        return;
      }
      setState(() {
        _latencyByNode[nodeName] = latency;
      });
    } finally {
      _latencyProbeInFlight = false;
    }
  }

  Future<int?> _probeActiveConnectionLatency() async {
    if (_desktopCapabilities.usesLocalProxyLatencyProbe &&
        !NativeBridge.isTunMode) {
      final watch = Stopwatch()..start();
      final result = await NativeBridge.verifySocks5Proxy();
      watch.stop();
      if (result.startsWith('success:')) {
        return watch.elapsedMilliseconds;
      }
      return null;
    }
    return _probeSystemTunnelLatency();
  }

  Future<int?> _probeSystemTunnelLatency() async {
    if (_requiresPacketTunnelStatus && _packetTunnelExplicitlyUnavailable) {
      return null;
    }
    final samples = <int>[];
    for (final uri in _latencyProbeUris) {
      final latency = await _probeLatencyViaHttp(uri);
      if (latency != null) {
        samples.add(latency);
      }
    }
    if (samples.isEmpty) {
      return null;
    }
    final total = samples.fold<int>(0, (sum, value) => sum + value);
    return (total / samples.length).round();
  }

  Future<int?> _probeLatencyViaHttp(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final watch = Stopwatch()..start();
      final request =
          await client.headUrl(uri).timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
            const Duration(seconds: 4),
          );
      await response.drain<void>();
      watch.stop();
      if (response.statusCode >= 200 && response.statusCode < 500) {
        return watch.elapsedMilliseconds;
      }
    } catch (_) {
      try {
        final watch = Stopwatch()..start();
        final request =
            await client.getUrl(uri).timeout(const Duration(seconds: 4));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final response = await request.close().timeout(
              const Duration(seconds: 4),
            );
        await response.drain<void>();
        watch.stop();
        if (response.statusCode >= 200 && response.statusCode < 500) {
          return watch.elapsedMilliseconds;
        }
      } catch (_) {
        return null;
      }
    } finally {
      client.close(force: true);
    }
    return null;
  }

  void _scheduleClearHighlight() {
    if (_highlightNode.isEmpty) return;
    Future<void>.delayed(const Duration(seconds: 12), () {
      if (!mounted) return;
      if (_highlightNode == GlobalState.lastImportedNodeName.value) {
        setState(() {
          _highlightNode = '';
        });
      }
    });
  }

  VpnNode? _resolveActionNode() {
    final selected = _selectedNode.trim();
    if (selected.isNotEmpty) {
      for (final node in vpnNodes) {
        if (node.name == selected) return node;
      }
    }
    final active = _activeNode.trim();
    if (active.isNotEmpty) {
      for (final node in vpnNodes) {
        if (node.name == active) return node;
      }
    }
    return vpnNodes.isNotEmpty ? vpnNodes.first : null;
  }

  void _selectNode(VpnNode node) {
    setState(() {
      _selectedNode = node.name;
      _highlightNode = node.name;
      _showNodeOptions = false;
      GlobalState.lastImportedNodeName.value = node.name;
    });
    _scheduleClearHighlight();
  }

  Future<void> _toggleFromFloatingButton() async {
    if (_isSwitchingNode) return;
    final node = _resolveActionNode();
    if (node == null) {
      _showMessage(context.l10n.get('noNodes'));
      return;
    }
    await _toggleNode(node);
  }

  Future<void> _toggleNode(VpnNode node) async {
    if (_isSwitchingNode) return;
    final nodeName = node.name.trim();
    if (nodeName.isEmpty) return;
    setState(() => _isSwitchingNode = true);
    final useTunMode = NativeBridge.isTunMode;
    try {
      // ── Stop active node ──────────────────────────────────────────
      if (shouldStopInsteadOfStart(
        activeNode: _activeNode,
        tappedNode: nodeName,
        hasLiveTunnel: _hasActiveConnection,
        tunnelPending: _tunnelPending,
      )) {
        // Prevent leaks if connection mode was changed during an active session by stopping both
        await NativeBridge.stopNodeForTunnel();
        final msg = await NativeBridge.stopNodeService(nodeName);
        if (!mounted) return;
        setState(() {
          _activeNode = '';
          _selectedNode = nodeName;
        });
        GlobalState.activeNodeName.value = '';
        _syncConnectedMeta();
        _showMessage(useTunMode ? 'Tunnel disconnected' : msg);
        return;
      }

      // ── Stop previous node if switching ───────────────────────────
      if (_activeNode.isNotEmpty) {
        await NativeBridge.stopNodeForTunnel();
        await NativeBridge.stopNodeService(_activeNode);
        if (!mounted) return;
        GlobalState.activeNodeName.value = '';
      }

      // ── Check if already running (proxy mode only) ────────────────
      if (!useTunMode) {
        final isRunning = await NativeBridge.checkNodeStatus(nodeName);
        if (!mounted) return;
        if (isRunning) {
          setState(() {
            _activeNode = nodeName;
            _selectedNode = nodeName;
            _highlightNode = nodeName;
          });
          GlobalState.activeNodeName.value = nodeName;
          _syncConnectedMeta();
          _showMessage(context.l10n.get('serviceRunning'));
          return;
        }
      }

      // ── Start node ────────────────────────────────────────────────
      final startedAt = DateTime.now();
      final msg = useTunMode
          ? await NativeBridge.startNodeForTunnel(nodeName)
          : await NativeBridge.startNodeService(nodeName);
      if (!mounted) return;

      // Determine if start succeeded
      final startOk = useTunMode
          ? NativeBridge.isTunnelStartAcceptedMessage(msg)
          : (msg.toLowerCase().startsWith('success') ||
              msg.contains('服务已在运行') ||
              await NativeBridge.checkNodeStatus(nodeName));
      if (!mounted) return;
      if (!startOk) {
        setState(() {
          _selectedNode = nodeName;
          _highlightNode = nodeName;
        });
        GlobalState.activeNodeName.value = '';
        _syncConnectedMeta();
        _showMessage(msg.endsWith('traffic_routing_unsupported_profile')
            ? context.l10n.get('trafficModeUnsupportedProfile')
            : msg);
        if (useTunMode) {
          await _maybeShowPacketTunnelPermissionGuide(msg);
        }
        _scheduleClearHighlight();
        return;
      }

      setState(() {
        _activeNode = nodeName;
        _selectedNode = nodeName;
        _highlightNode = nodeName;
      });
      GlobalState.activeNodeName.value = nodeName;
      _syncConnectedMeta();
      _showMessage(msg);
      _scheduleClearHighlight();

      // ── Verify connectivity ───────────────────────────────────────
      if (!useTunMode) {
        // Proxy mode: verify SOCKS5 proxy is reachable
        final verifyMsg = await NativeBridge.verifySocks5Proxy();
        final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
        if (verifyMsg.startsWith('success:')) {
          _latencyByNode[nodeName] = elapsed;
        }
        addAppLog(
          '[socks5] $verifyMsg',
          level:
              verifyMsg.startsWith('success:') ? LogLevel.info : LogLevel.error,
        );
        _showMessage(verifyMsg);
      } else {
        // TUN mode: log the launch result, then confirm the data plane in the
        // background. The probe takes seconds to settle, so it must not hold
        // the toggle disabled; it aborts on its own if the user disconnects.
        addAppLog('[tunnel] $msg');
        unawaited(_verifyTunnelDataPlane());
      }
    } finally {
      if (mounted) {
        setState(() => _isSwitchingNode = false);
      } else {
        _isSwitchingNode = false;
      }
    }
  }

  /// Confirm the tunnel carries traffic, and surface the result.
  ///
  /// The probe is advisory. On Android the Xray process and this control UI
  /// share the excluded UID, so their sockets intentionally stay on the
  /// underlying network while other applications use the Packet Tunnel.
  /// Device-level traffic is validated separately with an external app.
  Future<void> _verifyTunnelDataPlane() async {
    final report = await NativeBridge.verifyTunnelDataPlane();
    if (!mounted) return;
    if (report.ok) {
      addAppLog('[tunnel] ${report.describe()}');
      return;
    }
    if (!report.isConclusiveFailure) {
      // Tunnel went away mid-probe: says nothing about data-plane health.
      addAppLog('[tunnel] ${report.describe()}', level: LogLevel.info);
      return;
    }
    addAppLog('[tunnel] ${report.describe()}', level: LogLevel.error);
    _showMessage(report.describe());
  }

  Future<void> _maybeShowPacketTunnelPermissionGuide(
    String failureMessage,
  ) async {
    final shouldShow =
        await PermissionGuideService.shouldPromptForPacketTunnelAuthorization(
      failureMessage: failureMessage,
    );
    if (!mounted || !shouldShow) return;
    await showPermissionGuideDialog(context, failureMessage: failureMessage);
  }

  PacketTunnelMetricsSnapshot get _visibleMetrics {
    final updatedAt = _packetTunnelMetrics.updatedAt;
    if (_activeNode.isEmpty ||
        updatedAt == null ||
        (_requiresPacketTunnelStatus && _packetTunnelExplicitlyUnavailable) ||
        (!_requiresPacketTunnelStatus &&
            !_desktopCapabilities.supportsRuntimeMetrics)) {
      return const PacketTunnelMetricsSnapshot();
    }
    final age = DateTime.now().millisecondsSinceEpoch - updatedAt;
    if (age > 4500) {
      return const PacketTunnelMetricsSnapshot();
    }
    return _packetTunnelMetrics;
  }

  String _formatRate(int? bytesPerSecond) {
    if (bytesPerSecond == null || bytesPerSecond < 0) {
      return _emptyMetricValue;
    }
    final value = bytesPerSecond.toDouble();
    if (value >= 1024 * 1024) {
      final mb = value / (1024 * 1024);
      final digits = mb >= 10 ? 1 : 2;
      return '${mb.toStringAsFixed(digits)} MB/s';
    }
    final kb = value / 1024;
    final digits = kb >= 100 ? 0 : 1;
    return '${kb.toStringAsFixed(digits)} KB/s';
  }

  String _formatMemory(int? memoryBytes) {
    if (memoryBytes == null || memoryBytes < 0) {
      return _emptyMetricValue;
    }
    final mb = memoryBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  String _formatCpu(double? cpuPercent) {
    if (cpuPercent == null || cpuPercent.isNaN) {
      return _emptyMetricValue;
    }
    return '${cpuPercent.toStringAsFixed(0)}%';
  }

  _LatencyVisual _latencyVisual(BuildContext context, int? latency) {
    final xc = context.xColors;
    if (latency == null || latency < 0) {
      return _LatencyVisual(
        value: _emptyMetricValue,
        label: '',
        color: xc.subtleText,
      );
    }
    if (latency < 300) {
      return _LatencyVisual(
        value: '${latency}ms',
        color: xc.success,
        label: '',
      );
    }
    if (latency <= 500) {
      return _LatencyVisual(
        value: '${latency}ms',
        color: xc.warning,
        label: '',
      );
    }
    if (latency <= 800) {
      return _LatencyVisual(
        value: '${latency}ms',
        color: xc.error,
        label: '',
      );
    }
    return _LatencyVisual(
      value: '${latency}ms',
      color: xc.error,
      label: '',
    );
  }

  Widget _buildMetricValue(
    String value,
    TextStyle style, {
    TextAlign textAlign = TextAlign.left,
  }) {
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final offsetAnimation = Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: Text(
        value,
        key: ValueKey(value),
        textAlign: textAlign,
        style: style,
      ),
    );
  }

  Widget _buildMonitoringCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    final xc = context.xColors;
    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.standard),
      padding: padding,
      decoration: BoxDecoration(
        color: xc.cardBackground,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: xc.cardBorder),
      ),
      child: child,
    );
  }

  Widget _buildMetricBadge(IconData icon, Color color) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }

  bool get _hasActiveConnection => hasLiveTunnel(
        activeNode: _activeNode,
        requiresPacketTunnelStatus: _requiresPacketTunnelStatus,
        packetTunnelStatus: _packetTunnelStatus.status,
      );

  /// A node is selected and the tunnel has not (yet) come up behind it.
  ///
  /// This is the window in which Android is showing its consent dialog. The
  /// status poll promotes us to connected, or to a failed state if the OS
  /// denies; either way the card stops claiming a tunnel it does not have.
  bool get _tunnelPending =>
      _activeNode.trim().isNotEmpty &&
      _requiresPacketTunnelStatus &&
      !_hasActiveConnection &&
      !_packetTunnelExplicitlyUnavailable;

  String _connectionStateLabel(BuildContext context) {
    if (_isSwitchingNode) {
      return _hasActiveConnection
          ? context.l10n.get('tunStatusDisconnecting')
          : context.l10n.get('tunStatusConnecting');
    }
    if (_hasActiveConnection) {
      return context.l10n.get('tunStatusConnected');
    }
    if (_tunnelPending) {
      return context.l10n.get('tunStatusConnecting');
    }
    return context.l10n.get('tunStatusDisconnected');
  }

  Color _connectionStateColor() {
    final xc = context.xColors;
    if (_isSwitchingNode) {
      return xc.warning;
    }
    if (_hasActiveConnection) return xc.success;
    return _tunnelPending ? xc.warning : xc.mutedText;
  }

  String _connectionMetaLine(BuildContext context) {
    if (!_hasActiveConnection) {
      return '';
    }
    final parts = <String>[
      '${context.l10n.get('homeStatusDuration')}: ${_formatDuration(_connectedDuration)}',
      if (_connectedLocation != '-')
        '${context.l10n.get('homeStatusLocation')}: $_connectedLocation',
    ];
    return parts.join(' · ');
  }

  Widget _buildTrafficMetric({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildMetricBadge(icon, color),
              const SizedBox(width: 10),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: xc.mutedText),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildMetricValue(
            value,
            Theme.of(context).textTheme.displaySmall!.copyWith(
                  color: cs.onSurface,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildLatencyChip(
    BuildContext context,
    _LatencyVisual latency, {
    bool compact = false,
  }) {
    final xc = context.xColors;
    final isEmpty = latency.value == _emptyMetricValue;
    final theme = Theme.of(context);
    final textStyle =
        (compact ? theme.textTheme.labelSmall : theme.textTheme.labelLarge)
            ?.copyWith(
      color: isEmpty ? xc.mutedText : latency.color,
      fontWeight: FontWeight.w600,
    );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color:
            isEmpty ? xc.surfaceSunken : latency.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: isEmpty
            ? null
            : Border.all(color: latency.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 7 : 8,
            height: compact ? 7 : 8,
            decoration: BoxDecoration(
              color: latency.color,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: compact ? 6 : 8),
          Text(
            '${context.l10n.get('homeStatusLatency')} ${latency.value}',
            style: textStyle,
          ),
          if (latency.label.isNotEmpty) ...[
            SizedBox(width: compact ? 4 : 6),
            Text(
              latency.label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: compact ? 11 : 12,
                color: xc.mutedText,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomStatCell({
    required String label,
    required String value,
    Color? valueColor,
    Widget? leading,
  }) {
    final xc = context.xColors;
    final effectiveColor = valueColor ?? xc.mutedText;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 6)],
        Flexible(
          child: RichText(
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$label ',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: xc.subtleText),
                ),
                TextSpan(
                  text: value,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: effectiveColor,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryStatusChip(BuildContext context, VpnNode? node) {
    final xc = context.xColors;
    if (node != null && _activeNode == node.name) {
      return _buildLatencyChip(
        context,
        _latencyVisual(context, _latencyByNode[node.name]),
        compact: true,
      );
    }

    final color = _connectionStateColor();
    final isConnected = _hasActiveConnection;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isConnected ? xc.successMuted : xc.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: isConnected
            ? Border.all(color: xc.success.withValues(alpha: 0.3))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            _connectionStateLabel(context),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(
                  color: isConnected ? xc.successForeground : color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryStatusCard(BuildContext context) {
    final metrics = _visibleMetrics;
    final displayNode = _resolveActionNode();
    final nodeName = displayNode?.name ?? context.l10n.get('noNodes');
    final latency = _latencyVisual(
      context,
      _hasActiveConnection ? _latencyByNode[_activeNode] : null,
    );
    final connectionColor = _connectionStateColor();
    final metaLine = _connectionMetaLine(context);

    return _buildMonitoringCard(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: connectionColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Connecting/disconnecting is otherwise a silent
                        // change for anyone not watching the colour.
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _connectionStateLabel(context),
                            style: Theme.of(
                              context,
                            ).textTheme.headlineSmall?.copyWith(
                                  color: connectionColor,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      nodeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        metaLine,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _buildTrafficMetric(
                  label: context.l10n.get('homeStatusDownload'),
                  value: _formatRate(metrics.downloadBytesPerSecond),
                  icon: Icons.south_rounded,
                  color: context.xColors.download,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildTrafficMetric(
                  label: context.l10n.get('homeStatusUpload'),
                  value: _formatRate(metrics.uploadBytesPerSecond),
                  icon: Icons.north_rounded,
                  color: context.xColors.upload,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _buildBottomStatCell(
                  label: context.l10n.get('homeStatusCpu'),
                  value: _formatCpu(metrics.cpuPercent),
                ),
              ),
              Expanded(
                child: _buildBottomStatCell(
                  label: context.l10n.get('homeStatusMemory'),
                  value: _formatMemory(metrics.memoryBytes),
                ),
              ),
              Expanded(
                child: _buildBottomStatCell(
                  label: context.l10n.get('homeStatusLatency'),
                  value: latency.value,
                  valueColor: latency.value == _emptyMetricValue
                      ? context.xColors.mutedText
                      : latency.color,
                  leading: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: latency.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNodeOptionChip(BuildContext context, VpnNode node) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;
    final isActive = _activeNode == node.name;
    final isSelected = _selectedNode == node.name;
    final isHighlighted = _highlightNode == node.name;
    final latency = _latencyByNode[node.name];
    final emphasized = isActive || isSelected || isHighlighted;

    Color labelColor = cs.onSurface;
    Color chipBg = xc.surfaceSunken;
    BorderSide borderSide = BorderSide.none;

    if (isActive) {
      labelColor = xc.successForeground;
      chipBg = xc.successMuted;
      borderSide = BorderSide(color: xc.success);
    } else if (isSelected || isHighlighted) {
      labelColor = cs.primary;
      chipBg = xc.brandMuted;
      borderSide = BorderSide(color: xc.brandBorder);
    }

    final routingPool = (node.routingPool ?? '').trim();
    final sourceLabel = context.l10n.get(
      node.isManaged ? 'nodeSourceManaged' : 'nodeSourceImported',
    );
    final labelText = latency == null
        ? '${node.name} · $sourceLabel'
        : '${node.name} · $sourceLabel · ${latency}ms';

    return Semantics(
      button: true,
      selected: emphasized,
      label: isActive
          ? '${node.name} ${context.l10n.get('tunStatusConnected')}'
          : node.name,
      child: ChoiceChip(
        showCheckmark: false,
        selected: emphasized,
        avatar: isActive
            ? ExcludeSemantics(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: xc.success,
                    shape: BoxShape.circle,
                  ),
                ),
              )
            : null,
        label: routingPool.isEmpty
            ? Text(labelText, overflow: TextOverflow.ellipsis)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(labelText, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      routingPool.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: labelColor,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
        labelStyle: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(
              color: labelColor,
            ),
        backgroundColor: chipBg,
        selectedColor: chipBg,
        side: borderSide,
        shape: const StadiumBorder(),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (!_isSwitchingNode) ? (_) => _selectNode(node) : null,
      ),
    );
  }

  Widget _buildNodeSummarySection(BuildContext context) {
    final node = _resolveActionNode();
    final hasNodes = vpnNodes.isNotEmpty;

    return _buildMonitoringCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        children: [
          Semantics(
            button: hasNodes,
            enabled: hasNodes,
            expanded: hasNodes ? _showNodeOptions : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: hasNodes
                  ? () => setState(() => _showNodeOptions = !_showNodeOptions)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 20,
                      color: context.xColors.mutedText,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.get('nodeList'),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            node?.name ?? context.l10n.get('noNodes'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _buildSummaryStatusChip(context, node),
                    if (hasNodes) ...[
                      const SizedBox(width: 8),
                      AnimatedRotation(
                        turns: _showNodeOptions ? 0.5 : 0,
                        duration: AppMotion.of(context, AppMotion.standard),
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: context.xColors.subtleText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.of(context, AppMotion.standard),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !hasNodes || !_showNodeOptions
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final node in vpnNodes)
                            _buildNodeOptionChip(context, node),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitoringDashboard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_buildPrimaryStatusCard(context)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMonitoringDashboard(context),
                      const SizedBox(height: 16),
                      _buildNodeSummarySection(context),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 20,
              bottom: 20,
              // The one ink block on this screen. Everything else on the home
              // surface is a fill; this is the only element allowed to carry
              // full contrast, because it is the primary action.
              child: Semantics(
                button: true,
                enabled: !_isSwitchingNode,
                child: FloatingActionButton.extended(
                  heroTag: 'home_connection_control',
                  backgroundColor: _hasActiveConnection ? xc.success : xc.ink,
                  foregroundColor: xc.onInk,
                  onPressed:
                      _isSwitchingNode ? null : _toggleFromFloatingButton,
                  icon: _isSwitchingNode
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: xc.onInk,
                          ),
                        )
                      : Icon(
                          _hasActiveConnection
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                        ),
                  label: Text(
                    _isSwitchingNode
                        ? _connectionStateLabel(context)
                        : (_hasActiveConnection
                            ? context.l10n.get('stopAcceleration')
                            : context.l10n.get('startAcceleration')),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
