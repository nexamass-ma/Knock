import 'package:material_ui/material_ui.dart';

import '../services/contracts.dart';
import '../services/mock/mock_backend.dart';
import '../services/mock/mock_services.dart';
import '../services/security/authorizer.dart';
import '../services/security/secure_store.dart';
import '../state/assistant_controller.dart';
import '../state/session_store.dart';
import '../state/shell_controller.dart';
import '../state/wallet_store.dart';

/// Dependency container. Swap the mock services for live ones here.
class AppServices {
  AppServices({
    required this.wallet,
    required this.activity,
    required this.quotes,
    required this.transactions,
    required this.recognition,
    required this.conversation,
    required this.waitlist,
    required this.biometrics,
    required this.pin,
    required this.secureStore,
    this.mockBackend,
  });

  factory AppServices.mock() {
    final b = MockBackend();
    final wallet = MockWalletService(b);
    return AppServices(
      wallet: wallet,
      activity: wallet,
      quotes: MockQuoteService(b),
      transactions: MockTransactionService(b),
      recognition: MockGiftCardRecognition(b),
      conversation: const MockConversationService(),
      waitlist: MockCardWaitlist(b),
      biometrics: BiometricAuthorizer(),
      pin: const MockPinVerifier(),
      secureStore: SecureStore(),
      mockBackend: b,
    );
  }

  final WalletService wallet;
  final ActivityService activity;
  final QuoteService quotes;
  final TransactionService transactions;
  final GiftCardRecognitionService recognition;
  final ConversationService conversation;
  final CardWaitlistService waitlist;
  final BiometricAuthorizer biometrics;
  final MockPinVerifier pin;
  final SecureStore secureStore;

  /// Present only in mock mode; used by the prototype controls in Profile.
  final MockBackend? mockBackend;

  bool get isMock => mockBackend != null;
}

class AppState {
  AppState(this.services)
    : session = SessionStore(services),
      wallet = WalletStore(services),
      shell = ShellController() {
    assistant = AssistantController(services, wallet);
  }

  final AppServices services;
  final SessionStore session;
  final WalletStore wallet;
  final ShellController shell;
  late final AssistantController assistant;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.state, required super.child});

  final AppState state;

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing');
    return scope!.state;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.state != state;
}

extension AppScopeX on BuildContext {
  AppState get app => AppScope.of(this);
}
