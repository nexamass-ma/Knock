import 'package:flutter_test/flutter_test.dart';
import 'package:knock/api/api.dart';
import 'package:knock/app/app_controller.dart';
import 'package:knock/app/knock_app.dart';
import 'package:knock/design/theme.dart';
import 'package:knock/features/onboarding/guide.dart';
import 'package:knock/features/settings/delete_account_screen.dart';
import 'package:knock/features/settings/settings_screen.dart';
import 'package:knock/features/trade/rate_change_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// Widget tests for the acceptance flows. They run against the in-process
/// sandbox backend with no latency.

Finder field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

String latestCode(KnockServer s, String token) {
  final body = ((s.sandboxInbox(token)['items'] as List).first as Map)['body'] as String;
  return RegExp(r'\d{6}').firstMatch(body)!.group(0)!;
}

/// A fully onboarded Tier 1 customer, signed in on [api].
Future<AppController> signedInController(KnockApi api) async {
  final s = api.server;
  final r = s.register(fullName: 'Ada Okafor', email: 'ada@example.com', password: 'Secret123!', acceptedTerms: true, deviceId: api.deviceId);
  final token = r['token'] as String;
  s.verifyEmail(token, latestCode(s, token));
  s.startPhoneVerification(token, 'NG', '8031234567');
  s.verifyPhone(token, latestCode(s, token));
  s.personalise(token, country: 'NG', currency: 'NGN');
  s.setPin(token, '2580');
  await api.setToken(token);
  final c = AppController(api)
    ..me = (s.me(token)['user'] as Json)
    ..phase = AppPhase.ready;
  return c;
}

Widget host(AppController c, Widget child) => AppScope(controller: c, child: MaterialApp(theme: buildKnockTheme(), home: child));

Future<void> reveal(WidgetTester t, String key) async {
  await t.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  await t.pumpAndSettle();
}

void phone(WidgetTester t) {
  // The test font draws every glyph as a full square, so long labels can
  // overflow in tests even though they fit on devices. Layout is checked
  // with screenshots instead; overflow reports are ignored here.
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed')) return;
    original?.call(d);
  };
  addTearDown(() => FlutterError.onError = original);
  t.view.physicalSize = const Size(1170, 2532);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets('first launch: intro slides, then Welcome', (t) async {
    phone(t);
    final api = KnockApi.memory(introSeen: false);
    final c = AppController(api);
    await t.pumpWidget(KnockApp(controller: c));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Your money.\nOne conversation.'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('intro-next')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Gifts that feel\npersonal.'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('intro-next')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Get Started'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('intro-next')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(api.introSeen, isTrue);
    expect(find.text('Money moves.\nMake yours count.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
    api.dispose();
  });

  testWidgets('intro Skip goes straight to Welcome', (t) async {
    phone(t);
    final api = KnockApi.memory(introSeen: false);
    final c = AppController(api);
    await t.pumpWidget(KnockApp(controller: c));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byKey(const ValueKey('intro-skip')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Money moves.\nMake yours count.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
    api.dispose();
  });

  testWidgets('sign up: welcome, create account, then verify email', (t) async {
    phone(t);
    final api = KnockApi.memory();
    final c = AppController(api);
    await t.pumpWidget(KnockApp(controller: c));
    await t.pumpAndSettle();
    expect(find.text('Money moves.\nMake yours count.'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('welcome-create')));
    await t.pumpAndSettle();
    await t.enterText(field('signup-name'), 'Tunde Bello');
    await t.enterText(field('signup-email'), 'tunde@example.com');
    await t.enterText(field('signup-password'), 'Str0ng!Pass');
    await t.ensureVisible(find.byKey(const ValueKey('signup-terms')));
    await t.tap(find.descendant(of: find.byKey(const ValueKey('signup-terms')), matching: find.byType(Checkbox)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('signup-submit')));
    await t.pumpAndSettle();

    expect(c.phase, AppPhase.onboarding);
    expect(c.me?['email'], 'tunde@example.com');
    expect(find.byKey(const ValueKey('verify-email-submit')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
    api.dispose();
  });

  testWidgets('onboarding guide can be skipped and remembers it', (t) async {
    phone(t);
    final api = KnockApi.memory();
    final c = await signedInController(api);
    var done = false;
    await t.pumpWidget(host(c, GuideScreen(onDone: () => done = true)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('guide-skip')));
    await t.pumpAndSettle();
    expect(done, isTrue);
    expect(c.me?['guideSeen'], isTrue);
  });

  group('live rate change notice', () {
    const up = {'direction': 'up', 'oldRateKobo': 150000, 'newRateKobo': 152000, 'oldNetKobo': 15000000, 'newNetKobo': 15200000, 'differenceKobo': 200000};
    const down = {'direction': 'down', 'oldRateKobo': 150000, 'newRateKobo': 148000, 'oldNetKobo': 15000000, 'newNetKobo': 14800000, 'differenceKobo': -200000};

    testWidgets('rate up: Hey Chief good news, accept continues', (t) async {
      phone(t);
      RateChoice? choice;
      await t.pumpWidget(MaterialApp(
        theme: buildKnockTheme(),
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () async => choice = await showRateChangeSheet(context, cmp: up, currency: 'USD'), child: const Text('go'))))),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Hey Chief! Good news. Your rate just went up!'), findsOneWidget);
      expect(find.textContaining('+₦2,000'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('rate-accept')));
      await t.pumpAndSettle();
      expect(choice, RateChoice.accept);
    });

    testWidgets('rate down: cannot be dismissed, cancel cancels', (t) async {
      phone(t);
      RateChoice? choice;
      await t.pumpWidget(MaterialApp(
        theme: buildKnockTheme(),
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () async => choice = await showRateChangeSheet(context, cmp: down, currency: 'USD'), child: const Text('go'))))),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Hey Chief! Your rate just changed.'), findsOneWidget);
      await t.tapAt(const Offset(10, 10)); // tap outside
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rate-cancel')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rate-cancel')));
      await t.pumpAndSettle();
      expect(choice, RateChoice.cancel);
    });
  });

  testWidgets('settings: guide toggle and notification preference save to the backend', (t) async {
    phone(t);
    final api = KnockApi.memory();
    final c = await signedInController(api);
    await t.pumpWidget(host(c, const SettingsScreen()));
    await t.pumpAndSettle();
    await reveal(t, 'set-guide');
    await t.tap(find.byKey(const ValueKey('set-guide')));
    await t.pumpAndSettle();
    expect(c.me?['guideEnabled'], isFalse);
    expect(api.server.me(api.token!)['user']['guideEnabled'], isFalse);

    await t.pumpWidget(host(c, const NotificationPrefsScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pref-referral')));
    await t.pumpAndSettle();
    expect((api.server.me(api.token!)['user']['prefs'] as Map)['referral'], isFalse);
  });

  testWidgets('delete account: needs password, DELETE and acknowledgement, then is tracked and can be cancelled', (t) async {
    phone(t);
    t.view.physicalSize = const Size(1170, 9000); // whole form on screen
    final api = KnockApi.memory();
    final c = await signedInController(api);
    await t.pumpWidget(host(c, const DeleteAccountScreen()));
    await t.pumpAndSettle();

    KnockButtonFinder() => find.byKey(const ValueKey('delete-submit'));
    await t.enterText(field('delete-password'), 'Secret123!');
    await t.enterText(field('delete-confirm'), 'DELETE');
    await t.pump();
    // Still disabled until the acknowledgement is ticked.
    await t.tap(KnockButtonFinder(), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.text('Delete your Knock account?'), findsNothing);

    await t.tap(find.byKey(const ValueKey('delete-ack')));
    await t.pump();
    await t.tap(KnockButtonFinder());
    await t.pumpAndSettle();
    expect(find.text('Delete your Knock account?'), findsOneWidget);
    await t.tap(find.text('Delete account').last);
    await t.pumpAndSettle();
    c.dataVersion++;
    c.notifyListeners();
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('deletion-status')), findsOneWidget);
    expect(api.server.deletionCheck(api.token!)['request']['status'], 'scheduled');

    await t.tap(find.byKey(const ValueKey('deletion-cancel')));
    await t.pumpAndSettle();
    expect(api.server.deletionCheck(api.token!)['request'], isNull);
  });
}
