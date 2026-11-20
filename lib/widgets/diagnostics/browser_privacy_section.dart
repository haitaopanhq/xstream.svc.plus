import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/diagnostics/privacy_diagnostics.dart';
import '../../utils/app_theme.dart';

class BrowserPrivacySection extends StatefulWidget {
  const BrowserPrivacySection({super.key});

  @override
  State<BrowserPrivacySection> createState() => _BrowserPrivacySectionState();
}

class _BrowserPrivacySectionState extends State<BrowserPrivacySection> {
  final _browserCheck = LocalBrowserCheck();
  SystemPrivacySettings? _system;
  ExitLocation? _exit;
  bool _checkingExit = false;
  bool _checkedExit = false;
  bool _openingBrowser = false;
  bool _browserUnavailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readSystem());
  }

  Future<void> _readSystem() async {
    final system = await SystemPrivacySettings.read();
    if (mounted) setState(() => _system = system);
  }

  Future<void> _checkExit() async {
    setState(() {
      _checkingExit = true;
      _exit = null;
    });
    final lookup = ExitLocation.lookup();
    await _readSystem();
    final exit = await lookup;
    if (!mounted) return;
    setState(() {
      _exit = exit;
      _checkingExit = false;
      _checkedExit = true;
    });
  }

  Future<void> _openBrowser(String systemPrompt) async {
    final chinese = context.l10n.locale.languageCode == 'zh';
    setState(() {
      _openingBrowser = true;
      _browserUnavailable = false;
    });
    var opened = false;
    try {
      final page =
          await rootBundle.loadString('assets/browser_privacy_check.html');
      if (!mounted) return;
      final uri = await _browserCheck.start(
        page,
        chinese: chinese,
        systemPrompt: systemPrompt,
      );
      if (mounted) {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } on Exception {
      // Keep the failure visible next to the browser action.
    } finally {
      if (!opened) await _browserCheck.close();
      if (mounted) {
        setState(() {
          _openingBrowser = false;
          _browserUnavailable = !opened;
        });
      }
    }
  }

  Future<void> _copyPrompt(String prompt) async {
    final key = await Clipboard.setData(ClipboardData(text: prompt)).then(
      (_) => 'browserPrivacyCopied',
      onError: (Object _) => 'browserPrivacyCopyFailed',
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.get(key))));
    }
  }

  @override
  void dispose() {
    unawaited(_browserCheck.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.xColors;
    final l10n = context.l10n;
    final system = _system;
    final exit = _exit;
    final unavailable = l10n.get('browserPrivacyUnavailable');
    final exitRegion =
        [exit?.city, exit?.region, exit?.country].nonNulls.join(', ');
    final languages = View.of(context)
        .platformDispatcher
        .locales
        .map((locale) => locale.toLanguageTag())
        .join(', ');
    final systemRegion = system?.region;
    final systemZone = system?.timeZoneId;
    final regionDiffers = systemRegion != null &&
        RegExp(r'^[A-Z]{2}$').hasMatch(systemRegion) &&
        exit?.country != null &&
        systemRegion != exit!.country;
    final zoneDiffers = systemZone != null &&
        exit?.timeZone != null &&
        systemZone != exit!.timeZone;
    final timeZone = system == null
        ? null
        : '${systemZone ?? system.timeZoneLabel} (${system.formattedOffset})';
    final dnsServers = system?.dnsServers ?? const <String>[];
    final dnsCount = dnsServers.isEmpty ? unavailable : '${dnsServers.length}';
    final lookupStatus = _checkedExit && !_checkingExit
        ? unavailable
        : l10n.get('browserPrivacyNotChecked');
    final prompt = [
      l10n.get('browserPrivacyPromptTask'),
      '',
      '- ${l10n.get('browserPrivacySystemZone')} · ${timeZone ?? unavailable}',
      '- ${l10n.get('browserPrivacySystemLanguages')} · ${languages.isEmpty ? unavailable : languages}',
      '- ${l10n.get('browserPrivacySystemRegion')} · ${systemRegion ?? unavailable}',
      '- ${l10n.get('browserPrivacyDnsCount')} · $dnsCount',
      '- ${l10n.get('browserPrivacyExitRegion')} · ${exitRegion.isEmpty ? lookupStatus : exitRegion}',
      '- ${l10n.get('browserPrivacyExitZone')} · ${exit?.timeZone ?? lookupStatus}',
      if (regionDiffers) '- ${l10n.get('browserPrivacyRegionDifference')}',
      if (zoneDiffers) '- ${l10n.get('browserPrivacyZoneDifference')}',
    ].join('\n');

    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText('${l10n.get(label)} · ${value ?? unavailable}'),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.get('browserPrivacyTitle'),
              style: Theme.of(context).textTheme.titleMedium),
          row('browserPrivacySystemZone', timeZone),
          row('browserPrivacySystemLanguages',
              languages.isEmpty ? null : languages),
          row('browserPrivacySystemRegion', systemRegion),
          row('browserPrivacyDns',
              dnsServers.isEmpty ? null : dnsServers.join(', ')),
          if (exit != null) ...[
            row('browserPrivacyExitIp', exit.ip),
            row(
              'browserPrivacyExitRegion',
              exitRegion.isEmpty ? null : exitRegion,
            ),
            row('browserPrivacyExitZone', exit.timeZone),
            if (regionDiffers || zoneDiffers) ...[
              if (regionDiffers)
                row('browserPrivacyRegionDifference',
                    '$systemRegion / ${exit.country}'),
              if (zoneDiffers)
                row('browserPrivacyZoneDifference',
                    '$systemZone / ${exit.timeZone}'),
              const SizedBox(height: 8),
              Text(l10n.get('browserPrivacyDifferenceAdvice')),
            ],
          ] else if (_checkedExit && !_checkingExit) ...[
            const SizedBox(height: 8),
            Text(l10n.get('browserPrivacyLookupFailed')),
          ],
          const SizedBox(height: 12),
          Text(l10n.get('browserPrivacyLookupScope')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _checkingExit ? null : _checkExit,
                child: Text(l10n.get(_checkingExit
                    ? 'browserPrivacyChecking'
                    : 'browserPrivacyCheckExit')),
              ),
              if (LocalBrowserCheck.isSupported)
                OutlinedButton(
                  onPressed: _openingBrowser || _checkingExit || system == null
                      ? null
                      : () => _openBrowser(prompt),
                  child: Text(l10n.get('browserPrivacyOpenBrowser')),
                ),
              OutlinedButton.icon(
                onPressed: system == null || _checkingExit
                    ? null
                    : () => _copyPrompt(
                          '$prompt\n- ${l10n.get('browserPrivacyBrowserNotChecked')}',
                        ),
                icon: const Icon(Icons.copy_outlined),
                label: Text(l10n.get('browserPrivacyCopyPrompt')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.get(LocalBrowserCheck.isSupported
              ? 'browserPrivacyBrowserScope'
              : 'browserPrivacyMobileScope')),
          const SizedBox(height: 8),
          Text(l10n.get('browserPrivacyDnsScope')),
          if (_browserUnavailable) ...[
            const SizedBox(height: 8),
            Text(l10n.get('browserPrivacyOpenFailed')),
          ],
          const SizedBox(height: 8),
          Text(l10n.get('browserPrivacyAdvice')),
        ],
      ),
    );
  }
}
