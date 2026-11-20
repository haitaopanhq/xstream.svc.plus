import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xconnect/services/diagnostics/privacy_diagnostics.dart';

void main() {
  test('system region handles language scripts and locale suffixes', () {
    String? region(String locale) => SystemPrivacySettings(
          locale: locale,
          timeZoneLabel: '',
          offset: Duration.zero,
        ).region;

    expect(region('zh-Hans-CN'), 'CN');
    expect(region('en_US.UTF-8'), 'US');
    expect(region('es-419'), '419');
    expect(region('zh-Hans'), isNull);
  });

  test('browser check serves an escaped prompt only at its loopback URL',
      () async {
    final check = LocalBrowserCheck();
    addTearDown(check.close);
    final uri = await check.start(
      '<html lang="{{lang}}"><template>{{systemPrompt}}</template>'
      '<script nonce="{{nonce}}"></script></html>',
      chinese: true,
      systemPrompt: '</template><script>alert(1)</script>',
    );

    expect(uri.host, InternetAddress.loopbackIPv4.address);
    expect((await http.get(uri.replace(path: '/'))).statusCode, 404);
    expect((await http.post(uri)).statusCode, 404);
    expect(
      (await http.get(uri, headers: {'Host': 'other.example'})).statusCode,
      404,
    );
    final response = await http.get(uri);
    expect(response.statusCode, 200);
    expect(response.headers['cache-control'], 'no-store');
    expect(
      response.headers['content-security-policy'],
      contains("script-src 'nonce-${uri.pathSegments.single}'"),
    );
    expect(response.body, contains('lang="zh-CN"'));
    expect(response.body, contains('&lt;script&gt;'));
    expect(response.body, isNot(contains('<script>alert(1)</script>')));
  });
}
