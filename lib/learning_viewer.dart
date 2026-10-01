import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'learning_loading.dart';
import 'learning_webview.dart';
import 'store.dart';
import 'sync.dart';

bool isLearningContentPage(Uri endpoint, String destination) {
  final url = Uri.tryParse(destination);
  return url != null &&
      url.scheme == 'https' &&
      url.origin == endpoint.origin &&
      url.path != endpoint.path &&
      learningNavigationIssue(endpoint, destination, isMainFrame: true) == null;
}

String? learningNavigationIssue(
  Uri endpoint,
  String destination, {
  required bool isMainFrame,
}) {
  if (!isMainFrame && destination == 'about:blank') return null;
  final url = Uri.tryParse(destination);
  if (url == null ||
      url.scheme != 'https' ||
      !url.hasAuthority ||
      url.origin != endpoint.origin ||
      url.userInfo.isNotEmpty) {
    return 'This link is outside Learning. Return to your lesson.';
  }
  if ({
    '/login/index.php',
    '/auth/farmerplusoidc/login.php',
    '/auth/farmerplusoidc/reauthenticate.php',
  }.contains(url.path)) {
    return 'Your Learning session needs to be renewed. Tap Retry.';
  }
  return null;
}

class LearningViewer extends StatefulWidget {
  final FarmStore store;
  final Uri endpoint;
  final int? cmid;
  const LearningViewer({
    super.key,
    required this.store,
    required this.endpoint,
    this.cmid,
  });
  @override
  State<LearningViewer> createState() => _LearningViewerState();
}

class _LearningViewerState extends State<LearningViewer> {
  final loading = LearningLoading();
  WebViewController? controller;
  bool preparing = false;
  @override
  void initState() {
    super.initState();
    loading.addListener(changed);
    unawaited(load());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    loading.removeListener(changed);
    loading.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (preparing && loading.error == null) return;
    preparing = true;
    final attempt = loading.begin();
    setState(() => controller = null);
    final sync = SyncEngine(widget.store);
    bool current() => mounted && loading.accepts(attempt);
    try {
      await WebViewCookieManager().clearCookies();
      if (!current()) return;
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      Uri mainUrl = widget.endpoint;
      await web.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            final started = Uri.tryParse(url);
            if (started == null ||
                started.scheme != 'https' ||
                started.origin != widget.endpoint.origin) {
              return;
            }
            mainUrl = started;
            loading.pageStarted(attempt);
          },
          onPageFinished: (url) async {
            final completed = Uri.tryParse(url);
            if (!isLearningContentPage(widget.endpoint, url) ||
                completed != mainUrl) {
              return;
            }
            // A valid, current, same-origin main-frame completion is the
            // readiness signal. Some Android WebView providers render the
            // page but never answer evaluateJavascript; treating that bridge
            // timeout as a page failure hides a usable lesson.
            if (current() && mainUrl == completed) loading.finish(attempt);
          },
          onProgress: (value) => loading.updateProgress(attempt, value),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              loading.fail(
                attempt,
                'Learning could not be reached. Check your connection and tap Retry. Saved lessons remain available.',
              );
            }
          },
          onHttpError: (error) {
            // A missing image must not hide a usable lesson. The plugin exposes
            // the request URL, but not a portable main-frame flag for HTTP errors.
            if (error.request?.uri == mainUrl) {
              loading.fail(
                attempt,
                'Learning could not open this page. Tap Retry, or return to your saved lessons.',
              );
            }
          },
          onNavigationRequest: (request) {
            if (!current()) return NavigationDecision.prevent;
            final issue = learningNavigationIssue(
              widget.endpoint,
              request.url,
              isMainFrame: request.isMainFrame,
            );
            if (issue != null) {
              if (request.isMainFrame) loading.fail(attempt, issue);
              return NavigationDecision.prevent;
            }
            if (request.isMainFrame) mainUrl = Uri.parse(request.url);
            return NavigationDecision.navigate;
          },
        ),
      );
      if (!current()) return;
      setState(() => controller = web);
      // Attach the native surface before the authentication redirect starts.
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return;
      final handoff = await sync.request(
        'POST',
        '/learning/native-launch',
        body: {'cmid': widget.cmid},
      );
      if (!current()) return;
      if (handoff['url'] != widget.endpoint.toString() ||
          handoff['ticket'] is! String) {
        throw StateError('Learning returned an unexpected destination.');
      }
      // Only the single-use ticket enters the viewer, never the app's token.
      await web.loadRequest(
        widget.endpoint,
        method: LoadRequestMethod.post,
        body: Uint8List.fromList(
          utf8.encode('ticket=${Uri.encodeQueryComponent(handoff['ticket'])}'),
        ),
      );
    } catch (error) {
      loading.fail(
        attempt,
        error is SyncRequestError
            ? error.message
            : 'Learning could not be opened. Check your connection and tap Retry. Your saved work is unchanged.',
      );
    } finally {
      sync.client.close();
      if (loading.owns(attempt)) preparing = false;
      if (mounted) setState(() {});
    }
  }

  Widget viewer(WebViewController web) {
    return learningWebView(web);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Learning'),
      actions: [
        IconButton(
          tooltip: 'Renew Learning',
          onPressed: preparing && loading.error == null ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          // Keep the native view's position stable as loading completes.
          SizedBox(
            height: 4,
            child: loading.loading && loading.error == null
                ? LinearProgressIndicator(
                    value: loading.progress == 0
                        ? null
                        : loading.progress / 100,
                  )
                : null,
          ),
          Expanded(
            child: loading.error != null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_outlined, size: 36),
                          const SizedBox(height: 16),
                          Text(loading.error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: preparing && loading.error == null
                                ? null
                                : load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Back to My Learning'),
                          ),
                        ],
                      ),
                    ),
                  )
                : controller != null
                ? viewer(controller!)
                : const Center(child: Text('Opening your Learning…')),
          ),
        ],
      ),
    ),
  );
}
