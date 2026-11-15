import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'network_access_policy.dart';

/// Session lifecycle states for account authentication.
enum SessionStatus { unknown, loggedOut, mfaRequired, loggedIn }

class LoginResult {
  final bool success;
  final bool mfaRequired;
  final String message;

  const LoginResult({
    required this.success,
    required this.message,
    this.mfaRequired = false,
  });
}

class SessionRefreshUnavailableException implements Exception {
  const SessionRefreshUnavailableException();
}

/// Handles xc_session cookie and bearer token persistence.
class SessionManager {
  SessionManager._();

  static final SessionManager instance = SessionManager._();

  static const _prefsBaseUrlKey = 'session.baseUrl';
  static const _prefsCookieKey = 'session.cookie';
  static const _prefsTokenKey = 'session.token';
  static const _prefsRefreshKey = 'session.refreshToken';
  static const _prefsUserKey = 'session.username';

  final ValueNotifier<SessionStatus> status =
      ValueNotifier<SessionStatus>(SessionStatus.unknown);
  final ValueNotifier<String?> currentUser = ValueNotifier<String?>(null);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);
  final ValueNotifier<bool> loading = ValueNotifier<bool>(false);
  // No default endpoint: this is a self-hosted connector, the app must not
  // ship pre-pointed at any specific commercial service.
  final ValueNotifier<String> baseUrl = ValueNotifier<String>('');

  int generation = 0;
  Future<void> Function()? onSessionReset;

  String? _cookie;
  String? _sessionToken;
  String? _refreshToken;
  String? _mfaTicket;

  bool get isLoggedIn => status.value == SessionStatus.loggedIn;
  bool get isMfaRequired => status.value == SessionStatus.mfaRequired;
  String? get cookie => _cookie;
  String? get sessionToken => _sessionToken;
  String? get mfaTicket => _mfaTicket;

  Future<void> init() async {
    await NetworkAccessPolicy.instance.init();
    final prefs = await SharedPreferences.getInstance();
    final storedBaseUrl = prefs.getString(_prefsBaseUrlKey);
    if (storedBaseUrl != null && storedBaseUrl.isNotEmpty) {
      baseUrl.value = storedBaseUrl;
    }

    _cookie = prefs.getString(_prefsCookieKey);
    _sessionToken = prefs.getString(_prefsTokenKey);
    _refreshToken = prefs.getString(_prefsRefreshKey);
    currentUser.value = prefs.getString(_prefsUserKey);

    if ((_sessionToken ?? '').isNotEmpty || (_cookie ?? '').isNotEmpty) {
      NetworkAccessPolicy.instance.invalidate(signedIn: true);
      await NetworkAccessPolicy.instance.restoreCachedAccess(
        '${baseUrl.value}|${currentUser.value}',
      );
      status.value = SessionStatus.loggedIn;
    } else {
      NetworkAccessPolicy.instance.invalidate(signedIn: false);
      status.value = SessionStatus.loggedOut;
    }
  }

  Future<void> setBaseUrl(String url) async {
    final normalized = _normalizeBaseUrl(url);
    if (baseUrl.value != normalized) await logout();
    baseUrl.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsBaseUrlKey, normalized);
  }

  String _normalizeBaseUrl(String url) {
    var value = url.trim();
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    return value;
  }

  Uri buildEndpoint(String path) {
    final root = baseUrl.value;
    return Uri.parse('$root$path');
  }

  /// Retry only with credentials issued by the same connector. Never log out,
  /// prompt for credentials, or treat an HTTP failure as successful recovery.
  Future<http.Response> getWithSessionRecovery(
    http.Client client,
    Uri endpoint,
    Map<String, String> headers,
  ) async {
    final requestGeneration = generation;
    Future<http.Response> get(Map<String, String> requestHeaders) => client
        .get(endpoint, headers: requestHeaders)
        .timeout(const Duration(seconds: 20));
    var response = await get(headers);
    if (response.statusCode != 401 || requestGeneration != generation) {
      return response;
    }
    final cookieToken =
        RegExp(r'xc_session=([^;\s,]+)').firstMatch(_cookie ?? '')?.group(1);
    if (cookieToken != null && cookieToken != _sessionToken) {
      final cookieHeaders = Map<String, String>.from(headers)
        ..remove('Authorization');
      response = await get(cookieHeaders);
      if (requestGeneration != generation) return response;
      if (response.statusCode == 200) {
        await _saveRecoveredToken(cookieToken, requestGeneration);
        headers['Authorization'] = 'Bearer $cookieToken';
        return response;
      }
      if (response.statusCode != 401) return response;
    }
    final refreshToken = _refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      final refreshed = await client
          .post(
            buildEndpoint('/api/auth/token/refresh'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 20));
      if (requestGeneration != generation) return response;
      if (refreshed.statusCode == 200) {
        final token = _extractSessionToken(_parseBody(refreshed.body));
        if (token != null) {
          await _saveRecoveredToken(token, requestGeneration);
          if (requestGeneration != generation) return response;
          headers['Authorization'] = 'Bearer $token';
          return get(headers);
        }
      } else if (refreshed.statusCode == 408 ||
          refreshed.statusCode == 429 ||
          refreshed.statusCode >= 500) {
        // A refresh endpoint failure is neither a rejected session nor an
        // authoritative network policy response from the requested endpoint.
        throw const SessionRefreshUnavailableException();
      }
    }
    // One bounded retry also permits recovery from a transient rejected read.
    if (requestGeneration != generation) return response;
    return get(headers);
  }

  Future<void> _saveRecoveredToken(String token, int expectedGeneration) async {
    final prefs = await SharedPreferences.getInstance();
    if (expectedGeneration != generation) return;
    _sessionToken = token;
    await prefs.setString(_prefsTokenKey, token);
  }

  Future<LoginResult> login({
    required String identifier,
    required String password,
  }) async {
    loading.value = true;
    lastError.value = null;
    try {
      final response = await http
          .post(
            buildEndpoint('/api/auth/login'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identifier': identifier,
              'username': identifier,
              'email': identifier,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode >= 500) {
        lastError.value = '服务器错误 (${response.statusCode})';
        return LoginResult(success: false, message: lastError.value!);
      }
      if (response.statusCode == 404) {
        final body404 = _parseBody(response.body);
        final code404 = body404['error'] as String? ?? '';
        final msg404 = body404['message'] as String? ?? '';
        if (code404 == 'user_not_found' || msg404.contains('not found')) {
          lastError.value = msg404.isNotEmpty ? msg404 : '用户不存在';
          return LoginResult(success: false, message: lastError.value!);
        }
        lastError.value = '登录接口未启用，请确认部署配置。';
        return LoginResult(success: false, message: lastError.value!);
      }

      final payload = _parseBody(response.body);
      if (_isMfaRequired(payload)) {
        final ticket = _extractMfaTicket(payload);
        if (ticket == null || ticket.isEmpty) {
          lastError.value = 'MFA 票据缺失';
          return LoginResult(success: false, message: lastError.value!);
        }
        _mfaTicket = ticket;
        currentUser.value = identifier;
        status.value = SessionStatus.mfaRequired;
        return const LoginResult(
          success: false,
          mfaRequired: true,
          message: '请输入 MFA 验证码',
        );
      }

      if (response.statusCode != 200) {
        final message = payload['message'] as String? ?? '账号或密码错误';
        lastError.value = message;
        return LoginResult(success: false, message: message);
      }

      return await _completeLogin(
        payload: payload,
        responseHeaders: response.headers,
        fallbackUsername: identifier,
      );
    } catch (e) {
      final message = '登录失败: $e';
      lastError.value = message;
      return LoginResult(success: false, message: message);
    } finally {
      loading.value = false;
    }
  }

  Future<LoginResult> verifyMfaCode(String code) async {
    final ticket = (_mfaTicket ?? '').trim();
    final normalizedCode = code.trim();
    if (ticket.isEmpty) {
      lastError.value = 'MFA 会话不存在，请重新登录';
      return LoginResult(success: false, message: lastError.value!);
    }
    if (normalizedCode.isEmpty) {
      lastError.value = '请输入 MFA 验证码';
      return LoginResult(success: false, message: lastError.value!);
    }

    loading.value = true;
    lastError.value = null;
    try {
      final response = await http
          .post(
            buildEndpoint('/api/auth/mfa/verify'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'mfa_ticket': ticket,
              'code': normalizedCode,
              'method': 'totp',
            }),
          )
          .timeout(const Duration(seconds: 20));

      final payload = _parseBody(response.body);
      if (response.statusCode != 200) {
        final message = payload['message'] as String? ?? 'MFA 验证失败';
        lastError.value = message;
        return LoginResult(success: false, message: message);
      }

      return await _completeLogin(
        payload: payload,
        responseHeaders: response.headers,
        fallbackUsername: currentUser.value ?? '',
      );
    } catch (e) {
      final message = 'MFA 验证失败: $e';
      lastError.value = message;
      return LoginResult(success: false, message: message);
    } finally {
      loading.value = false;
    }
  }

  Future<LoginResult> _completeLogin({
    required Map<String, dynamic> payload,
    required Map<String, String> responseHeaders,
    required String fallbackUsername,
  }) async {
    final token = _extractSessionToken(payload);
    final cookie = _extractSessionCookie(responseHeaders);
    if ((token ?? '').isEmpty && (cookie ?? '').isEmpty) {
      lastError.value = '未返回有效会话信息';
      return LoginResult(success: false, message: lastError.value!);
    }

    await logout();
    _sessionToken = token;
    _refreshToken = payload['refresh_token'] is String
        ? payload['refresh_token'] as String
        : null;
    _cookie = cookie;
    _mfaTicket = null;
    final savedUser = _extractLoginIdentity(payload, fallbackUsername);
    currentUser.value = savedUser;
    generation++;
    NetworkAccessPolicy.instance.invalidate(signedIn: true);
    status.value = SessionStatus.loggedIn;

    final prefs = await SharedPreferences.getInstance();
    if (_cookie != null && _cookie!.isNotEmpty) {
      await prefs.setString(_prefsCookieKey, _cookie!);
    } else {
      await prefs.remove(_prefsCookieKey);
    }
    if (_sessionToken != null && _sessionToken!.isNotEmpty) {
      await prefs.setString(_prefsTokenKey, _sessionToken!);
    } else {
      await prefs.remove(_prefsTokenKey);
    }
    if ((_refreshToken ?? '').isNotEmpty) {
      await prefs.setString(_prefsRefreshKey, _refreshToken!);
    }
    await prefs.setString(_prefsUserKey, savedUser);

    return const LoginResult(success: true, message: '登录成功');
  }

  Future<void> logout() async {
    generation++;
    NetworkAccessPolicy.instance.invalidate(signedIn: false);
    _cookie = null;
    _sessionToken = null;
    _refreshToken = null;
    _mfaTicket = null;
    currentUser.value = null;
    status.value = SessionStatus.loggedOut;
    lastError.value = null;
    try {
      await onSessionReset?.call();
    } finally {
      await _clearPrefs();
    }
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsCookieKey);
    await prefs.remove(_prefsTokenKey);
    await prefs.remove(_prefsRefreshKey);
    await prefs.remove(_prefsUserKey);
    await NetworkAccessPolicy.instance.clearCachedAccess();
  }

  Map<String, dynamic> _parseBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  bool _isMfaRequired(Map<String, dynamic> payload) {
    return payload['mfa_required'] == true || payload['mfaRequired'] == true;
  }

  String? _extractMfaTicket(Map<String, dynamic> payload) {
    final candidates = [
      payload['mfa_ticket'],
      payload['mfaTicket'],
      payload['mfaToken'],
    ];
    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return null;
  }

  String? _extractSessionToken(Map<String, dynamic> payload) {
    final candidates = [payload['token'], payload['access_token']];
    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return null;
  }

  String? _extractSessionCookie(Map<String, String> headers) {
    final setCookie = headers['set-cookie'];
    if (setCookie == null) return null;

    final match = RegExp(r'xc_session=([^;\s,]+)').firstMatch(setCookie);
    if (match != null) return 'xc_session=${match.group(1)}';
    return null;
  }

  String _extractLoginIdentity(
    Map<String, dynamic> payload,
    String fallbackUsername,
  ) {
    final user = payload['user'];
    if (user is Map) {
      final normalized = user.cast<Object?, Object?>();
      final candidates = [
        normalized['email'],
        normalized['username'],
        normalized['name'],
      ];
      for (final candidate in candidates) {
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate.trim();
        }
      }
    }
    return fallbackUsername;
  }
}
