import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/learning_loading.dart';
import 'package:farmerplus_mobile/learning_viewer.dart';

void main() {
  test(
    'intermediate handoff and blank pages do not count as loaded content',
    () {
      final endpoint = Uri.parse(
        'https://learn.agritec.earth/auth/farmerplusoidc/native.php',
      );
      expect(isLearningContentPage(endpoint, endpoint.toString()), false);
      expect(isLearningContentPage(endpoint, 'about:blank'), false);
      expect(
        isLearningContentPage(
          endpoint,
          'https://learn.agritec.earth/login/index.php',
        ),
        false,
      );
      expect(
        isLearningContentPage(
          endpoint,
          'https://learn.agritec.earth/my/courses.php',
        ),
        true,
      );
      expect(
        isLearningContentPage(
          endpoint,
          'https://learn.agritec.earth/mod/page/view.php?id=32',
        ),
        true,
      );
    },
  );
  test(
    'Learning navigation keeps sign-in and unrelated sites out of the viewer',
    () {
      final endpoint = Uri.parse(
        'https://learn.agritec.earth/auth/farmerplusoidc/native.php',
      );
      for (final url in [
        'https://learn.agritec.earth.evil.example/my/',
        'https://learn.agritec.earth@evil.example/',
        'http://learn.agritec.earth/my/',
        'javascript:alert(1)',
        'about:blank',
        'https://learn.agritec.earth/login/index.php',
        'https://learn.agritec.earth/auth/farmerplusoidc/reauthenticate.php',
      ]) {
        expect(
          learningNavigationIssue(endpoint, url, isMainFrame: true),
          isNotNull,
        );
      }
      expect(
        learningNavigationIssue(
          endpoint,
          'https://learn.agritec.earth/my/courses.php',
          isMainFrame: true,
        ),
        isNull,
      );
      expect(
        learningNavigationIssue(endpoint, 'about:blank', isMainFrame: false),
        isNull,
      );
    },
  );
  testWidgets('a stalled page times out even after reaching 100 percent', (
    t,
  ) async {
    final state = LearningLoading();
    final attempt = state.begin();
    state.updateProgress(attempt, 100);
    await t.pump(const Duration(seconds: 46));
    expect(state.loading, false);
    expect(state.error, contains('Retry'));
    state.finish(attempt);
    expect(state.error, isNotNull);
    state.dispose();
  });

  testWidgets('retry ignores late success and failure from an earlier viewer', (
    t,
  ) async {
    final state = LearningLoading();
    final old = state.begin();
    state.fail(old, 'Unavailable');
    final fresh = state.begin();
    state.finish(old);
    state.fail(old, 'Old failure');
    expect(state.loading, true);
    expect(state.error, isNull);
    state.finish(fresh);
    await t.pump(const Duration(minutes: 1));
    expect(state.loading, false);
    expect(state.error, isNull);
    state.dispose();
  });

  testWidgets('later course navigation receives its own bounded load', (
    t,
  ) async {
    final state = LearningLoading();
    final attempt = state.begin();
    state.finish(attempt);
    await t.pump(const Duration(minutes: 1));
    state.pageStarted(attempt);
    await t.pump(const Duration(seconds: 46));
    expect(state.error, isNotNull);
    state.dispose();
  });

  testWidgets('leaving Learning cancels the timeout and ignores callbacks', (
    t,
  ) async {
    final state = LearningLoading();
    final attempt = state.begin();
    state.dispose();
    state.finish(attempt);
    await t.pump(const Duration(minutes: 1));
    expect(t.takeException(), isNull);
  });
}
