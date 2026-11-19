import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/screens/home_screen.dart';
import 'package:xconnect/services/vpn_config_service.dart';

VpnNode _buildNode({
  required String name,
  String? routingPool,
  String? pricingGroup,
}) {
  return VpnNode(
    name: name,
    countryCode: 'JP',
    configPath: '/tmp/$name.json',
    serviceName: 'xconnect-$name',
    routingPool: routingPool,
    pricingGroup: pricingGroup,
  );
}

void main() {
  group('isProTierNode', () {
    test('returns true for Pro-EC2-Pool or pricingGroup pro', () {
      expect(
        isProTierNode(
          _buildNode(
            name: 'jp-xconnect-02.svc.plus',
            routingPool: 'Pro-EC2-Pool',
            pricingGroup: 'pro',
          ),
        ),
        isTrue,
      );
      expect(
        isProTierNode(
          _buildNode(
            name: 'jp-pro-only',
            routingPool: null,
            pricingGroup: 'PRO',
          ),
        ),
        isTrue,
      );
    });

    test('returns false for Media-Pool, Custom-Dedicated, and null', () {
      expect(isProTierNode(null), isFalse);
      expect(
        isProTierNode(
          _buildNode(
            name: 'ph-xconnect.svc.plus',
            routingPool: 'Media-Pool',
            pricingGroup: 'plus',
          ),
        ),
        isFalse,
      );
      expect(
        isProTierNode(
          _buildNode(
            name: 'jp-xconnect-free-01.svc.plus',
            routingPool: 'Media-Pool',
            pricingGroup: 'shared',
          ),
        ),
        isFalse,
      );
      expect(
        isProTierNode(
          _buildNode(
            name: 'us-xconnect-los-angeles-custom-01.svc.plus',
            routingPool: 'Custom-Dedicated',
            pricingGroup: 'custom',
          ),
        ),
        isFalse,
      );
    });
  });

  group('proStreamingNoticeBody l10n', () {
    testWidgets('provides friendly zh and en notice copy for existing SnackBar',
        (tester) async {
      late String zhCopy;
      late String enCopy;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Builder(
            builder: (context) {
              zhCopy = context.l10n.get('proStreamingNoticeBody');
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Builder(
            builder: (context) {
              enCopy = context.l10n.get('proStreamingNoticeBody');
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(zhCopy, contains('Plus / Shared'));
      expect(enCopy, contains('Media-Pool'));
    });
  });
}
