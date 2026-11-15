import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/network_access_policy.dart';
import 'package:xconnect/services/session/session_manager.dart';
import 'package:xconnect/services/sync/desktop_sync_service.dart';
import 'package:xconnect/services/sync/sync_state.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/app_log_file.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = SessionManager.instance;
  final sync = DesktopSyncService.instance;
  final policy = NetworkAccessPolicy.instance;
  late Directory support;

  final access = {
    'mode': 'dedicated',
    'allowed': true,
    'accountId': 'account-a',
    'teamId': 'team-a',
    'team': {
      'name': 'Team A',
      'validUntil':
          DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    },
  };
  const nodes = [
    {
      'id': 'node-a',
      'name': 'Cached connection',
      'region': 'test',
      'vless_uri':
          'vless://11111111-1111-4111-8111-111111111111@edge.example:443'
              '?type=xhttp&security=tls&path=%2Fsecure',
    },
  ];

  setUpAll(() async {
    // Logging is not under test; queued writes must not race temp-dir cleanup.
    AppLogFile.enabled = false;
    support = await Directory.systemTemp.createTemp('xconnect-managed-cache-');
    GlobalApplicationConfig.localConfigPathOverride =
        '${support.path}/vpn_nodes.json';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      if (utf8.decode(message!.buffer.asUint8List()) !=
          'macos/Runner/Configs/AppInfo.xcconfig') {
        return null;
      }
      return ByteData.sublistView(
        Uint8List.fromList(
          utf8.encode('PRODUCT_BUNDLE_IDENTIFIER=plus.svc.xconnect'),
        ),
      );
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'test-session',
      'session.username': 'member@example',
    });
    session.onSessionReset = null;
    await session.init();
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    await VpnConfig.importFromJson('[]');
    sync.client = MockClient((request) async {
      if (request.url.path.endsWith('/network-access')) {
        return http.Response(jsonEncode(access), 200);
      }
      if (request.url.path.endsWith('/nodes')) {
        return http.Response(jsonEncode(nodes), 200);
      }
      return http.Response('', 404);
    });
    expect((await sync.syncNow()).success, isTrue);
  });

  tearDownAll(() async {
    GlobalApplicationConfig.localConfigPathOverride = null;
    await support.delete(recursive: true);
  });
  tearDown(sync.dispose);

  test('weak network, offline restart and retry preserve the same snapshot',
      () async {
    final saved = VpnConfig.allNodes.single;
    final summary = SyncStateStore.instance.summary.value;
    var offline = false;
    var recovered = false;
    sync.client = MockClient((request) async {
      if (offline) throw const SocketException('No network');
      if (!recovered) {
        // Network access looks rejected while the independent session check
        // times out. This is not enough evidence to invalidate the account.
        if (request.url.path == '/api/auth/session') {
          throw TimeoutException('Weak network');
        }
        return http.Response('{"error":"invalid_session"}', 401);
      }
      if (request.url.path.endsWith('/network-access')) {
        return http.Response(jsonEncode(access), 200);
      }
      if (request.url.path.endsWith('/nodes')) {
        return http.Response(
          jsonEncode([
            {...nodes.single, 'id': 'node-after-reconnect'}
          ]),
          200,
        );
      }
      return http.Response('', 404);
    });

    final weak = await sync.syncNow();
    expect(weak.message, DesktopSyncService.syncUnavailableMessage);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.configPath, saved.configPath);
    expect(SyncStateStore.instance.summary.value.lastSuccessAt,
        summary.lastSuccessAt);

    offline = true;
    await session.init();
    await VpnConfig.load();
    final disconnected = await sync.syncNow(manual: true);
    expect(disconnected.message, DesktopSyncService.syncUnavailableMessage);
    expect(session.isLoggedIn, isTrue);
    expect(session.sessionToken, 'test-session');
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
    expect(await File(saved.configPath).exists(), isTrue);
    expect(sync.syncing.value, isFalse);

    offline = false;
    recovered = true;
    expect((await sync.syncNow(manual: true)).success, isTrue);
    expect(SyncStateStore.instance.summary.value.lastError, isNull);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-after-reconnect');
    expect(session.sessionToken, 'test-session');
  });

  test('temporary team-node 503 keeps the last successful snapshot', () async {
    sync.client = MockClient(
      (request) async => request.url.path.endsWith('/network-access')
          ? http.Response(jsonEncode(access), 200)
          : http.Response('', 503),
    );
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
  });

  test('malformed nonempty snapshot cannot erase valid cached nodes', () async {
    sync.client = MockClient(
      (request) async => request.url.path.endsWith('/network-access')
          ? http.Response(jsonEncode(access), 200)
          : http.Response('[{"broken":true}]', 200),
    );
    expect((await sync.syncNow()).success, isFalse);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
  });

  test('another account cannot restore the cached authorization', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.username', 'other@example');
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('explicit denial invalidates the cache across restart', () async {
    final saved = VpnConfig.allNodes.single;
    sync.client = MockClient((_) async => http.Response('', 403));
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isFalse);
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
    expect(VpnConfig.allNodes.single.configPath, saved.configPath);
    expect(await File(saved.configPath).exists(), isTrue);
  });

  test(
    'logout clears cached authorization even without cleanup callback',
    () async {
      await session.logout();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session.token', 'new-session');
      await prefs.setString('session.username', 'member@example');
      await session.init();
      expect(policy.active, isFalse);
      expect(VpnConfig.nodes, isEmpty);
    },
  );

  test('an authoritative empty list withdraws the offline snapshot', () async {
    final saved = VpnConfig.allNodes.single;
    sync.client = MockClient(
      (request) async => request.url.path.endsWith('/network-access')
          ? http.Response(jsonEncode(access), 200)
          : http.Response('[]', 200),
    );
    expect((await sync.syncNow()).success, isFalse);
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
    expect(VpnConfig.allNodes.single.configPath, saved.configPath);
    expect(await File(saved.configPath).exists(), isTrue);
  });

  test('manual sync recovers a transient 401 without withdrawing access',
      () async {
    var accessCalls = 0;
    final generation = session.generation;
    sync.client = MockClient((request) async {
      if (request.url.path.endsWith('/network-access')) {
        return ++accessCalls == 1
            ? http.Response('{}', 401)
            : http.Response(jsonEncode(access), 200);
      }
      if (request.url.path.endsWith('/nodes')) {
        return http.Response(jsonEncode(nodes), 200);
      }
      return http.Response('', 404);
    });
    expect((await sync.syncNow(manual: true)).success, isTrue);
    expect(accessCalls, 2);
    expect(session.generation, generation);
    expect(session.isLoggedIn, isTrue);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
    expect(sync.syncing.value, isFalse);
  });

  test('expired login retains credentials and saved managed files', () async {
    final saved = VpnConfig.allNodes.single;
    session.onSessionReset = sync.clearManagedConnections;
    sync.client = MockClient(
      (_) async => http.Response('{"error":"invalid or expired token"}', 401),
    );
    final result = await sync.syncNow();
    expect(result.message, DesktopSyncService.sessionExpiredMessage);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sync.lastError'), isNull);
    expect(session.isLoggedIn, isTrue);
    expect(session.sessionToken, 'test-session');
    expect(VpnConfig.nodes, isEmpty);
    expect(VpnConfig.allNodes.single.configPath, saved.configPath);
    expect(await File(saved.configPath).exists(), isTrue);
  });

  for (final endpoint in ['access', 'nodes']) {
    test('$endpoint 401 retains persisted login through restart', () async {
      sync.client = MockClient((request) async {
        if (endpoint == 'nodes' &&
            request.url.path.endsWith('/network-access')) {
          return http.Response(jsonEncode(access), 200);
        }
        return http.Response('{"error":"session not found"}', 401);
      });
      expect((await sync.syncNow()).success, isFalse);
      expect(session.isLoggedIn, isTrue);
      expect(session.sessionToken, 'test-session');
      expect((await SharedPreferences.getInstance()).getString('session.token'),
          'test-session');
      expect(policy.active, isFalse);
      await session.init();
      expect(session.isLoggedIn, isTrue);
      expect(policy.active, isFalse);
      expect(VpnConfig.allNodes.single.managedNodeId, 'node-a');
    });
  }

  for (final verification in [
    http.Response('{"user":{"id":"account-a"}}', 200),
    http.Response('Unauthorized', 401),
    http.Response('', 503),
  ]) {
    test(
        'sync 401 with session response ${verification.statusCode} keeps access',
        () async {
      final saved = VpnConfig.allNodes.single;
      var verified = false;
      sync.client = MockClient((request) async {
        if (request.url.path == '/api/auth/session') {
          verified = true;
          expect(request.headers['Authorization'], 'Bearer test-session');
          return verification;
        }
        return http.Response('{"error":"invalid_session"}', 401);
      });

      final result = await sync.syncNow(manual: true);
      expect(verified, isTrue);
      expect(result.success, isFalse);
      expect(result.message, DesktopSyncService.syncUnavailableMessage);
      expect(SyncStateStore.instance.summary.value.lastError, result.message);
      expect(session.isLoggedIn, isTrue);
      expect(policy.active, isTrue);
      expect(VpnConfig.nodes.single.configPath, saved.configPath);
      expect(await File(saved.configPath).exists(), isTrue);

      sync.client = MockClient((request) async {
        if (request.url.path.endsWith('/network-access')) {
          return http.Response(jsonEncode(access), 200);
        }
        if (request.url.path.endsWith('/nodes')) {
          return http.Response(jsonEncode(nodes), 200);
        }
        return http.Response('', 404);
      });
      expect((await sync.syncNow()).success, isTrue);
      expect(SyncStateStore.instance.summary.value.lastError, isNull);
    });
  }

  test('rate-limited session refresh cannot purge cached nodes', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.refreshToken', 'test-refresh');
    await session.init();
    final saved = VpnConfig.allNodes.single;
    var refreshes = 0;
    bool canRefresh = false;
    sync.client = MockClient((request) async {
      if (request.url.path.endsWith('/token/refresh')) {
        refreshes++;
        return canRefresh
            ? http.Response('{"access_token":"renewed"}', 200)
            : http.Response('{"code":"quota_exhausted"}', 429);
      }
      if (request.headers['Authorization'] != 'Bearer renewed') {
        return http.Response('{"error":"invalid_session"}', 401);
      }
      if (request.url.path.endsWith('/network-access')) {
        return http.Response(jsonEncode(access), 200);
      }
      if (request.url.path.endsWith('/nodes')) {
        return http.Response(jsonEncode(nodes), 200);
      }
      return http.Response('', 404);
    });
    final result = await sync.syncNow();
    expect(result.message, DesktopSyncService.syncUnavailableMessage);
    expect(refreshes, 1);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.configPath, saved.configPath);
    expect(await File(saved.configPath).exists(), isTrue);
    expect(session.sessionToken, 'test-session');

    canRefresh = true;
    expect((await sync.syncNow()).success, isTrue);
    expect(refreshes, 2);
    expect(session.sessionToken, 'renewed');
    expect(SyncStateStore.instance.summary.value.lastError, isNull);
  });

  test('old session verification cannot invalidate a new login', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    sync.client = MockClient((request) async {
      if (request.url.path == '/api/auth/session') {
        if (!started.isCompleted) started.complete();
        return response.future;
      }
      return http.Response('', 401);
    });
    final pending = sync.syncNow();
    await started.future;
    await session.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.token', 'new-session');
    await session.init();
    sync.client = MockClient((_) async => http.Response('', 503));
    response.complete(http.Response('{"code":"invalid_session"}', 401));
    expect((await pending).success, isFalse);
    expect(session.isLoggedIn, isTrue);
    expect(session.sessionToken, 'new-session');
  });

  test('an unclassified policy denial preserves managed files', () async {
    final saved = VpnConfig.allNodes.single;
    sync.client = MockClient(
      (_) async =>
          http.Response(jsonEncode({...access, 'allowed': false}), 200),
    );
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isFalse);
    expect(VpnConfig.allNodes.single.configPath, saved.configPath);
    expect(await File(saved.configPath).exists(), isTrue);
  });

  for (final code in [
    'quota_exhausted',
    'traffic_stopped',
    'email_blacklisted',
  ]) {
    for (final endpoint in ['access', 'nodes']) {
      test(
        '$endpoint explicit $code purges only managed configuration',
        () async {
          final saved = VpnConfig.allNodes.single;
          final customFile = File('${support.path}/independent.json');
          await customFile.writeAsString('{"custom":true}');
          VpnConfig.addNode(
            VpnNode(
              name: 'Independent',
              countryCode: 'CUSTOM',
              configPath: customFile.path,
              serviceName: 'custom.import',
            ),
          );
          await VpnConfig.saveToFile();
          sync.client = MockClient((request) async {
            if (endpoint == 'access' || request.url.path.endsWith('/nodes')) {
              return http.Response(jsonEncode({'error': code}), 403);
            }
            if (request.url.path.endsWith('/network-access')) {
              return http.Response(jsonEncode(access), 200);
            }
            return http.Response('', 404);
          });
          expect((await sync.syncNow()).success, isFalse);
          expect(VpnConfig.allNodes.where((n) => n.isManaged), isEmpty);
          expect(await File(saved.configPath).exists(), isFalse);
          expect(await customFile.readAsString(), '{"custom":true}');
          expect(policy.active, isFalse);
        },
      );
    }
  }

  test(
    'quota words in a generic forbidden message do not permit deletion',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (_) async => http.Response(
          '{"error":"forbidden","message":"quota_exhausted"}',
          403,
        ),
      );
      await sync.syncNow();
      expect(VpnConfig.allNodes.single.configPath, saved.configPath);
      expect(await File(saved.configPath).exists(), isTrue);
    },
  );

  test(
    'a transient server error cannot authorize purge through its body',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (_) async => http.Response('{"error":"email_blacklisted"}', 503),
      );
      await sync.syncNow();
      expect(policy.active, isTrue);
      expect(await File(saved.configPath).exists(), isTrue);
    },
  );

  test(
    'ordinary node authorization failure suspends without deleting files',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (request) async => request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode(access), 200)
            : http.Response('{"code":"forbidden"}', 403),
      );
      await sync.syncNow();
      await session.init();
      expect(policy.active, isFalse);
      expect(await File(saved.configPath).exists(), isTrue);
      expect(VpnConfig.allNodes.single.managedNodeId, 'node-a');
    },
  );

  test(
    'suspension retains ownership for a later explicit enforcement',
    () async {
      final saved = VpnConfig.allNodes.single;
      session.onSessionReset = sync.clearManagedConnections;
      await session.logout();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session.token', 'new-session');
      await prefs.setString('session.username', 'member@example');
      await session.init();
      expect(await File(saved.configPath).exists(), isTrue);
      sync.client = MockClient(
        (_) async => http.Response('{"error":"email_blacklisted"}', 403),
      );
      await sync.syncNow();
      expect(await File(saved.configPath).exists(), isFalse);
      expect(VpnConfig.allNodes, isEmpty);
    },
  );

  test(
    'a denied new account cannot purge another account retained snapshot',
    () async {
      final saved = VpnConfig.allNodes.single;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session.username', 'other@example');
      await session.init();
      sync.client = MockClient(
        (_) async => http.Response('{"error":"email_blacklisted"}', 403),
      );
      await sync.syncNow();
      expect(policy.active, isFalse);
      expect(VpnConfig.nodes, isEmpty);
      expect(await File(saved.configPath).exists(), isTrue);
      expect(
        VpnConfig.allNodes.single.managedOwner,
        'https://accounts.example|account-a',
      );
    },
  );

  test(
    'explicit policy denial in a successful response purges its owner only',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            ...access,
            'allowed': false,
            'reason': 'traffic_stopped',
          }),
          200,
        ),
      );
      await sync.syncNow();
      expect(policy.active, isFalse);
      expect(await File(saved.configPath).exists(), isFalse);
    },
  );

  test(
    'explicit denial does not require an otherwise usable policy payload',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (_) async =>
            http.Response('{"allowed":false,"reason":"quota_exhausted"}', 200),
      );
      await sync.syncNow();
      expect(policy.active, isFalse);
      expect(await File(saved.configPath).exists(), isFalse);
    },
  );

  test(
    'a denied policy for a different owner cannot purge the old owner',
    () async {
      final saved = VpnConfig.allNodes.single;
      sync.client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            ...access,
            'accountId': 'account-b',
            'allowed': false,
            'reason': 'email_blacklisted',
          }),
          200,
        ),
      );
      await sync.syncNow();
      expect(policy.active, isFalse);
      expect(await File(saved.configPath).exists(), isTrue);
    },
  );

  for (final scenario in ['relogin', 'switch', 'switch-offline']) {
    test(
      '$scenario automatically syncs after login without mixing accounts',
      () async {
        final saved = VpnConfig.allNodes.single;
        final switched = scenario != 'relogin';
        var newRequest = false;
        var retainedBeforeReplacement = false;
        final finished = Completer<void>();
        sync.client = MockClient((request) async {
          final fresh = request.headers['Authorization'] == 'Bearer session-b';
          if (request.url.path.endsWith('/network-access')) {
            return http.Response(
              jsonEncode(
                fresh && switched
                    ? {...access, 'accountId': 'account-b', 'teamId': 'team-b'}
                    : access,
              ),
              200,
            );
          }
          if (request.url.path.endsWith('/nodes')) {
            if (fresh) {
              newRequest = true;
              retainedBeforeReplacement = await File(saved.configPath).exists();
              if (scenario == 'switch-offline') return http.Response('', 503);
            }
            return http.Response(
              jsonEncode(
                fresh && switched
                    ? [
                        {
                          ...nodes.single,
                          'id': 'node-b',
                          'name': 'New account connection',
                        },
                      ]
                    : nodes,
              ),
              200,
            );
          }
          return http.Response('', 404);
        });
        void onSync() {
          if (!sync.syncing.value && newRequest && !finished.isCompleted) {
            finished.complete();
          }
        }

        sync.syncing.addListener(onSync);
        try {
          await sync.init();
          final login = await http.runWithClient(
            () => session.login(
              identifier: switched ? 'other@example' : 'member@example',
              password: 'fixture-only',
            ),
            () => MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'token': 'session-b',
                  'user': {
                    'email': switched ? 'other@example' : 'member@example',
                  },
                }),
                200,
              ),
            ),
          );
          expect(login.success, isTrue);
          await finished.future.timeout(const Duration(seconds: 5));
          expect(retainedBeforeReplacement, isTrue);
          if (scenario == 'switch-offline') {
            expect(VpnConfig.nodes, isEmpty);
            expect(await File(saved.configPath).exists(), isTrue);
          } else {
            expect(
              VpnConfig.nodes.single.managedNodeId,
              switched ? 'node-b' : 'node-a',
            );
            if (switched) {
              expect(await File(saved.configPath).exists(), isFalse);
            }
          }
        } finally {
          sync.syncing.removeListener(onSync);
        }
      },
    );
  }

  test(
    'a changed team cannot restore the previous snapshot after a 503',
    () async {
      sync.client = MockClient(
        (request) async => request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode({...access, 'teamId': 'team-b'}), 200)
            : http.Response('', 503),
      );
      expect((await sync.syncNow()).success, isFalse);
      await session.init();
      expect(policy.active, isFalse);
      expect(VpnConfig.nodes, isEmpty);
    },
  );

  test(
    'cache lifetime is bounded even when the login token remains stored',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final cache = jsonDecode(prefs.getString('network.cachedAccess')!) as Map;
      cache['savedAt'] = DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch;
      await prefs.setString('network.cachedAccess', jsonEncode(cache));
      await session.init();
      expect(session.isLoggedIn, isTrue);
      expect(policy.active, isFalse);
      expect(VpnConfig.nodes, isEmpty);
    },
  );

  test(
    'expired team validity rejects an otherwise fresh offline cache',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final cache = jsonDecode(prefs.getString('network.cachedAccess')!) as Map;
      cache['validUntil'] =
          DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String();
      await prefs.setString('network.cachedAccess', jsonEncode(cache));
      await session.init();
      expect(policy.active, isFalse);
      expect(VpnConfig.nodes, isEmpty);
    },
  );

  test(
    'policy cache contains neither credentials nor connection URIs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('network.cachedAccess')!;
      expect(raw, isNot(contains('test-session')));
      expect(raw, isNot(contains('vless://')));
      expect(raw, isNot(contains('11111111-1111-4111-8111-111111111111')));
    },
  );
}
