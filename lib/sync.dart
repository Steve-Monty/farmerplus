import 'browser_bridge.dart' if (dart.library.html) 'browser_bridge_web.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'background.dart';
import 'account_workspaces.dart';
import 'package:http/http.dart' as http;
import 'http_client.dart' if (dart.library.html) 'http_client_web.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'store.dart';
import 'taxonomy.dart';
import 'phone_reporting.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:url_launcher/url_launcher.dart';

class SyncRequestError extends StateError {
  final int statusCode;
  SyncRequestError(this.statusCode, super.message);
}

class SyncTransportError extends StateError {
  SyncTransportError(super.message);
}

class SyncEngine extends ChangeNotifier with WidgetsBindingObserver {
  static final _active = Expando<SyncEngine>();
  static SyncEngine? activeFor(FarmStore store) => _active[store];
  static final activeTokens = Expando<String>('account session');
  static final accessRejected = ValueNotifier<bool>(false);
  static Future<void>? refreshing;
  final FarmStore store;
  final http.Client client;
  String status = 'Saved on this phone';
  final Map<String, String> itemIssues = {};
  final Map<String, String> issueOperations = {};
  String? token;
  bool busy = false;
  bool credentialChangeInProgress = false;
  Future<void> Function()? beforeLogout;
  int credentialRevision = 0;
  int failures = 0;
  DateTime? retryAfter;
  Timer? timer;
  Timer? queueTimer;
  Timer? recoveryTimer;
  Timer? browserRefreshTimer;
  bool disposed = false;
  bool foreground = true;
  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  bool serverOnline = false, checkingConnection = false;
  String queueSignature = "";
  late final PhoneReporter phoneReporter = PhoneReporter(store);
  Future<void> Function()? afterOnlineLogin;
  Future<void> reportPhone({
    bool explicit = false,
    bool onlineLogin = false,
  }) async {
    if (kIsWeb || !Platform.isAndroid || credentialChangeInProgress) return;
    try {
      final owner = await store.setting('boundOwner'), server = await base();
      if (owner is! String ||
          await store.setting('boundServer') != server ||
          await store.setting('consent') != true) {
        return;
      }
      final mode = await store.setting('syncMode') ?? 'automatic';
      if (mode == 'manual' && !explicit) return;
      final networks = await Connectivity().checkConnectivity();
      if (networks.contains(ConnectivityResult.none) ||
          mode == 'wifi' && !networks.contains(ConnectivityResult.wifi)) {
        return;
      }
      await phoneReporter.report(
        owner: owner,
        server: server,
        forceRetry: explicit,
        captureCurrent: onlineLogin,
        send: (body) => request('POST', '/sync/phone-report', body: body),
      );
    } catch (_) {
      /* Diagnostics must never interrupt startup or record sync. */
    }
  }

  Future<void> onlineLoginReports() async {
    await reportPhone(explicit: true, onlineLogin: true);
    await afterOnlineLogin?.call();
  }

  Future<void> checkConnection() async {
    if (checkingConnection) return;
    checkingConnection = true;
    try {
      final response = await client
          .get(Uri.parse("${await base()}/oidc/config"))
          .timeout(const Duration(seconds: 5));
      serverOnline = response.statusCode == 200;
    } catch (_) {
      serverOnline = false;
    } finally {
      checkingConnection = false;
      notifyListeners();
    }
  }

  void queueChanged() {
    queueTimer?.cancel();
    queueTimer = Timer(const Duration(seconds: 2), () async {
      if (disposed) return;
      final rows = await store.db.query(
        "queue",
        columns: ["op_id"],
        orderBy: "op_id",
      );
      final signature =
          '${rows.map((r) => r["op_id"]).join(":")}:${kIsWeb ? await inventorySignature() : ''}';
      if (signature == queueSignature) return;
      queueSignature = signature;
      if (rows.isEmpty && !await hasPendingInventory()) {
        recoveryTimer?.cancel();
        recoveryTimer = null;
        return;
      }
      scheduleRecoveryProbe();
      await schedulePendingSync(store);
      if (!disposed) await automatic();
    });
  }

  Future<Map<String, dynamic>> reportedSettings() async => {
    for (final key in {
      ...FarmStore.syncedPreferences,
      'preferredMapLayer',
      'activeMapPack',
      'mapEnabled',
      'pushOptIn',
      'backgroundSync',
      'gpsCountry',
    })
      key: await store.setting(key),
    'customWallpaper': await store.setting('wallpaperPhoto') != null,
  };

  Future<String> inventorySignature() async => jsonEncode({
    'version': (await PackageInfo.fromPlatform()).version,
    'build': (await PackageInfo.fromPlatform()).buildNumber,
    'settings': await reportedSettings(),
    'apps': await store.db.query(
      'installs',
      columns: ['id', 'version'],
      where: 'state=?',
      whereArgs: ['ready'],
      orderBy: 'id',
    ),
  });

  Future<bool> hasPendingInventory() async =>
      kIsWeb &&
      await inventorySignature() != await store.setting('lastInventoryReport');

  Future<bool> browserPullDue() async {
    if (!kIsWeb || !foreground) return false;
    final last = DateTime.tryParse(
      await store.setting('lastBrowserPull') ?? '',
    );
    return last == null ||
        DateTime.now().difference(last) >= const Duration(minutes: 5);
  }

  void scheduleRecoveryProbe({Duration delay = const Duration(seconds: 20)}) {
    if (disposed || recoveryTimer?.isActive == true) return;
    recoveryTimer = Timer(delay, () => unawaited(probePendingRecovery()));
  }

  Future<void> probePendingRecovery() async {
    recoveryTimer = null;
    if (disposed) return;
    final pending = (await store.db.query(
      'queue',
      columns: ['id'],
      limit: 1,
    )).isNotEmpty;
    if (!pending && !await hasPendingInventory()) return;
    if (await store.setting('syncMode') == 'manual') return;
    if (!foreground) {
      scheduleRecoveryProbe();
      return;
    }
    await checkConnection();
    if (serverOnline) {
      failures = 0;
      retryAfter = null;
      timer?.cancel();
      timer = null;
      await automatic();
    }
    if (!disposed &&
        (await store.db.query('queue', columns: ['id'], limit: 1)).isNotEmpty) {
      scheduleRecoveryProbe();
    }
  }

  StreamSubscription? connection;
  late final secure = WorkspaceCredentials(store);
  SyncEngine(this.store, {http.Client? client})
    : client = client ?? createHttpClient();
  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _active[store] = this;
    final savedIssues = await store.setting('syncIssues');
    if (savedIssues is Map) {
      for (final entry in savedIssues.entries) {
        if (entry.value is Map && entry.value['message'] is String) {
          itemIssues[entry.key.toString()] = entry.value['message'];
          issueOperations[entry.key.toString()] = entry.value['op_id'] ?? '';
        }
      }
    }
    if (!kIsWeb) {
      final session = await oidcStored();
      token = session?['access_token'] ?? await secure.read(key: 'syncToken');
    }
    if ((await store.setting("syncMode") ?? "automatic") != "manual") {
      await store.setSetting("consent", true);
    }
    store.addListener(queueChanged);
    if ((await store.db.query('queue', columns: ['id'], limit: 1)).isNotEmpty) {
      scheduleRecoveryProbe();
    }
    unawaited(checkConnection());
    connection = Connectivity().onConnectivityChanged.listen((_) {
      retryAfter = null;
      unawaited(checkConnection());
      automatic();
      unawaited(reportPhone());
    });
    unawaited(reportPhone());
    if (kIsWeb) {
      browserRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (foreground && !disposed) unawaited(automatic());
      });
    }
    await automatic();
  }

  Future<void> automatic() async {
    if (disposed || credentialChangeInProgress) return;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter!)) return;
    final mode = await store.setting('syncMode') ?? 'automatic';
    if (mode == 'manual') return;
    // An idle phone must not pull every record or report another successful sync.
    // Initial account restoration and an explicit Sync now can still pull data.
    if ((await store.db.query('queue', columns: ['id'], limit: 1)).isEmpty &&
        !await hasPendingInventory() &&
        !await browserPullDue()) {
      return;
    }
    final networks = await Connectivity().checkConnectivity();
    if (networks.contains(ConnectivityResult.none)) return;
    if (mode == 'wifi' && !networks.contains(ConnectivityResult.wifi)) return;
    await sync(pendingOnly: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (kIsWeb && foreground) unawaited(automatic());
    if (foreground && !disposed) {
      recoveryTimer?.cancel();
      recoveryTimer = null;
      unawaited(probePendingRecovery());
      unawaited(automatic());
      unawaited(reportPhone());
    }
  }

  Future<String> base() async {
    final value =
        (await store.setting('server') ??
                (kIsWeb
                    ? Uri.base.origin
                    : const String.fromEnvironment(
                        'FARMER_SYNC_URL',
                        defaultValue: 'https://app.agritec.earth',
                      )))
            .toString()
            .replaceAll(RegExp(r'/$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw StateError('Enter your sync server in Settings.');
    }
    if (uri.scheme != 'https' &&
        !{'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host)) {
      throw StateError('Use HTTPS for a remote server.');
    }
    return value;
  }

  Future<bool> onlineAvailable() async {
    try {
      return !(await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.none,
      );
    } catch (_) {
      return true;
    }
  }

  Future<dynamic> request(String method, String route, {Object? body}) async {
    if (disposed) throw StateError('This account workspace is closed.');
    final requestRevision = credentialRevision;
    final public = {
      '/auth/login',
      '/auth/native/login',
      '/auth/native/refresh',
      '/auth/register',
      '/auth/recover',
      '/auth/providers',
      '/auth/email/register',
      '/auth/email/login',
      '/auth/email/verification/request',
      '/auth/email/verification/confirm',
      '/auth/email/password/forgot',
      '/auth/email/password/reset',
      '/oidc/config',
    }.contains(route);
    if (!public) {
      if (!kIsWeb && await oidcStored() != null) await refreshOidc();
      token ??= activeTokens[store];
      if (!kIsWeb) token ??= await secure.read(key: 'syncToken');
      final bound = await store.setting('boundServer');
      if (token != null && bound != null && bound != await base()) {
        throw StateError('Sign in to the original account server.');
      }
    }
    final req = http.Request(method, Uri.parse('${await base()}$route'))
      ..followRedirects = false;
    req.headers.addAll({
      'Content-Type': 'application/json',
      if (!kIsWeb && token != null && !public) 'Authorization': 'Bearer $token',
    });
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    ).timeout(const Duration(seconds: 20));
    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw StateError(
        'The service could not return a valid response. Your saved work has been kept.',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (!public &&
          !credentialChangeInProgress &&
          requestRevision == credentialRevision &&
          {401, 403}.contains(res.statusCode) &&
          (route == '/auth/me' || route.startsWith('/sync/'))) {
        accessRejected.value = true;
      }
      throw SyncRequestError(
        res.statusCode,
        decoded['detail']?.toString() ?? 'Server returned ${res.statusCode}',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> emailLogin(String email, String password) async {
    final login = Map<String, dynamic>.from(
      await request(
        'POST',
        '/auth/email/login',
        body: {'email': email, 'password': password},
      ),
    );
    final loginOwner = login['owner']?.toString();
    if (loginOwner == null || loginOwner.isEmpty) {
      throw StateError('The server returned an invalid account session.');
    }

    // The login response establishes the browser cookie and intentionally
    // contains only minimal identifiers. Resolve the canonical account shape
    // from that cookie before binding a durable local workspace.
    final session = Map<String, dynamic>.from(await request('GET', '/auth/me'));
    if (session['owner']?.toString() != loginOwner) {
      throw StateError(
        'The signed-in account did not match the login session.',
      );
    }
    return session;
  }

  Future<void> acceptBrowserSession(Map<String, dynamic> result) async {
    final server = await base();
    final owner = result['owner']?.toString();
    final studentId = result['studentId']?.toString();
    final account = (result['email'] ?? result['username'])?.toString();
    if (owner == null ||
        owner.isEmpty ||
        studentId == null ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(studentId) ||
        account == null ||
        account.isEmpty) {
      throw StateError('The server returned an invalid account session.');
    }
    credentialRevision++;
    token = 'browser-session';
    activeTokens[store] = token;
    await store.setSetting('boundOwner', owner);
    await store.setSetting('boundServer', server);
    await store.setSetting('studentId', studentId);
    await store.setSetting('accountUsername', account);
    await store.setSetting('accountEmail', result['email']);
    credentialRevision++;
    accessRejected.value = false;
    failures = 0;
    retryAfter = null;
    timer?.cancel();
    timer = null;
    status = 'Connected as $account';
    notifyListeners();
    unawaited(automatic());
  }

  Future<Map<String, dynamic>> oidcConfiguration() async {
    final value = Map<String, dynamic>.from(
      await request('GET', '/oidc/config'),
    );
    if (value['enabled'] != true) {
      throw StateError(
        'Single sign-on is being prepared. Saved farm records have been kept.',
      );
    }
    final issuer = Uri.tryParse(value['issuer'] ?? '');
    final staging =
        const String.fromEnvironment('FARMER_ENVIRONMENT') == 'staging';
    final keycloak = value['provider'] == 'keycloak';
    final approved = keycloak
        ? const String.fromEnvironment(
            'FARMER_KEYCLOAK_ISSUER',
            defaultValue: 'https://auth.agritec.earth/realms/farmerplus',
          )
        : staging
        ? 'https://identity.farmerplus.test'
        : 'https://identity.agritec.earth';
    if (issuer == null ||
        issuer.scheme != 'https' ||
        issuer.toString() != approved ||
        issuer.hasPort ||
        issuer.userInfo.isNotEmpty ||
        issuer.hasQuery ||
        issuer.hasFragment) {
      throw StateError(
        'The configured sign-in provider does not match this build.',
      );
    }
    return value;
  }

  Future<Map<String, dynamic>?> oidcStored() async {
    if (kIsWeb) return null;
    final value = await secure.read(key: 'farmerplus.oidc.session');
    if (value == null) return null;
    return Map<String, dynamic>.from(jsonDecode(value));
  }

  Future<Map<String, dynamic>?> beginOidc() async {
    final config = await oidcConfiguration();
    if (kIsWeb) {
      final signIn = Uri.parse(config['webSignIn']);
      if (signIn.origin != await base() || signIn.path != '/oidc/web/login') {
        throw StateError('The sign-in address was not accepted.');
      }
      if (!await launchUrl(signIn, webOnlyWindowName: '_self')) {
        throw StateError('Could not open sign-in.');
      }
      return null;
    }
    final random = Random.secure();
    final nonce = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    AuthorizationTokenResponse result;
    try {
      result = await const FlutterAppAuth().authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          config['androidClientId'],
          config['androidRedirect'],
          issuer: config['issuer'],
          nonce: nonce,
          scopes: const [
            'openid',
            'profile',
            'farmerplus.identity',
            'farm:read',
            'farm:write',
            'learning:courses:read',
            'learning:content:read',
            'offline_access',
          ],
          additionalParameters: const {
            'audience': 'farmerplus-api farmerplus-learning-api',
          },
        ),
      );
    } catch (_) {
      throw StateError(
        'Sign-in was cancelled or could not finish. Open sign-in to try again.',
      );
    }
    if (result.accessToken == null ||
        result.idToken == null ||
        result.accessTokenExpirationDateTime == null) {
      throw StateError('Sign-in did not return a complete session.');
    }
    final candidate = result.accessToken!;
    // Do not interpret unverified JWT claims. The server uses Authlib/JWKS to
    // validate the ID token, nonce and access-token binding before local adoption.
    final verifyRequest =
        http.Request('POST', Uri.parse('${await base()}/oidc/native/verify'))
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $candidate',
          })
          ..body = jsonEncode({'id_token': result.idToken, 'nonce': nonce});
    final verified = await http.Response.fromStream(
      await client.send(verifyRequest).timeout(const Duration(seconds: 25)),
    );
    if (verified.statusCode != 200) {
      throw StateError(
        'Sign-in could not be verified. No saved records were reassigned.',
      );
    }
    final meRequest = http.Request('GET', Uri.parse('${await base()}/auth/me'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $candidate';
    final response = await http.Response.fromStream(
      await client.send(meRequest).timeout(const Duration(seconds: 25)),
    );
    if (response.statusCode != 200) {
      throw StateError('The account is not available.');
    }
    final me = Map<String, dynamic>.from(jsonDecode(response.body));
    if (jsonDecode(verified.body)['farmerplusId'] != me['studentId']) {
      throw StateError('The account identity did not match.');
    }
    return {
      ...me,
      'oidcSession': {
        'access_token': candidate,
        'refresh_token': result.refreshToken,
        'expires': result.accessTokenExpirationDateTime!
            .toUtc()
            .millisecondsSinceEpoch,
        'issuer': config['issuer'],
        'client': config['androidClientId'],
        'redirect': config['androidRedirect'],
        'server': await base(),
        'farmerplusId': me['studentId'],
      },
    };
  }

  Future<void> acceptOidc(Map<String, dynamic> result) async {
    final bound = await store.setting('boundOwner');
    final server = await base();
    if (bound != null &&
        (bound != result['owner'] ||
            await store.setting('boundServer') != server)) {
      throw StateError(
        'Sign in to this device’s original account. Its records cannot be reassigned.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(result['studentId'] ?? '')) {
      throw StateError('Invalid permanent account identifier.');
    }
    credentialRevision++;
    if (!kIsWeb) {
      final session = Map<String, dynamic>.from(result['oidcSession']);
      await secure.write(
        key: 'farmerplus.oidc.session',
        value: jsonEncode(session),
      );
      await secure.delete(key: 'syncToken');
      token = session['access_token'];
    } else {
      token = 'browser-session';
    }
    activeTokens[store] = token;
    await store.setSetting('boundOwner', result['owner']);
    await store.setSetting('boundServer', server);
    await store.setSetting('studentId', result['studentId']);
    await store.setSetting('accountUsername', result['username']);
    credentialRevision++;
    accessRejected.value = false;
    status = 'Connected as ${result['username']}';
    notifyListeners();
  }

  Future<Map<String, dynamic>> nativeLogin(
    String username,
    String password,
  ) async {
    final result = Map<String, dynamic>.from(
      await request(
        'POST',
        '/auth/native/login',
        body: {'username': username.trim(), 'password': password},
      ),
    );
    final session = Map<String, dynamic>.from(result['oidcSession'] ?? {});
    if (result['admin'] != false ||
        result['verified'] != true ||
        session['kind'] != 'native' ||
        session['server'] != await base() ||
        session['access_token'] is! String ||
        session['refresh_token'] is! String ||
        session['expires'] is! int) {
      throw StateError('Farmer sign-in could not be verified.');
    }
    return result;
  }

  Future<void> refreshOidc() async {
    if (kIsWeb) return;
    final pending = refreshing;
    if (pending != null) {
      await pending;
      token = (await oidcStored())?['access_token'];
      return;
    }
    final completer = Completer<void>();
    refreshing = completer.future;
    RandomAccessFile? lease;
    try {
      lease = await File(
        path.join(store.filesPath, 'oidc-refresh.lock'),
      ).open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      final session = await oidcStored();
      if (session == null) return;
      if (session['server'] != await base()) {
        throw StateError('Sign in to the original account server.');
      }
      if ((session['expires'] as int) >
          DateTime.now().toUtc().millisecondsSinceEpoch + 30000) {
        token = session['access_token'];
        return;
      }
      if (session['refresh_token'] == null) {
        accessRejected.value = true;
        throw StateError('Open sign-in to renew your account access.');
      }
      if (session['kind'] == 'native') {
        // Persist the nonce before sending: an interrupted response can safely
        // retry the same rotation without using the old refresh token twice.
        session['refreshRequest'] ??= base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        );
        await secure.write(
          key: 'farmerplus.oidc.session',
          value: jsonEncode(session),
        );
        try {
          final result = Map<String, dynamic>.from(
            await request(
              'POST',
              '/auth/native/refresh',
              body: {
                'refresh_token': session['refresh_token'],
                'request_id': session['refreshRequest'],
              },
            ),
          );
          if (result['kind'] != 'native' ||
              result['server'] != session['server'] ||
              result['client'] != session['client'] ||
              result['access_token'] is! String ||
              result['expires'] is! int) {
            throw StateError('Account access could not be renewed.');
          }
          await secure.write(
            key: 'farmerplus.oidc.session',
            value: jsonEncode(result),
          );
          token = result['access_token'];
          activeTokens[store] = token;
        } on SyncRequestError catch (e) {
          if ({401, 403}.contains(e.statusCode)) {
            accessRejected.value = true;
            await secure.delete(key: 'farmerplus.oidc.session');
            token = null;
            activeTokens[store] = null;
          }
          rethrow;
        }
        return;
      }
      TokenResponse result;
      try {
        result = await const FlutterAppAuth().token(
          TokenRequest(
            session['client'],
            session['redirect'],
            issuer: session['issuer'],
            refreshToken: session['refresh_token'],
          ),
        );
      } on FlutterAppAuthPlatformException catch (e) {
        if ({
          'invalid_grant',
          'invalid_client',
          'unauthorized_client',
          'invalid_scope',
        }.contains(e.platformErrorDetails.error)) {
          await secure.delete(key: 'farmerplus.oidc.session');
          await secure.delete(key: 'farmer.access.owner');
          await secure.delete(key: 'farmer.access.until');
          token = null;
          activeTokens[store] = null;
          accessRejected.value = true;
          throw SyncRequestError(
            401,
            'Account access has ended. Sign in again. Your records have been kept.',
          );
        }
        throw SyncTransportError(
          'Connect to renew your sign-in. Your saved records have been kept.',
        );
      } catch (_) {
        throw SyncTransportError(
          'Connect to renew your sign-in. Your saved records have been kept.',
        );
      }
      if (result.accessToken == null ||
          result.accessTokenExpirationDateTime == null) {
        throw StateError('Account access could not be renewed.');
      }
      session['access_token'] = result.accessToken;
      session['refresh_token'] =
          result.refreshToken ?? session['refresh_token'];
      session['expires'] = result.accessTokenExpirationDateTime!
          .toUtc()
          .millisecondsSinceEpoch;
      await secure.write(
        key: 'farmerplus.oidc.session',
        value: jsonEncode(session),
      );
      token = result.accessToken;
      activeTokens[store] = token;
    } finally {
      try {
        await lease?.unlock();
      } catch (_) {}
      await lease?.close();
      completer.complete();
      refreshing = null;
    }
  }

  Future<void> login(String username, String password) async {
    final r = await request(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password},
    );
    await acceptSession(r, username);
  }

  Future<void> exchangeLearning(String learningToken) async {
    final r = await request(
      'POST',
      '/auth/moodle',
      body: {'token': learningToken},
    );
    await acceptSession(r, 'Learning account');
  }

  Future<void> acceptSession(dynamic r, String username) async {
    final owner = r['owner'] as String;
    final bound = await store.setting('boundOwner');
    final server = await base();
    final boundServer = await store.setting('boundServer');
    if (bound != null && (bound != owner || boundServer != server)) {
      throw StateError(
        'This phone is linked to a different account or server. Its records cannot be uploaded to another account.',
      );
    }
    token = r['token'];
    activeTokens[store] = token;
    if (!kIsWeb) await secure.write(key: 'syncToken', value: token);
    await store.setSetting('boundOwner', owner);
    await store.setSetting('boundServer', server);
    status = 'Connected as $username';
    notifyListeners();
  }

  Future<void> logout() async {
    await beforeLogout?.call();
    var remoteDone = false;
    String? endSessionUrl;
    try {
      if ((token != null || kIsWeb) &&
          await base() == await store.setting('boundServer')) {
        final result = await request('POST', '/auth/logout');
        if (kIsWeb &&
            result is Map &&
            result['endSessionUrl'] == '/oidc/logout') {
          endSessionUrl = '/oidc/logout';
        }
        remoteDone = true;
      }
    } catch (_) {
      // Offline sign-out still removes the local credential. Server sessions expire.
    }
    await clearLocalSession();
    await store.setSetting('remoteSignOutPending', !remoteDone);
    status = remoteDone
        ? 'Signed out • remote sessions revalidate online'
        : 'Signed out on this device • remote sign-out could not be confirmed';
    notifyListeners();
    if (endSessionUrl != null) browserAssign(endSessionUrl);
  }

  Future<void> clearLocalSession() async {
    credentialRevision++;
    token = null;
    activeTokens[store] = null;
    accessRejected.value = false;
    if (!kIsWeb) {
      await secure.delete(key: 'syncToken');
      await secure.delete(key: 'farmerplus.oidc.session');
    }
  }

  Future<void> sync({Set<String>? recordIds, bool pendingOnly = false}) async {
    if (busy) return;
    if (token == null && !kIsWeb) {
      status = 'Sign in to sync. Your saved work is kept on this phone.';
      notifyListeners();
      return;
    }
    if (await store.setting('consent') != true) {
      status = 'Sync is paused. Your saved work is kept on this phone.';
      notifyListeners();
      return;
    }
    busy = true;
    status = 'Synchronising…';
    notifyListeners();
    RandomAccessFile? lease;
    try {
      if (!kIsWeb) {
        lease = await File(
          path.join(store.filesPath, 'sync.lock'),
        ).open(mode: FileMode.append);
        await lease.lock(FileLock.exclusive);
      }
      if (await store.setting('syncMode') == 'wifi' &&
          !(await Connectivity().checkConnectivity()).contains(
            ConnectivityResult.wifi,
          )) {
        throw StateError('Waiting for Wi-Fi as requested in Settings.');
      }
      if (await base() != await store.setting('boundServer')) {
        throw StateError('Sign in again after changing the server.');
      }
      final queue = List<Map<String, Object?>>.from(
        await store.db.query('queue'),
      );
      if (pendingOnly &&
          queue.isEmpty &&
          !await hasPendingInventory() &&
          !await browserPullDue())
        return;
      final currentOps = {for (final op in queue) op['id']: op['op_id']};
      itemIssues.removeWhere((id, _) => currentOps[id] != issueOperations[id]);
      issueOperations.removeWhere((id, _) => !itemIssues.containsKey(id));
      if (recordIds != null) {
        final selected = Set<String>.from(recordIds);
        final byId = {for (final r in queue) r['id'] as String: r};
        void dependencies(dynamic value) {
          if (value is String &&
              byId.containsKey(value) &&
              selected.add(value)) {
            dependencies(jsonDecode(byId[value]!['data'] as String));
          } else if (value is Map) {
            for (final v in value.values) {
              dependencies(v);
            }
          } else if (value is List) {
            for (final v in value) {
              dependencies(v);
            }
          }
        }

        for (final id in recordIds) {
          if (byId[id] != null) {
            dependencies(jsonDecode(byId[id]!['data'] as String));
          }
        }
        queue.removeWhere((r) => !selected.contains(r['id']));
      }
      int rank(dynamic r) => r['deleted'] == true || r['deleted'] == 1
          ? (r['kind'] == 'farm' ? 3 : 0)
          : (r['kind'] == 'farm' ? 1 : 2);
      queue.sort((a, b) => rank(a).compareTo(rank(b)));
      final pending = List<Map<String, Object?>>.from(queue);
      final syncDevice = await store.setting('deviceId') ?? const Uuid().v4();
      await store.setSetting('deviceId', syncDevice);
      String? pendingIssue;
      for (var pass = 0; pass <= queue.length && pending.isNotEmpty; pass++) {
        final before = pending.length;
        for (final op in List<Map<String, Object?>>.from(pending)) {
          if (await store.setting('consent') != true ||
              (token == null && !kIsWeb)) {
            break;
          }
          final data = jsonDecode(op['data'] as String);
          dynamic result;
          try {
            await store.validateGeometry(
              store.db,
              op['id'] as String,
              op['kind'] as String,
              Map<String, dynamic>.from(data),
              op['deleted'] == 1,
            );
            for (final media in (data['media'] as List? ?? [])) {
              await upload(media['hash']);
            }
            result = await request(
              'POST',
              '/sync/push',
              body: {
                ...op,
                'data': data,
                'deleted': op['deleted'] == 1,
                'sourceAppId': owningApp(op['kind'] as String),
                'deviceId': syncDevice,
              },
            );
          } on SyncRequestError catch (e) {
            if (!{400, 404, 409, 413, 422}.contains(e.statusCode)) rethrow;
            pendingIssue = e.message;
            itemIssues[op['id'] as String] = e.message;
            issueOperations[op['id'] as String] = op['op_id'] as String;
            continue;
          } on SyncTransportError {
            rethrow;
          } on StateError catch (e) {
            pendingIssue = e.message.toString();
            itemIssues[op['id'] as String] = pendingIssue;
            issueOperations[op['id'] as String] = op['op_id'] as String;
            continue;
          }
          pending.remove(op);
          itemIssues.remove(op['id']);
          issueOperations.remove(op['id']);
          if (result['conflict'] == true) {
            await store.db.insert('conflicts', {
              'id': op['id'],
              'remote': jsonEncode(result['record']),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          } else {
            await store.acknowledge(op, result['record']['version']);
          }
        }
        if (pending.length == before) break;
      }
      final pulled = await request('GET', '/sync/pull');
      final incoming = List<dynamic>.from(pulled['records']);
      final receivedInboxIds = <String>[];
      incoming.sort((a, b) => rank(a).compareTo(rank(b)));
      for (final r in incoming) {
        final ownerApp = owningApp(r['kind']);
        if (ownerApp != null &&
            await store.setting('removedApp:$ownerApp') == true) {
          continue;
        }
        final local = await store.get(r['id']);
        if (local == null || r['version'] > local['version']) {
          await store.incoming(Map<String, dynamic>.from(r));
        }
        final accepted = await store.get(r['id']);
        if (accepted != null && accepted['version'] == r['version']) {
          if (r['kind'] == 'inbox' && r['deleted'] != true) {
            receivedInboxIds.add(r['id'] as String);
          }
          for (final media in (accepted['data']['media'] as List? ?? [])) {
            await download(media['hash']);
          }
        }
      }
      final conflicts = await store.db.query('conflicts');
      if (kIsWeb)
        await store.setSetting(
          'lastBrowserPull',
          DateTime.now().toUtc().toIso8601String(),
        );
      final completedAt = DateTime.now().toUtc().toIso8601String();
      final remaining = (await store.db.query('queue')).length;
      if (conflicts.isEmpty && remaining == 0) {
        await store.setSetting('lastSync', completedAt);
      }
      {
        try {
          final inventorySnapshot = await inventorySignature();
          final info = await PackageInfo.fromPlatform();
          final device = await store.setting('deviceId') ?? const Uuid().v4();
          await store.setSetting('deviceId', device);
          final installedApps = <Map<String, dynamic>>[];
          for (final item in await store.db.query(
            'installs',
            where: 'state=?',
            whereArgs: ['ready'],
          )) {
            if (await store.ready(item['id'] as String)) {
              installedApps.add({'id': item['id'], 'version': item['version']});
            }
          }
          for (
            var offset = 0;
            offset < receivedInboxIds.length || offset == 0;
            offset += 2000
          ) {
            await request(
              'POST',
              '/sync/complete',
              body: {
                'device': device,
                'version': '${info.version}+${info.buildNumber}',
                if (kIsWeb) 'browser': browserCapabilities(),
                'installedApps': installedApps,
                'settings': await reportedSettings(),
                'pendingChanges': remaining,
                'conflicts': conflicts.length,
                'receivedInboxIds': receivedInboxIds
                    .skip(offset)
                    .take(2000)
                    .toList(),
              },
            );
          }
          await store.setSetting('lastDeviceReport', completedAt);
          if (kIsWeb)
            await store.setSetting('lastInventoryReport', inventorySnapshot);
        } catch (_) {
          /* Reporting must not turn successfully saved records into failed saves. */
          if (kIsWeb) scheduleRecoveryProbe();
        }
      }
      if (pending.isNotEmpty) {
        throw StateError(pendingIssue ?? 'Some changes still need sync.');
      }
      status = conflicts.isEmpty
          ? (remaining == 0
                ? 'Synced'
                : 'Pending — $remaining changes saved on this phone')
          : '${conflicts.length} conflict(s) need your choice';
      failures = 0;
      retryAfter = null;
    } catch (e) {
      failures = (failures + 1).clamp(1, 7);
      retryAfter = DateTime.now().add(
        Duration(seconds: (15 * (1 << failures)).clamp(30, 900)),
      );
      status =
          'Sync failed — saved on this phone. ${e.toString().replaceFirst('Bad state: ', '')}';
      timer?.cancel();
      timer = Timer(retryAfter!.difference(DateTime.now()), () {
        if (!disposed) unawaited(automatic());
      });
      scheduleRecoveryProbe();
    } finally {
      try {
        final current = {
          for (final op in await store.db.query('queue')) op['id']: op['op_id'],
        };
        itemIssues.removeWhere((id, _) => current[id] != issueOperations[id]);
        await store.setSetting('syncIssues', {
          for (final entry in itemIssues.entries)
            entry.key: {
              'op_id': issueOperations[entry.key],
              'message': entry.value,
            },
        });
      } catch (_) {
        /* Queue records remain authoritative if status cannot be saved. */
      }
      try {
        await lease?.unlock();
      } catch (_) {}
      await lease?.close();
      busy = false;
      notifyListeners();
      unawaited(reportPhone(explicit: true));
      // Edits made during an upload must not wait for another connectivity event.
      if (failures == 0 &&
          (await store.db.query('queue', limit: 1)).isNotEmpty) {
        queueSignature = '';
        queueChanged();
      }
    }
  }

  Future<void> upload(String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw StateError('Invalid attachment identifier.');
    }
    final file = File(path.join(store.filesPath, 'media', hash));
    if (!await file.exists()) {
      throw StateError('An attachment is missing on this phone.');
    }
    if (await file.length() > 25 * 1024 * 1024) {
      throw StateError(
        'Attachments above 25 MB are not supported in this build.',
      );
    }
    final bytes = await file.readAsBytes();
    final state = await request('GET', '/media/$hash/status');
    var offset = state['bytes'] as int;
    if (offset < 0 || offset > bytes.length) {
      throw StateError('Invalid server attachment offset.');
    }
    while (offset < bytes.length) {
      final end = (offset + 128 * 1024).clamp(0, bytes.length);
      final r = await request(
        'PUT',
        '/media/$hash',
        body: {
          'offset': offset,
          'total': bytes.length,
          'chunk': base64Encode(bytes.sublist(offset, end)),
        },
      );
      if (r['bytes'] <= offset || r['bytes'] > bytes.length) {
        throw StateError('Attachment upload made no valid progress.');
      }
      offset = r['bytes'];
      status = 'Uploading attachment $offset / ${bytes.length} bytes';
      notifyListeners();
    }
  }

  Future<void> download(String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw StateError('Invalid attachment identifier.');
    }
    final dir = Directory(path.join(store.filesPath, 'media'));
    await dir.create(recursive: true);
    final finalFile = File(path.join(dir.path, hash));
    if (await finalFile.exists()) {
      if (sha256.convert(await finalFile.readAsBytes()).toString() == hash) {
        return;
      }
      await finalFile.delete();
    }
    final part = File('${finalFile.path}.partial');
    var offset = await part.exists() ? await part.length() : 0;
    while (true) {
      final result = await request('GET', '/media/$hash?offset=$offset');
      final bytes = base64Decode(result['chunk']);
      if (result['total'] > 25 * 1024 * 1024 ||
          result['total'] < offset ||
          (bytes.isEmpty && offset < result['total'])) {
        throw StateError('Invalid attachment download response.');
      }
      await part.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      offset += bytes.length;
      if (offset >= result['total']) break;
    }
    if (sha256.convert(await part.readAsBytes()).toString() != hash) {
      await part.delete();
      throw StateError('Attachment integrity check failed. Retry sync.');
    }
    await part.rename(finalFile.path);
  }

  @override
  void dispose() {
    disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_active[store], this)) _active[store] = null;
    store.removeListener(queueChanged);
    queueTimer?.cancel();
    timer?.cancel();
    recoveryTimer?.cancel();
    browserRefreshTimer?.cancel();
    connection?.cancel();
    client.close();
    super.dispose();
  }
}
