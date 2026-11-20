import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

class ExitLocation {
  const ExitLocation({
    required this.ip,
    this.city,
    this.region,
    this.country,
    this.timeZone,
  });

  final String ip;
  final String? city;
  final String? region;
  final String? country;
  final String? timeZone;

  static const _timeout = Duration(seconds: 8);
  static final _endpoint = Uri.https('ipinfo.io', '/json');

  static Future<ExitLocation?> lookup() async {
    final client = http.Client();
    try {
      final request = http.Request('GET', _endpoint)..followRedirects = false;
      final response =
          await client.send(request).then(http.Response.fromStream).timeout(
                _timeout,
              );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      String? field(String key) {
        final value = data[key];
        return value is String && value.trim().isNotEmpty ? value.trim() : null;
      }

      final ip = field('ip');
      if (ip == null || InternetAddress.tryParse(ip) == null) return null;
      return ExitLocation(
        ip: ip,
        city: field('city'),
        region: field('region'),
        country: field('country')?.toUpperCase(),
        timeZone: field('timezone'),
      );
    } on Exception {
      return null;
    } finally {
      client.close();
    }
  }
}

class SystemPrivacySettings {
  const SystemPrivacySettings({
    required this.locale,
    required this.timeZoneLabel,
    required this.offset,
    this.timeZoneId,
    this.dnsServers = const [],
  });

  final String locale;
  final String timeZoneLabel;
  final Duration offset;
  final String? timeZoneId;
  final List<String> dnsServers;

  String? get region => RegExp(
        r'^[a-z]{2,3}(?:[-_][a-z]{4})?[-_]([a-z]{2}|[0-9]{3})(?=$|[-_.@])',
        caseSensitive: false,
      ).firstMatch(locale)?.group(1)?.toUpperCase();

  String get formattedOffset {
    final minutes = offset.inMinutes.abs();
    final hours = (minutes ~/ 60).toString().padLeft(2, '0');
    final remainder = (minutes % 60).toString().padLeft(2, '0');
    return 'UTC${offset.isNegative ? '−' : '+'}$hours:$remainder';
  }

  static Future<SystemPrivacySettings> read() async {
    // AppleLocale reflects the formatting region, which may differ from the
    // first preferred language reported by the Flutter engine.
    var locale = Platform.localeName;
    if (Platform.isMacOS) {
      try {
        final result = await Process.run(
          '/usr/bin/defaults',
          ['read', '-g', 'AppleLocale'],
        ).timeout(const Duration(seconds: 2));
        final value = result.stdout.toString().trim();
        if (result.exitCode == 0 && value.isNotEmpty) locale = value;
      } on Exception {
        // Fall back to the locale visible to the process.
      }
    }
    String? timeZoneId;
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        final target = await Link('/etc/localtime').target();
        const marker = 'zoneinfo/';
        final index = target.lastIndexOf(marker);
        if (index != -1) {
          final id = target.substring(index + marker.length);
          if (id.isNotEmpty) timeZoneId = id;
        }
      } on FileSystemException {
        // Some systems copy the zone file instead of using a link.
      }
    }
    final now = DateTime.now();
    return SystemPrivacySettings(
      locale: locale,
      timeZoneLabel: now.timeZoneName,
      timeZoneId: timeZoneId,
      offset: now.timeZoneOffset,
      dnsServers: await _readDnsServers(),
    );
  }

  static Future<List<String>> _readDnsServers() async {
    try {
      final String values;
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/scutil', ['--dns'])
            .timeout(const Duration(seconds: 2));
        if (result.exitCode != 0) return const [];
        values = RegExp(r'^\s*nameserver\[\d+\]\s*:\s*(\S+)', multiLine: true)
            .allMatches(result.stdout.toString())
            .map((match) => match.group(1)!)
            .join('\n');
      } else if (Platform.isLinux) {
        final config = await File('/etc/resolv.conf').readAsString();
        values = RegExp(r'^\s*nameserver\s+(\S+)', multiLine: true)
            .allMatches(config)
            .map((match) => match.group(1)!)
            .join('\n');
      } else if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-DnsClientServerAddress).ServerAddresses',
        ]).timeout(const Duration(seconds: 3));
        if (result.exitCode != 0) return const [];
        values = result.stdout.toString();
      } else {
        return const [];
      }
      return values
          .split(RegExp(r'\s+'))
          .where((value) =>
              InternetAddress.tryParse(value.split('%').first) != null)
          .toSet()
          .toList(growable: false);
    } on Exception {
      return const [];
    }
  }
}

/// Serves a read-only page briefly to the external browser on this device.
class LocalBrowserCheck {
  HttpServer? _server;
  Timer? _expiry;

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<Uri> start(
    String template, {
    required bool chinese,
    required String systemPrompt,
  }) async {
    await close();
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.idleTimeout = const Duration(seconds: 5);
    final uri = Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: '/$nonce',
    );
    final page = template
        .replaceFirst('{{lang}}', chinese ? 'zh-CN' : 'en')
        .replaceFirst('{{nonce}}', nonce)
        .replaceFirst('{{systemPrompt}}', htmlEscape.convert(systemPrompt));
    _expiry = Timer(const Duration(minutes: 2), () => unawaited(close()));
    server.listen((request) async {
      final response = request.response;
      try {
        if (request.method != 'GET' ||
            request.headers.value(HttpHeaders.hostHeader) != uri.authority ||
            request.uri.toString() != uri.path) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers
            ..contentType = ContentType('text', 'html', charset: 'utf-8')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..set('X-Content-Type-Options', 'nosniff')
            ..set('Referrer-Policy', 'no-referrer')
            ..set(
              'Content-Security-Policy',
              "default-src 'none'; script-src 'nonce-$nonce'; "
                  "style-src 'unsafe-inline'; connect-src https://ipinfo.io; "
                  "frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
            );
          response.write(page);
        }
        await response.close();
      } on Exception {
        // The browser may disconnect before the response is sent.
      }
    });
    return uri;
  }

  Future<void> close() async {
    _expiry?.cancel();
    _expiry = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
