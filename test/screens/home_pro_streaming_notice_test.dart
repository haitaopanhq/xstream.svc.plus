import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/screens/home_screen.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/app_theme.dart';

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

Widget _wrapWithApp(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    theme: AppTheme.lightTheme,
    home: Scaffold(body: child),
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

  group('ProStreamingNoticeBanner', () {
    testWidgets('renders friendly notice for Pro node and triggers callbacks',
        (tester) async {
      var switched = false;
      var dismissed = false;

      await tester.pumpWidget(
        _wrapWithApp(
          ProStreamingNoticeBanner(
            node: _buildNode(
              name: 'jp-xconnect-02.svc.plus',
              routingPool: 'Pro-EC2-Pool',
              pricingGroup: 'pro',
            ),
            onSwitchNode: () => switched = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('pro_streaming_notice_banner')),
        findsOneWidget,
      );
      expect(find.text('Pro 节点仅用于 AI 与开发办公'), findsOneWidget);
      expect(find.textContaining('切换至 Plus / Shared'), findsOneWidget);
      expect(find.text('切换节点'), findsOneWidget);

      await tester.tap(find.text('切换节点'));
      await tester.pump();
      expect(switched, isTrue);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(dismissed, isTrue);
    });

    testWidgets('renders English copy when locale is en', (tester) async {
      await tester.pumpWidget(
        _wrapWithApp(
          ProStreamingNoticeBanner(
            node: _buildNode(
              name: 'jp-xconnect-02.svc.plus',
              routingPool: 'Pro-EC2-Pool',
              pricingGroup: 'pro',
            ),
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Pro Node'), findsOneWidget);
      expect(find.textContaining('Media-Pool'), findsOneWidget);
    });

    testWidgets('renders nothing for Media-Pool or Custom-Dedicated nodes',
        (tester) async {
      await tester.pumpWidget(
        _wrapWithApp(
          ProStreamingNoticeBanner(
            node: _buildNode(
              name: 'ph-xconnect.svc.plus',
              routingPool: 'Media-Pool',
              pricingGroup: 'plus',
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('pro_streaming_notice_banner')),
        findsNothing,
      );

      await tester.pumpWidget(
        _wrapWithApp(
          ProStreamingNoticeBanner(
            node: _buildNode(
              name: 'us-xconnect-los-angeles-custom-01.svc.plus',
              routingPool: 'Custom-Dedicated',
              pricingGroup: 'custom',
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('pro_streaming_notice_banner')),
        findsNothing,
      );
    });
  });
}
