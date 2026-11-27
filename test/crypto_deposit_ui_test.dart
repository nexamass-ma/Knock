import 'package:flutter_test/flutter_test.dart';
import 'package:knock/api/api.dart';
import 'package:knock/features/wallet/crypto_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'app_flows_test.dart' show host, phone, signedInController;

void main() {
  testWidgets('deposit screen generates an address, shows QR and tracks a test deposit to completion', (t) async {
    phone(t);
    final api = KnockApi.memory();
    final c = await signedInController(api);
    await t.pumpWidget(host(c, const CryptoReceiveScreen(symbol: 'USDT')));
    await t.pump();
    expect(find.text('Deposit crypto'), findsOneWidget);
    // Generating, then ready.
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Generating your address…'), findsOneWidget);
    api.server.timeOffset += const Duration(seconds: 2);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 900));
    }
    await t.pumpAndSettle();
    expect(find.text('Awaiting Deposit'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('Only send USDT on Tron (TRC20)'), 200, scrollable: find.byType(Scrollable).first);
    await t.scrollUntilVisible(find.byKey(const ValueKey('crypto-sim-completed')), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('crypto-sim-completed')));
    await t.pumpAndSettle();
    for (var i = 0; i < 15; i++) {
      api.server.timeOffset += const Duration(seconds: 1);
      api.server.tick();
    }
    c.poke();
    await t.pumpAndSettle();
    expect(find.text('Deposit Completed'), findsOneWidget);
  });
}
