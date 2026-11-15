import 'dart:async';
import 'package:flutter/material.dart';
import '../services/account_usage_service.dart';
import 'package:flutter/services.dart';
import '../services/session/session_manager.dart';
import '../services/session/network_access_policy.dart';
import '../services/sync/desktop_sync_service.dart';
import '../services/sync/sync_state.dart';
import '../l10n/app_localizations.dart';
import '../utils/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usageService = AccountUsageService();
  Future<(AccountUsageSummary, int)>? _usage;
  Timer? _usageTimer;
  bool _reauthenticating = false;

  final SessionManager _sessionManager = SessionManager.instance;
  final DesktopSyncService _syncService = DesktopSyncService.instance;
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _mfaCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _baseUrlController.text = _sessionManager.baseUrl.value;
    _usernameController.text = _sessionManager.currentUser.value ?? '';
    _sessionManager.status.addListener(_refreshUsage);
    _syncService.syncing.addListener(_onSyncChanged);
    _refreshUsage();
    _usageTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _refreshUsage());
  }

  @override
  void dispose() {
    _usageTimer?.cancel();
    _sessionManager.status.removeListener(_refreshUsage);
    _syncService.syncing.removeListener(_onSyncChanged);
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _mfaCodeController.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    if (!_syncService.syncing.value) _refreshUsage();
  }

  Future<(AccountUsageSummary, int)> _loadUsage() async {
    final baseUrl = _sessionManager.baseUrl.value;
    final token = _sessionManager.sessionToken ?? '';
    final cookie = _sessionManager.cookie;
    final values = await Future.wait<Object>([
      _usageService.fetchUsageSummary(
          baseUrl: baseUrl, sessionToken: token, cookie: cookie),
      _usageService.fetchMonthUsage(
          baseUrl: baseUrl, sessionToken: token, cookie: cookie),
    ]);
    return (values[0] as AccountUsageSummary, values[1] as int);
  }

  void _refreshUsage() {
    if (!mounted) return;
    setState(() {
      _usage = _sessionManager.isLoggedIn ? _loadUsage() : null;
    });
  }

  String _formatBytes(int value) {
    var amount = value.toDouble();
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var unit = 0;
    while (amount >= 1024 && unit < units.length - 1) {
      amount /= 1024;
      unit++;
    }
    return '${amount.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
  }

  Widget _buildUsageCard(BuildContext context) {
    final xc = context.xColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: xc.cardBackground,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: xc.cardBorder),
      ),
      child: FutureBuilder<(AccountUsageSummary, int)>(
        future: _usage,
        builder: (context, snapshot) {
          final usage = snapshot.data;
          final String value;
          if (snapshot.connectionState != ConnectionState.done) {
            value = context.l10n.get('usageLoading');
          } else if (snapshot.hasError || usage == null) {
            value = context.l10n.get('usageUnavailable');
          } else {
            final used = usage.$2;
            final quota = usage.$1.includedQuotaBytes;
            value = '${_formatBytes(used)} / '
                '${quota == null ? '—' : _formatBytes(quota)}';
          }
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.get('usageMonthly'),
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(value, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(context.l10n.get('usageServerSource'),
                    style: Theme.of(context).textTheme.bodySmall),
              ]);
        },
      ),
    );
  }

  Future<void> _handleLogin() async {
    final isMfaRequired = _sessionManager.isMfaRequired;
    if (isMfaRequired) {
      final result =
          await _sessionManager.verifyMfaCode(_mfaCodeController.text);
      if (mounted) {
        _finishReauthentication(result);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.message)));
      }
    } else {
      await _sessionManager.setBaseUrl(_baseUrlController.text);
      final result = await _sessionManager.login(
        identifier: _usernameController.text,
        password: _passwordController.text,
      );
      if (mounted) {
        _finishReauthentication(result);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.message)));
      }
    }
  }

  void _finishReauthentication(LoginResult result) {
    if (!result.success) return;
    _passwordController.clear();
    _mfaCodeController.clear();
    if (_reauthenticating) setState(() => _reauthenticating = false);
  }

  void _reauthenticate() {
    _baseUrlController.text = _sessionManager.baseUrl.value;
    _usernameController.text = _sessionManager.currentUser.value ?? '';
    _passwordController.clear();
    setState(() => _reauthenticating = true);
  }

  Future<void> _handleLogout() async {
    await _sessionManager.logout();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.get('logoutSuccess'))),
      );
    }
  }

  Future<void> _handleSyncNow() async {
    final result = await _syncService.syncNow(manual: true);
    if (!mounted ||
        result.message == DesktopSyncService.sessionExpiredMessage) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.get(result.message))),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}:${_pad(local.second)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SessionStatus>(
      valueListenable: _sessionManager.status,
      builder: (context, status, _) {
        final isLoggedIn = status == SessionStatus.loggedIn;
        final isMfaRequired = status == SessionStatus.mfaRequired;

        if (isLoggedIn && !_reauthenticating) {
          return _buildLoggedInView(context);
        }
        return _buildLoginForm(context, isMfaRequired);
      },
    );
  }

  Widget _buildLoggedInView(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 32),
              Icon(Icons.account_circle, size: 80, color: xc.brand),
              const SizedBox(height: 16),
              Text(
                _sessionManager.currentUser.value ?? '',
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(color: cs.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                _sessionManager.baseUrl.value,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),

              // Sync status card
              _buildSyncStatusCard(context),
              const SizedBox(height: 16),
              _buildUsageCard(context),

              const SizedBox(height: 24),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: _syncService.syncing,
                    builder: (context, syncing, _) {
                      return ElevatedButton.icon(
                        onPressed: syncing ? null : _handleSyncNow,
                        icon: syncing
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: xc.onInk,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: Text(syncing
                            ? context.l10n.get('syncInProgress')
                            : context.l10n.get('syncNow')),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _handleLogout,
                    icon: const Icon(Icons.logout),
                    label: Text(context.l10n.get('logout')),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: xc.error,
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSyncStatusCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;

    return ValueListenableBuilder<SyncSummary>(
      valueListenable: SyncStateStore.instance.summary,
      builder: (context, summary, _) {
        final lastSync = summary.lastSuccessAt != null
            ? _formatDateTime(summary.lastSuccessAt!)
            : context.l10n.get('never');
        final nodeIds = summary.nodeIds;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: xc.cardBackground,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: xc.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync, size: 18, color: xc.brand),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.get('desktopSync'),
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: cs.onSurface),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (NetworkAccessPolicy.instance.dedicated) ...[
                _infoRow(context, context.l10n.get('teamDedicated'),
                    NetworkAccessPolicy.instance.teamName),
                _infoRow(
                    context,
                    context.l10n.get('serviceValidity'),
                    NetworkAccessPolicy.instance.validUntil
                            ?.toLocal()
                            .toString() ??
                        '-'),
              ],
              _infoRow(context, context.l10n.get('lastSyncTime'), lastSync),
              const SizedBox(height: 4),
              _infoRow(context, context.l10n.get('syncedNodes'),
                  '${summary.nodeCount}'),
              if (nodeIds != null && nodeIds.isNotEmpty) ...[
                const SizedBox(height: 4),
                _infoRow(context, context.l10n.get('nodeIds'), nodeIds),
              ],
              if (summary.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.get(summary.lastError!),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: cs.error),
                ),
                if (summary.lastError ==
                    DesktopSyncService.sessionExpiredMessage)
                  TextButton(
                    onPressed: _reauthenticate,
                    child: Text(context.l10n.get('connectorSignInAgain')),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurface),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm(BuildContext context, bool isMfaRequired) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.link_outlined, size: 64, color: xc.brand),
                      const SizedBox(height: 16),
                      Text(
                        context.l10n.get('selfHostedConnector'),
                        style: Theme.of(
                          context,
                        ).textTheme.displaySmall?.copyWith(color: cs.onSurface),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.get('connectorIntro'),
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: xc.mutedText),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),

                      // Server address
                      TextField(
                        controller: _baseUrlController,
                        decoration: InputDecoration(
                          labelText: context.l10n.get('serverAddress'),
                          hintText: context.l10n.get('serverAddressHint'),
                          prefixIcon: const Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                        ),
                        onSubmitted: (_) =>
                            _sessionManager.setBaseUrl(_baseUrlController.text),
                      ),
                      const SizedBox(height: 16),

                      // Username / email
                      TextField(
                        controller: _usernameController,
                        enabled: !isMfaRequired,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
                        decoration: InputDecoration(
                          labelText: context.l10n.get('accountOrEmail'),
                          prefixIcon: const Icon(Icons.person_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Password
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        enabled: !isMfaRequired,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: context.l10n.get('password'),
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                        ),
                        onSubmitted: (_) => _handleLogin(),
                      ),

                      // MFA code field
                      if (isMfaRequired) ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: _mfaCodeController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          decoration: InputDecoration(
                            labelText: context.l10n.get('mfaCode'),
                            helperText: context.l10n.get('mfaRequiredHint'),
                            prefixIcon:
                                const Icon(Icons.verified_user_outlined),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.card),
                            ),
                          ),
                          onSubmitted: (_) => _handleLogin(),
                        ),
                      ],

                      const SizedBox(height: 24),

                      // Login button
                      ValueListenableBuilder<bool>(
                        valueListenable: _sessionManager.loading,
                        builder: (context, loading, _) {
                          return ElevatedButton(
                            onPressed: loading ? null : _handleLogin,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: loading
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: cs.onPrimary,
                                    ),
                                  )
                                : Text(
                                    context.l10n.get(
                                        isMfaRequired ? 'verifyMfa' : 'login'),
                                  ),
                          );
                        },
                      ),

                      if (_reauthenticating && _sessionManager.isLoggedIn)
                        ValueListenableBuilder<bool>(
                          valueListenable: _sessionManager.loading,
                          builder: (context, loading, _) => TextButton(
                            onPressed: loading
                                ? null
                                : () {
                                    _passwordController.clear();
                                    setState(() => _reauthenticating = false);
                                  },
                            child: Text(context.l10n.get('cancel')),
                          ),
                        ),

                      // Error message
                      ValueListenableBuilder<String?>(
                        valueListenable: _sessionManager.lastError,
                        builder: (context, error, _) {
                          if (error == null) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              error,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(color: cs.error),
                              textAlign: TextAlign.center,
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
