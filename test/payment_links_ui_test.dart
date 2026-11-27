import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:knock/features/payment_links/payment_links_screen.dart';
import 'package:knock/features/payment_links/pl_sandbox.dart';

void main() {
  testWidgets('dashboard shows seeded links and opens the create flow', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final sb = PlSandbox();
    await tester.pumpWidget(MaterialApp(home: PaymentLinksScreen(sandbox: sb)));
    expect(find.text('Project Alpha'), findsOneWidget);
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();
    expect(find.text('What do you want to collect?'), findsOneWidget);
    await tester.tap(find.text('Split payment'));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 · Total to collect'), findsOneWidget);
  });
}
