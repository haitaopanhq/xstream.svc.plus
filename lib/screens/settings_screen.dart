import '../widgets/quota_notification_button.dart';
import '../widgets/traffic_mode_group.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';
import '../../utils/global_config.dart'
    show GlobalState, DnsConfig, GlobalApplicationConfig, XhttpAdvancedConfig;
import '../../utils/native_bridge.dart';
import '../../utils/settings_tab_navigation.dart';
import '../../services/app_version_service.dart';
import '../../services/desktop/desktop_platform_capabilities.dart';
import '../l10n/app_localizations.dart';
import '../../services/vpn_config_service.dart';
import '../../services/telemetry/telemetry_service.dart';
import '../../services/session/session_manager.dart';
import '../../services/sync/desktop_sync_service.dart';
import '../../services/mcp/runtime_mcp_service.dart';
import '../../utils/app_logger.dart';
import '../utils/app_theme.dart';
import '../screens/about_screen.dart';
import '../screens/help_screen.dart';
import '../screens/logs_screen.dart';
import '../widgets/permission_guide_dialog.dart';
import '../widgets/diagnostics/live_metrics_panel.dart';
import '../widgets/diagnostics/browser_privacy_section.dart';
import '../widgets/repair/repair_section.dart';
import '../widgets/settings_row.dart';
import '../widgets/settings_tab_bar.dart';
import '../widgets/log_console.dart' show LogLevel;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PacketTunnelStatus _tunStatus = const PacketTunnelStatus(
    status: 'unknown',
    utunInterfaces: [],
  );

  final SessionManager _sessionManager = SessionManager.instance;
  final RuntimeMcpService _runtimeMcpService = RuntimeMcpService.instance;
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _mfaCodeController = TextEditingController();
  final TextEditingController _xhttpXmuxMaxConcurrencyController =
      TextEditingController();
  // Held on the state rather than rebuilt in build(): a controller recreated
  // every frame resets the selection and drops the cursor to the start.
  final TextEditingController _socksPortController = TextEditingController();
  final TextEditingController _httpPortController = TextEditingController();

  /// Index into the tab list built by [_settingsTabs].
  int _selectedTab = 0;
  String _draftXhttpMode = XhttpAdvancedConfig.mode.value;
  Set<String> _draftXhttpAlpn = <String>{...XhttpAdvancedConfig.alpn.value};
  String _draftXhttpXmuxMaxConcurrency =
      XhttpAdvancedConfig.xmuxMaxConcurrency.value;
  // Values shown when the draft was loaded. Only fields the user changed
  // from these are saved, and so marked as their own choice.
  String _loadedXhttpMode = XhttpAdvancedConfig.mode.value;
  String _loadedXhttpXmuxMaxConcurrency =
      XhttpAdvancedConfig.xmuxMaxConcurrency.value;
  bool _xhttpAdvancedDirty = false;

  DesktopPlatformCapabilities get _desktopCapabilities =>
      DesktopPlatformCapabilities.current;

  @override
  void initState() {
    super.initState();
    _loadXhttpAdvancedDraft();
    _baseUrlController.text = _sessionManager.baseUrl.value;
    _usernameController.text = _sessionManager.currentUser.value ?? '';
    _sessionManager.baseUrl.addListener(_syncBaseUrlFromSession);
    _sessionManager.currentUser.addListener(_syncUsernameFromSession);
    _socksPortController.text = GlobalState.socksPort.value;
    _httpPortController.text = GlobalState.httpPort.value;
    _refreshTunStatus();
    _runtimeMcpService.init();
    GlobalState.settingsTabRequest.addListener(_onSettingsTabRequested);
  }

  /// Wakes the widget so [_buildSettingsView] can resolve and consume the
  /// pending request. The actual index lookup happens there, where the
  /// platform-filtered tab list (and its ids) already exist for this frame.
  void _onSettingsTabRequested() {
    if (!mounted) return;
    if (GlobalState.settingsTabRequest.value != null) {
      setState(() {});
    }
  }

  void _syncBaseUrlFromSession() {
    final value = _sessionManager.baseUrl.value;
    if (_baseUrlController.text != value) {
      _baseUrlController.text = value;
    }
  }

  void _syncUsernameFromSession() {
    final value = _sessionManager.currentUser.value ?? '';
    if (_usernameController.text != value) {
      _usernameController.text = value;
    }
  }

  /// Human-readable tunnel state.
  ///
  /// Deliberately omits `status.utunInterfaces`: that list is mostly made up of
  /// interfaces owned by other software (iCloud Private Relay, other VPNs), so
  /// showing it here implied we controlled all of them. It remains available in
  /// the logs for diagnostics.
  String _tunStatusLabel(BuildContext context, PacketTunnelStatus status) {
    return switch (status.status) {
      'connected' => context.l10n.get('tunStatusConnected'),
      'connecting' => context.l10n.get('tunStatusConnecting'),
      'disconnected' => context.l10n.get('tunStatusDisconnected'),
      'disconnecting' => context.l10n.get('tunStatusDisconnecting'),
      'invalid' => context.l10n.get('tunStatusInvalid'),
      'reasserting' => context.l10n.get('tunStatusReasserting'),
      'not_configured' => context.l10n.get('tunStatusNotConfigured'),
      'unsupported' => context.l10n.get('tunStatusUnsupported'),
      _ => context.l10n.get('tunStatusUnknown'),
    };
  }

  Future<void> _openHelpPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HelpScreen(
          breadcrumbItems: [
            context.l10n.get('settings'),
            context.l10n.get('help'),
          ],
        ),
      ),
    );
  }

  Future<void> _openAboutPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AboutScreen(
          breadcrumbItems: [
            context.l10n.get('settings'),
            context.l10n.get('about'),
          ],
        ),
      ),
    );
  }

  Future<void> _openLogsPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LogsScreen(
          breadcrumbItems: [
            context.l10n.get('settings'),
            context.l10n.get('logs'),
          ],
        ),
      ),
    );
  }

  Future<void> _onSyncConfig() async {
    addAppLog('开始同步区域节点...');
    final result = await DesktopSyncService.instance.syncNow(manual: true);
    addAppLog(result.message,
        level: result.success ? LogLevel.info : LogLevel.error);
  }

  Future<void> _prepareImportedNodeForIos(String nodeName) async {
    if (!Platform.isIOS) return;
    final targetName = nodeName.trim();
    if (targetName.isEmpty) return;
    addAppLog(await NativeBridge.prepareNodeForTunnel(targetName));
  }

  Future<void> _onImportConfig() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.get('importConfig')),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '/path/to/backup.zip 或 vless://...',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.get('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(context.l10n.get('confirm')),
            ),
          ],
        );
      },
    );
    var importText = input?.trim() ?? '';
    if (importText.isEmpty) {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      importText = clipboard?.text?.trim() ?? '';
    }
    if (importText.isEmpty) return;
    final normalizedInput = importText
        .trim()
        .replaceFirst(RegExp(r'^file:///', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^vless\\://', caseSensitive: false), 'vless://')
        .replaceAll('"', '');
    if (normalizedInput.isEmpty) return;

    addAppLog('开始导入配置...');
    try {
      if (normalizedInput.startsWith('vless://')) {
        final bundleId = await GlobalApplicationConfig.getBundleId();
        final profile = VpnConfig.parseVlessUri(normalizedInput);
        final saved = await VpnConfig.generateFromVlessUri(
          vlessUri: normalizedInput,
          password: '',
          bundleId: bundleId,
          setMessage: (msg) => addAppLog(msg),
          logMessage: (msg) => addAppLog(msg),
        );
        if (!saved) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.get('configSaveFailed'))),
            );
          }
          return;
        }
        await VpnConfig.load();
        GlobalState.activeNodeName.value = '';
        GlobalState.lastImportedNodeName.value = profile.name;
        GlobalState.nodeListRevision.value++;
        addAppLog('✅ 已从 VLESS 链接导入配置');
        await _prepareImportedNodeForIos(profile.name);
        return;
      }

      final existingNames = VpnConfig.nodes.map((e) => e.name).toSet();
      final file = File(normalizedInput);
      if (!await file.exists()) {
        addAppLog('备份文件不存在', level: LogLevel.error);
        return;
      }
      final bytes = await file.readAsBytes();
      if (normalizedInput.toLowerCase().endsWith('.json')) {
        await VpnConfig.importFromJson(utf8.decode(bytes));
        await VpnConfig.load();
        GlobalState.activeNodeName.value = '';
        GlobalState.nodeListRevision.value++;
        addAppLog('Config JSON imported successfully');
        return;
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        final name = entry.name;
        String dest;
        if (name == 'vpn_nodes.json') {
          dest = await VpnConfig.getConfigPath();
        } else if (name.endsWith('.json')) {
          final prefix = await GlobalApplicationConfig.getXrayConfigPath();
          dest = '$prefix$name';
        } else if (name.endsWith('.plist') ||
            name.endsWith('.service') ||
            name.endsWith('.schtasks')) {
          dest = await GlobalApplicationConfig.getServicePath(name);
        } else {
          continue;
        }
        final out = File(dest);
        await out.create(recursive: true);
        await out.writeAsBytes(entry.content as List<int>);
      }
      await VpnConfig.load();
      GlobalState.activeNodeName.value = '';
      final imported = VpnConfig.nodes.map((e) => e.name).firstWhere(
        (name) => !existingNames.contains(name),
        orElse: () {
          return VpnConfig.nodes.isNotEmpty ? VpnConfig.nodes.first.name : '';
        },
      );
      GlobalState.lastImportedNodeName.value = imported;
      GlobalState.nodeListRevision.value++;
      await _prepareImportedNodeForIos(imported);
      addAppLog('✅ 已导入配置');
    } catch (e) {
      addAppLog('[错误] 导入失败: $e', level: LogLevel.error);
    }
  }

  Future<void> _onExportConfig() async {
    addAppLog('开始导出配置...');
    try {
      final configPath = await VpnConfig.getConfigPath();
      final dir = File(configPath).parent.path;
      final backupPath =
          '$dir/vpn_backup_${DateTime.now().millisecondsSinceEpoch}.zip';

      final encoder = ZipFileEncoder();
      encoder.create(backupPath);
      encoder.addFile(File(configPath), 'vpn_nodes.json');
      for (final node in VpnConfig.nodes) {
        final cfg = File(node.configPath);
        if (await cfg.exists()) {
          encoder.addFile(cfg, cfg.uri.pathSegments.last);
        }
        final servicePath = await GlobalApplicationConfig.getServicePath(
          node.serviceName,
        );
        final svc = File(servicePath);
        if (await svc.exists()) {
          encoder.addFile(svc, svc.uri.pathSegments.last);
        }
      }
      encoder.close();
      addAppLog('✅ 配置已导出: $backupPath');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出到: $backupPath')));
    } catch (e) {
      addAppLog('[错误] 导出失败: $e', level: LogLevel.error);
    }
  }

  Future<void> _onDeleteConfig() async {
    await VpnConfig.load();
    final nodes = List<VpnNode>.from(VpnConfig.nodes);
    if (nodes.isEmpty) {
      addAppLog('暂无可删除节点', level: LogLevel.warning);
      return;
    }
    if (!mounted) return;

    final selected = <String>{};
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text(context.l10n.get('deleteConfig')),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: nodes
                        .map(
                          (node) => CheckboxListTile(
                            value: selected.contains(node.name),
                            title: Text(node.name),
                            subtitle: Text(
                              '${node.countryCode.toUpperCase()} · ${context.l10n.get(node.isManaged ? 'nodeSourceManaged' : 'nodeSourceImported')}',
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (checked) {
                              setStateDialog(() {
                                if (checked == true) {
                                  selected.add(node.name);
                                } else {
                                  selected.remove(node.name);
                                }
                              });
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l10n.get('cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(context.l10n.get('confirm')),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldDelete != true || selected.isEmpty) {
      addAppLog('未选择要删除的节点', level: LogLevel.warning);
      return;
    }

    try {
      var count = 0;
      for (final name in selected) {
        final node = nodes.firstWhere((n) => n.name == name);
        await VpnConfig.deleteNodeFiles(node);
        count++;
      }
      await VpnConfig.load();
      if (selected.contains(GlobalState.activeNodeName.value)) {
        GlobalState.activeNodeName.value = '';
      }
      GlobalState.nodeListRevision.value++;
      addAppLog('✅ 已删除 $count 个节点并更新配置');
    } catch (e) {
      addAppLog('[错误] 删除失败: $e', level: LogLevel.error);
    }
  }

  void _onResetAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.get('resetAllConfirmTitle')),
        content: Text(context.l10n.get('resetAllConfirmBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.get('cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            // The verb, not "confirm" — the button should say what it does.
            child: Text(context.l10n.get('reset')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    addAppLog('开始重置配置与文件...');
    try {
      final result = await NativeBridge.resetXrayAndConfig('');
      addAppLog(result);
    } catch (e) {
      addAppLog('[错误] 重置失败: $e', level: LogLevel.error);
    }
  }

  void _onToggleDnsOverHttps(bool enabled) {
    setState(() => DnsConfig.setDohEnabled(enabled));
    addAppLog('代理 DNS / DoH: ${enabled ? "开启" : "关闭"}');
    if (GlobalState.tunSettingsEnabled.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.get('dnsReconnectHint'))),
      );
    }
  }

  Future<void> _refreshTunStatus() async {
    final status = await NativeBridge.getPacketTunnelStatus();
    if (!mounted) return;
    final connected =
        status.status == 'connected' || status.status == 'connecting';
    setState(() {
      _tunStatus = status;
      GlobalState.tunSettingsEnabled.value = connected;
    });
  }

  Future<void> _toggleRuntimeMcp(bool enabled) async {
    final ok = enabled
        ? await _runtimeMcpService.start()
        : await _runtimeMcpService.stop();
    if (!mounted) return;
    final msg = ok
        ? (enabled
            ? context.l10n.get('runtimeMcpStarted')
            : context.l10n.get('runtimeMcpStopped'))
        : (_runtimeMcpService.lastError.value ??
            context.l10n.get('runtimeMcpToggleFailed'));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Shows the values in effect, including control-plane tuning, so the user
  /// can explicitly pick a local default over a tuned value.
  void _loadXhttpAdvancedDraft() {
    _loadedXhttpMode = VpnConfig.effectiveXhttpMode();
    _loadedXhttpXmuxMaxConcurrency = VpnConfig.effectiveXmuxMaxConcurrency();
    _draftXhttpMode = _loadedXhttpMode;
    _draftXhttpAlpn = <String>{...XhttpAdvancedConfig.alpn.value};
    _draftXhttpXmuxMaxConcurrency = _loadedXhttpXmuxMaxConcurrency;
    _xhttpXmuxMaxConcurrencyController.text = _draftXhttpXmuxMaxConcurrency;
    _xhttpAdvancedDirty = false;
  }

  void _setDraftXhttpXmuxMaxConcurrency(String value) {
    if (_draftXhttpXmuxMaxConcurrency == value) return;
    setState(() {
      _draftXhttpXmuxMaxConcurrency = value;
      _xhttpAdvancedDirty = true;
    });
  }

  void _setDraftXhttpMode(String value) {
    if (_draftXhttpMode == value) return;
    setState(() {
      _draftXhttpMode = value;
      _xhttpAdvancedDirty = true;
    });
  }

  void _toggleDraftXhttpAlpn(String value, bool enabled) {
    final next = <String>{..._draftXhttpAlpn};
    if (enabled) {
      next.add(value);
    } else {
      next.remove(value);
    }
    final changed = next.length != _draftXhttpAlpn.length ||
        next.any((item) => !_draftXhttpAlpn.contains(item));
    if (!changed) return;
    setState(() {
      _draftXhttpAlpn = next;
      _xhttpAdvancedDirty = true;
    });
  }

  void _resetXhttpAdvancedDraft() {
    setState(() {
      _loadXhttpAdvancedDraft();
    });
  }

  Future<void> _saveAndApplyXhttpAdvanced() async {
    final orderedAlpn = <String>[
      for (final candidate in XhttpAdvancedConfig.allowedAlpn)
        if (_draftXhttpAlpn.contains(candidate)) candidate,
    ];
    if (_draftXhttpMode != _loadedXhttpMode) {
      XhttpAdvancedConfig.setMode(_draftXhttpMode);
    }
    XhttpAdvancedConfig.setAlpn(orderedAlpn);
    if (_draftXhttpXmuxMaxConcurrency != _loadedXhttpXmuxMaxConcurrency) {
      XhttpAdvancedConfig.setXmuxMaxConcurrency(
        _draftXhttpXmuxMaxConcurrency,
      );
    }
    _loadedXhttpMode = VpnConfig.effectiveXhttpMode();
    _loadedXhttpXmuxMaxConcurrency = VpnConfig.effectiveXmuxMaxConcurrency();
    _draftXhttpMode = _loadedXhttpMode;
    _draftXhttpXmuxMaxConcurrency = _loadedXhttpXmuxMaxConcurrency;
    _xhttpXmuxMaxConcurrencyController.text = _draftXhttpXmuxMaxConcurrency;

    final activeNodeName = GlobalState.activeNodeName.value.trim();
    var reconnectRequired = false;
    String? applyError;
    if (activeNodeName.isNotEmpty) {
      try {
        final result = await VpnConfig.applyXhttpAdvancedSettingsToNode(
          activeNodeName,
        );
        reconnectRequired = result.foundXhttp && result.changed;
      } catch (error) {
        applyError = error.toString();
        addAppLog(
          'Failed to update active XHTTP node config: $error',
          level: LogLevel.error,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _xhttpAdvancedDirty = false;
    });
    addAppLog(
      'XHTTP advanced config saved: '
      'mode=${XhttpAdvancedConfig.mode.value}, '
      'alpn=${XhttpAdvancedConfig.alpn.value.join(",")}, '
      'xmux.maxConcurrency=${XhttpAdvancedConfig.xmuxMaxConcurrency.value}',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          applyError == null
              ? context.l10n.get('xhttpSavedApplied')
              : '${context.l10n.get('xhttpApplyFailed')}: $applyError',
        ),
      ),
    );
    if (reconnectRequired) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.get('xhttpReconnectTitle')),
          content: Text(
            context.l10n
                .get('xhttpReconnectHint')
                .replaceAll('{node}', activeNodeName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.get('confirm')),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildXhttpAdvancedConfig(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: context.xColors.cardBackground,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.get('xhttpAdvancedTitle'),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              // This card is the one place on the page that does not apply
              // immediately, so the pending state has to be visible.
              if (_xhttpAdvancedDirty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.xColors.warningBannerBackground,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border:
                        Border.all(color: context.xColors.warningBannerBorder),
                  ),
                  child: Text(
                    context.l10n.get('unsavedChanges'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: context.xColors.warningBannerText,
                        ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            context.l10n.get('xhttpAdvancedHint'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.get('xhttpModeLabel'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                ),
              ),
              DropdownButton<String>(
                value: _draftXhttpMode,
                items: [
                  DropdownMenuItem(
                    value: XhttpAdvancedConfig.modeStreamUp,
                    child: Text(context.l10n.get('xhttpModeStreamUp')),
                  ),
                  DropdownMenuItem(
                    value: XhttpAdvancedConfig.modeAuto,
                    child: Text(context.l10n.get('xhttpModeAuto')),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  _setDraftXhttpMode(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.get('xhttpAlpnLabel'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: Text(context.l10n.get('xhttpAlpnH3')),
                selected: _draftXhttpAlpn.contains(XhttpAdvancedConfig.alpnH3),
                onSelected: (enabled) =>
                    _toggleDraftXhttpAlpn(XhttpAdvancedConfig.alpnH3, enabled),
              ),
              FilterChip(
                label: Text(context.l10n.get('xhttpAlpnH2')),
                selected: _draftXhttpAlpn.contains(XhttpAdvancedConfig.alpnH2),
                onSelected: (enabled) =>
                    _toggleDraftXhttpAlpn(XhttpAdvancedConfig.alpnH2, enabled),
              ),
              FilterChip(
                label: Text(context.l10n.get('xhttpAlpnHttp11')),
                selected: _draftXhttpAlpn.contains(
                  XhttpAdvancedConfig.alpnHttp11,
                ),
                onSelected: (enabled) => _toggleDraftXhttpAlpn(
                  XhttpAdvancedConfig.alpnHttp11,
                  enabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _xhttpXmuxMaxConcurrencyController,
            keyboardType: TextInputType.text,
            onChanged: _setDraftXhttpXmuxMaxConcurrency,
            decoration: InputDecoration(
              labelText: context.l10n.get('xhttpXmuxMaxConcurrencyLabel'),
              hintText: context.l10n.get('xhttpXmuxMaxConcurrencyHint'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed:
                    _xhttpAdvancedDirty ? _resetXhttpAdvancedDraft : null,
                child: Text(context.l10n.get('xhttpResetDraft')),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed:
                    _xhttpAdvancedDirty ? _saveAndApplyXhttpAdvanced : null,
                icon: const Icon(Icons.save),
                label: Text(context.l10n.get('xhttpSaveApply')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Settings read as a list, not a form, so the column is capped rather than
  /// stretched to the window width.
  ///
  /// Wider than a prose measure would allow: these rows are label/value pairs,
  /// not running text, and 720 left a maximised window looking mostly empty.
  static const double _maxContentWidth = 900;

  /// Spacing between groups inside one tab.
  static const double _groupGap = 24;

  /// One entry per tab: its chrome, and the blocks it owns.
  ///
  /// A tab whose blocks are all empty on this platform is dropped along with
  /// its chip, so no tab can be opened onto a blank page.
  List<({SettingsTabId id, SettingsTab tab, List<Widget> blocks})>
      _settingsTabs(
    BuildContext context, {
    required bool isMobile,
  }) {
    final candidates =
        <({SettingsTabId id, SettingsTab tab, List<Widget> blocks})>[
      (
        id: SettingsTabId.connection,
        tab: SettingsTab(
          icon: Icons.vpn_key_outlined,
          label: context.l10n.get('settingsTabConnection'),
        ),
        blocks: [
          _connectionGroup(context, isMobile: isMobile),
          _proxyPortsCard(context, isMobile: isMobile),
        ],
      ),
      (
        id: SettingsTabId.dns,
        tab: SettingsTab(
          icon: Icons.dns_outlined,
          label: context.l10n.get('settingsTabDns'),
        ),
        blocks: [
          _dnsGroup(context),
          if (!Platform.isIOS) _desktopTunnelDnsGroup(context),
        ],
      ),
      (
        id: SettingsTabId.routing,
        tab: SettingsTab(
          icon: Icons.alt_route,
          label: context.l10n.get('settingsTabRouting'),
        ),
        blocks: [
          if (Platform.isMacOS ||
              Platform.isIOS ||
              Platform.isAndroid ||
              Platform.isWindows ||
              Platform.isLinux)
            const TrafficModeGroup(),
          _routingGroup(context, isMobile: isMobile),
        ],
      ),
      (
        id: SettingsTabId.transport,
        tab: SettingsTab(
          icon: Icons.swap_vert,
          label: context.l10n.get('settingsTabTransport'),
        ),
        blocks: [_buildXhttpAdvancedConfig(context)],
      ),
      (
        id: SettingsTabId.notifications,
        tab: SettingsTab(
          icon: Icons.notifications_outlined,
          label: context.l10n.get('notifications'),
        ),
        blocks: [const QuotaNotificationPanel()],
      ),
      (
        id: SettingsTabId.system,
        tab: SettingsTab(
          icon: Icons.tune,
          label: context.l10n.get('settingsTabSystem'),
        ),
        blocks: [
          _configGroup(context, isMobile: isMobile),
          _dangerZoneGroup(context),
          _systemGroup(context),
          _developerGroup(context, isMobile: isMobile),
          _navigationGroup(context, isMobile: isMobile),
          LiveDiagnosisSection(
            onHowToFix: () => GlobalState.settingsTabRequest.value =
                const SettingsTabRequest(id: SettingsTabId.system),
          ),
          const BrowserPrivacySection(),
          const RepairSection(),
        ],
      ),
    ];

    bool renders(Widget block) {
      if (block is SizedBox) return false;
      // A group can also be empty from the inside out, when every row it was
      // given is absent on this platform.
      if (block is SettingsGroup) return !block.isEmpty;
      return true;
    }

    return candidates
        .map((entry) => (
              id: entry.id,
              tab: entry.tab,
              blocks: entry.blocks.where(renders).toList(),
            ))
        .where((entry) => entry.blocks.isNotEmpty)
        .toList();
  }

  Widget _buildSettingsView(BuildContext context, {required bool isMobile}) {
    final cs = Theme.of(context).colorScheme;
    final entries = _settingsTabs(context, isMobile: isMobile);

    final pendingRequest = GlobalState.settingsTabRequest.value;
    if (pendingRequest != null) {
      final resolved = resolveSettingsTabIndex(
        entries.map((entry) => entry.id).toList(),
        pendingRequest.id,
      );
      // Filtered out on this platform: leave the current selection alone
      // rather than silently landing on tab 0.
      if (resolved != null) {
        _selectedTab = resolved;
      }
      // Cleared after this frame, not inline: mutating the notifier here
      // would re-enter build via its own listener.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (GlobalState.settingsTabRequest.value == pendingRequest) {
          GlobalState.settingsTabRequest.value = null;
        }
      });
    }

    final index = _selectedTab.clamp(0, entries.length - 1);
    final blocks = entries[index].blocks;

    return Container(
      color: cs.surface,
      // Anchored left rather than centred: the breadcrumb and the navigation
      // rail are both hard against the left edge, so centring the column left
      // the title floating in the middle of a maximised window with nothing
      // lining up with it.
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The header and tab strip stay put; only the panel scrolls, so
              // switching tabs never leaves you deep in a scrolled page.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.get('settingsCenter'),
                      style: TextStyle(
                        fontSize: isMobile ? 24 : 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.get('settingsSubtitle'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    SettingsTabBar(
                      tabs: entries.map((e) => e.tab).toList(),
                      selectedIndex: index,
                      onSelected: (i) => setState(() => _selectedTab = i),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  key: PageStorageKey<int>(index),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < blocks.length; i++) ...[
                        if (i > 0) const SizedBox(height: _groupGap),
                        blocks[i],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Routing toggles. Mobile only today — desktop exposes these through the
  /// node editor instead.
  Widget _routingGroup(BuildContext context, {required bool isMobile}) {
    if (!isMobile) return const SizedBox.shrink();

    Widget toggle({
      required ValueNotifier<bool> notifier,
      required IconData icon,
      required String titleKey,
      required String hintKey,
      required String logLabel,
    }) {
      return ValueListenableBuilder<bool>(
        valueListenable: notifier,
        builder: (context, enabled, _) {
          return SettingsRow(
            icon: icon,
            kind: SettingsRowKind.toggle,
            title: context.l10n.get(titleKey),
            description: context.l10n.get(hintKey),
            switchValue: enabled,
            onSwitchChanged: (value) {
              setState(() => notifier.value = value);
              addAppLog('$logLabel: ${value ? "开启" : "关闭"}');
            },
          );
        },
      );
    }

    return SettingsGroup(
      children: [
        toggle(
          notifier: GlobalState.sniffingEnabled,
          icon: Icons.travel_explore,
          titleKey: 'sniffing',
          hintKey: 'sniffingHint',
          logLabel: '嗅探',
        ),
        toggle(
          notifier: GlobalState.http3Passthrough,
          icon: Icons.bolt,
          titleKey: 'http3Passthrough',
          hintKey: 'http3PassthroughHint',
          logLabel: 'HTTP/3 passthrough',
        ),
        toggle(
          notifier: GlobalState.fallbackToProxy,
          icon: Icons.alt_route,
          titleKey: 'fallbackProxy',
          hintKey: 'fallbackProxyHint',
          logLabel: '回退到代理',
        ),
        toggle(
          notifier: GlobalState.fallbackToDomain,
          icon: Icons.language,
          titleKey: 'fallbackDomain',
          hintKey: 'fallbackDomainHint',
          logLabel: '回退到域名',
        ),
        toggle(
          notifier: GlobalState.ipv6ToDomain,
          icon: Icons.swap_horiz,
          titleKey: 'ipv6ToDomain',
          hintKey: 'ipv6ToDomainHint',
          logLabel: 'IPv6 to Domain',
        ),
      ],
    );
  }

  /// Local proxy ports. Mobile only today.
  Widget _proxyPortsCard(BuildContext context, {required bool isMobile}) {
    if (!isMobile) return const SizedBox.shrink();
    final xc = context.xColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            context.l10n.get('proxySettings').toUpperCase(),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(letterSpacing: 1.1),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: xc.cardBackground,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _socksPortController,
                  decoration: InputDecoration(
                    labelText: context.l10n.get('socksPort'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => GlobalState.socksPort.value = v,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _httpPortController,
                  decoration: InputDecoration(
                    labelText: context.l10n.get('httpPort'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => GlobalState.httpPort.value = v,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _configGroup(BuildContext context, {required bool isMobile}) {
    return SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.sync,
          kind: SettingsRowKind.action,
          title: context.l10n.get('syncConfig'),
          onTap: _onSyncConfig,
        ),
        SettingsRow(
          icon: Icons.upload_file,
          title: context.l10n.get('importConfig'),
          onTap: _onImportConfig,
        ),
        SettingsRow(
          icon: Icons.download,
          title: context.l10n.get('exportConfig'),
          onTap: _onExportConfig,
        ),
      ],
    );
  }

  /// Irreversible actions, kept in their own group at the end of the tab so
  /// they never sit in the same rhythm as everyday ones.
  Widget _dangerZoneGroup(BuildContext context) {
    return SettingsGroup(
      title: context.l10n.get('dangerZone'),
      children: [
        SettingsRow(
          icon: Icons.delete_forever,
          title: context.l10n.get('deleteConfig'),
          description: context.l10n.get('deleteConfigMeaning'),
          destructive: true,
          onTap: _onDeleteConfig,
        ),
        SettingsRow(
          icon: Icons.restore,
          title: context.l10n.get('resetAll'),
          description: context.l10n.get('resetAllMeaning'),
          destructive: true,
          onTap: _onResetAll,
        ),
      ],
    );
  }

  Widget _dnsGroup(BuildContext context) {
    return SettingsGroup(
      children: [
        // Listen rather than read once: confirming the dialog updates the
        // notifier without rebuilding this screen, so a plain read leaves the
        // row showing the previous resolver.
        ValueListenableBuilder<String>(
          valueListenable: DnsConfig.directDns1,
          builder: (context, directDns, _) => SettingsRow(
            icon: Icons.dns_outlined,
            title: context.l10n.get('directDnsConfig'),
            value: directDns,
            onTap: _showDirectDnsDialog,
          ),
        ),
        SettingsRow(
          icon: Icons.vpn_lock,
          kind: SettingsRowKind.toggle,
          title: context.l10n.get('dnsOverHttps'),
          description: context.l10n.get('dnsOverHttpsHint'),
          switchValue: DnsConfig.dohEnabled,
          onSwitchChanged: _onToggleDnsOverHttps,
        ),
      ],
    );
  }

  /// Desktop keeps its established tunnel-DNS routing control. iOS omits it
  /// because its DNS bootstrap policy is fixed and fail-closed.
  Widget _desktopTunnelDnsGroup(BuildContext context) {
    return SettingsGroup(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: DnsConfig.tunnelDnsViaProxy,
          builder: (context, viaProxy, _) => SettingsRow(
            icon: Icons.alt_route,
            kind: SettingsRowKind.toggle,
            title: context.l10n.get('tunnelDnsViaProxy'),
            description: context.l10n.get('tunnelDnsViaProxyHint'),
            switchValue: viaProxy,
            onSwitchChanged: (value) {
              DnsConfig.tunnelDnsViaProxy.value = value;
              addAppLog('隧道 DNS 走代理: ${value ? "开启" : "关闭"}');
            },
          ),
        ),
      ],
    );
  }

  Widget _connectionGroup(BuildContext context, {required bool isMobile}) {
    final localProxyRows = <Widget>[
      // Desktop-only today.
      if (!isMobile)
        ValueListenableBuilder<bool>(
          valueListenable: GlobalState.socksProxyEnabled,
          builder: (context, enabled, _) {
            return SettingsRow(
              icon: Icons.swap_calls,
              kind: SettingsRowKind.toggle,
              title: 'SOCKS 代理',
              description: '启用 SOCKS 代理服务 (127.0.0.1:1080)',
              switchValue: enabled,
              onSwitchChanged: (value) {
                setState(() => GlobalState.socksProxyEnabled.value = value);
                addAppLog('SOCKS 代理: ${value ? "开启" : "关闭"}');
              },
            );
          },
        )
      else
        SettingsRow.absent(),
      if (!isMobile)
        ValueListenableBuilder<bool>(
          valueListenable: GlobalState.httpProxyEnabled,
          builder: (context, enabled, _) {
            return SettingsRow(
              icon: Icons.http,
              kind: SettingsRowKind.toggle,
              title: 'HTTP 代理',
              description: '启用 HTTP 代理服务 (127.0.0.1:1081)',
              switchValue: enabled,
              onSwitchChanged: (value) {
                setState(() => GlobalState.httpProxyEnabled.value = value);
                addAppLog('HTTP 代理: ${value ? "开启" : "关闭"}');
              },
            );
          },
        )
      else
        SettingsRow.absent(),
    ];

    final Widget tunnelRow;
    if (Platform.isIOS) {
      tunnelRow = const SettingsRow(
        icon: Icons.vpn_lock,
        kind: SettingsRowKind.action,
        title: 'Packet Tunnel',
        description: 'iOS 默认使用系统级 Packet Tunnel',
      );
    } else {
      tunnelRow = ValueListenableBuilder<bool>(
        valueListenable: GlobalState.tunnelProxyEnabled,
        builder: (context, enabled, _) {
          return SettingsRow(
            icon: Icons.vpn_key,
            kind: SettingsRowKind.toggle,
            title: '隧道模式',
            description: _tunnelRowDescription(context),
            switchValue: enabled,
            onSwitchChanged: (value) {
              setState(() => GlobalState.setTunnelModeEnabled(value));
              addAppLog('系统级网络隧道: ${value ? "开启" : "关闭"}');
              _refreshTunStatus();
            },
          );
        },
      );
    }

    return SettingsGroup(children: [...localProxyRows, tunnelRow]);
  }

  String _tunnelRowDescription(BuildContext context) {
    if (_tunStatus.status == 'connected') {
      return context.l10n.get('tunnelActive');
    }
    if (_tunStatus.status == 'unknown') {
      return '启用系统级网络隧道';
    }
    return '${context.l10n.get('tunStatus')}: '
        '${_tunStatusLabel(context, _tunStatus)}';
  }

  Widget _developerGroup(BuildContext context, {required bool isMobile}) {
    final rows = <Widget>[
      if (_desktopCapabilities.supportsRuntimeMcp)
        ValueListenableBuilder<bool>(
          valueListenable: _runtimeMcpService.available,
          builder: (context, available, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _runtimeMcpService.running,
              builder: (context, running, __) {
                return ValueListenableBuilder<bool>(
                  valueListenable: _runtimeMcpService.loading,
                  builder: (context, loading, ___) {
                    final status = available
                        ? (running
                            ? context.l10n.get('runtimeMcpStatusRunning')
                            : context.l10n.get('runtimeMcpStatusStopped'))
                        : context.l10n.get('runtimeMcpStatusUnavailable');
                    return SettingsRow(
                      icon: Icons.terminal,
                      kind: SettingsRowKind.toggle,
                      title: context.l10n.get('runtimeMcpServer'),
                      description: loading
                          ? context.l10n.get('runtimeMcpStatusLoading')
                          : status,
                      switchValue: running,
                      onSwitchChanged:
                          available && !loading ? _toggleRuntimeMcp : null,
                    );
                  },
                );
              },
            );
          },
        )
      else
        SettingsRow.absent(),
      // Desktop-only today.
      if (!isMobile)
        SettingsRow(
          icon: Icons.stacked_line_chart,
          title: context.l10n.get('viewCollected'),
          onTap: _showTelemetryData,
          trailing: Switch(
            value: GlobalState.telemetryEnabled.value,
            onChanged: (v) {
              setState(() => GlobalState.telemetryEnabled.value = v);
              addAppLog('Telemetry: ${v ? "开启" : "关闭"}');
            },
          ),
        )
      else
        SettingsRow.absent(),
    ];

    return SettingsGroup(children: rows);
  }

  /// Logs / help / about. Mobile only — on desktop these are navigation rail
  /// destinations, so repeating them here would be a second entrance.
  Widget _navigationGroup(BuildContext context, {required bool isMobile}) {
    if (!isMobile) return const SizedBox.shrink();

    return SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.article_outlined,
          title: context.l10n.get('logs'),
          onTap: _openLogsPage,
        ),
        SettingsRow(
          icon: Icons.help_outline,
          title: context.l10n.get('help'),
          onTap: _openHelpPage,
        ),
        SettingsRow(
          icon: Icons.info_outline,
          title: context.l10n.get('about'),
          onTap: _openAboutPage,
        ),
      ],
    );
  }

  Widget _systemGroup(BuildContext context) {
    return SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.security,
          title: context.l10n.get('permissionGuide'),
          onTap: _showPermissionGuide,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _buildSettingsView(
          context,
          isMobile: constraints.maxWidth < 900,
        );
      },
    );
  }

  @override
  void dispose() {
    _sessionManager.baseUrl.removeListener(_syncBaseUrlFromSession);
    _sessionManager.currentUser.removeListener(_syncUsernameFromSession);
    GlobalState.settingsTabRequest.removeListener(_onSettingsTabRequested);
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _mfaCodeController.dispose();
    _xhttpXmuxMaxConcurrencyController.dispose();
    _socksPortController.dispose();
    _httpPortController.dispose();
    super.dispose();
  }

  void _showDirectDnsDialog() {
    final dns1Controller = TextEditingController(
      text: DnsConfig.directDns1.value,
    );
    final dns2Controller = TextEditingController(
      text: DnsConfig.directDns2.value,
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.get('directDnsConfig')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Chips fill the primary field only, so the secondary stays a
              // deliberate choice. They rebuild on every edit — a controller
              // change does not rebuild the dialog by itself, which used to
              // freeze the highlight on whatever was selected when it opened.
              AnimatedBuilder(
                animation: dns1Controller,
                builder: (context, _) {
                  final primary = dns1Controller.text.trim();
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: DnsConfig.dnsPresets.map((preset) {
                      final isSelected = primary == preset.plainHost;
                      return ActionChip(
                        label: Text(preset.label),
                        backgroundColor: isSelected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        // Direct resolvers are always plain — the DoH toggle
                        // only governs the built-in proxy resolvers.
                        onPressed: () => dns1Controller.text = preset.plainHost,
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.l10n.get('dnsDialogHintDirect'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dns1Controller,
                decoration: InputDecoration(
                  labelText: context.l10n.get('primaryDns'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: dns2Controller,
                decoration: InputDecoration(
                  labelText: context.l10n.get('secondaryDns'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.get('cancel')),
          ),
          TextButton(
            onPressed: () {
              DnsConfig.updateDirectServers(
                primary: dns1Controller.text,
                secondary: dns2Controller.text,
              );
              Navigator.pop(context);
            },
            child: Text(context.l10n.get('confirm')),
          ),
        ],
      ),
    ).whenComplete(() {
      dns1Controller.dispose();
      dns2Controller.dispose();
    });
  }

  void _showTelemetryData() {
    final data = TelemetryService.collectData(
      appVersion: AppVersionService.shortLabel,
    );
    final json = const JsonEncoder.withIndent('  ').convert(data);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.get('collectedData')),
        content: SingleChildScrollView(child: SelectableText(json)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.get('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _showPermissionGuide() async {
    await showPermissionGuideDialog(context);
  }
}
