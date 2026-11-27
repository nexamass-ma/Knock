import 'package:flutter_test/flutter_test.dart';
import 'package:knock/app/app_scope.dart';
import 'package:knock/app/knock_app.dart';
import 'package:knock/state/shell_controller.dart';
import 'package:knock/models/quote.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('unlocks with a PIN, shows home, opens assistant with intent', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState(AppServices.mock());
    state.services.mockBackend!.latency = Duration.zero;
    await tester.pumpWidget(KnockApp(state: state));
    await tester.pumpAndSettle();

    expect(find.textContaining('Welcome back'), findsOneWidget);
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d).first);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('Start a trade'), findsOneWidget);
    expect(find.text('Buy Crypto'), findsOneWidget);

    await tester.tap(find.text('Buy Crypto'));
    await tester.pumpAndSettle();
    expect(state.shell.tab, AppTab.knock);
    expect(find.text("Let's buy crypto."), findsOneWidget);
    expect(find.text('Which asset would you like to buy?'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, 'USDT'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '₦100,000'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Confirm transaction'), findsOneWidget);
    expect(state.assistant.activeFlow, TxFlow.buyCrypto);

    // Unmount so the quote countdown timer is disposed.
    await tester.pumpWidget(const SizedBox());
  });
}
