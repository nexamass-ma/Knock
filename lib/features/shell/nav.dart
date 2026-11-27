import 'package:material_ui/material_ui.dart';

import '../../design/widgets/kit.dart';
import '../coming_soon/knock_ai_screen.dart';
import '../coming_soon/usa_account_screen.dart';
import '../gifts/gift_detail_screen.dart';
import '../gifts/send_gift_screen.dart';
import '../growth/fire_load_screen.dart';
import '../growth/knockout_screen.dart';
import '../growth/leaderboard_screen.dart';
import '../growth/referrals_screen.dart';
import '../growth/rewards_screen.dart';
import '../growth/workings_screen.dart';
import '../history/transaction_detail_screen.dart';
import '../notifications/notifications_screen.dart';
import '../services/betting_screen.dart';
import '../services/bills_screen.dart';
import '../services/epins_screen.dart';
import '../services/esim_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/verification_screen.dart';
import '../support/faq_screen.dart';
import '../support/support_screen.dart';
import '../trade/rates_screen.dart';
import '../trade/sell_gift_card_screen.dart';
import '../trade/watchlist_screen.dart';
import '../wallet/crypto_screen.dart';
import '../wallet/money_screens.dart';
import 'shell.dart';

/// One place for every destination, so buttons, notifications and the
/// drawer all open the same screens.
abstract final class Nav {
  static void tab(BuildContext context, ShellTab t) => ShellScope.of(context)?.goTab(t);

  static Future<void> sellGiftCard(BuildContext c, {String? brandId, String? currency, String? cardType, int? faceValue}) =>
      go(c, SellGiftCardScreen(brandId: brandId, currency: currency, cardType: cardType, faceValue: faceValue));
  static Future<void> rates(BuildContext c, {String? category}) => go(c, RatesScreen(category: category));
  static Future<void> watchlist(BuildContext c) => go(c, const WatchlistScreen());
  static Future<void> crypto(BuildContext c, {String side = 'sell', String? symbol}) => go(c, CryptoScreen(initialSide: side, symbol: symbol));
  static Future<void> bills(BuildContext c, {String kind = 'airtime'}) => go(c, ServicePurchaseScreen(kind: kind));
  static Future<void> billsHub(BuildContext c) => go(c, const BillsScreen());
  static Future<void> betting(BuildContext c) => go(c, const BettingScreen());
  static Future<void> epins(BuildContext c) => go(c, const EpinsScreen());
  static Future<void> esim(BuildContext c) => go(c, const EsimScreen());
  static Future<void> sendGift(BuildContext c) => go(c, const SendGiftScreen());
  static Future<void> gift(BuildContext c, String id) => go(c, GiftDetailScreen(giftId: id));
  static Future<void> txn(BuildContext c, String id) => go(c, TransactionDetailScreen(txnId: id));
  static Future<void> deposit(BuildContext c) => go(c, const DepositScreen());
  static Future<void> withdraw(BuildContext c) => go(c, const WithdrawScreen());
  static Future<void> referrals(BuildContext c) => go(c, const ReferralsScreen());
  static Future<void> leaderboard(BuildContext c) => go(c, const LeaderboardScreen());
  static Future<void> rewards(BuildContext c) => go(c, const RewardsScreen());
  static Future<void> knockout(BuildContext c) => go(c, const KnockoutScreen());
  static Future<void> fireLoad(BuildContext c) => go(c, const FireLoadScreen());
  static Future<void> workings(BuildContext c) => go(c, const WorkingsScreen());
  static Future<void> usaAccount(BuildContext c) => go(c, const UsaAccountScreen());
  static Future<void> knockAi(BuildContext c) => go(c, const KnockAiScreen());
  static Future<void> support(BuildContext c) => go(c, const SupportScreen());
  static Future<void> faq(BuildContext c) => go(c, const FaqScreen());
  static Future<void> settings(BuildContext c) => go(c, const SettingsScreen());
  static Future<void> verification(BuildContext c) => go(c, const VerificationScreen());
  static Future<void> notifications(BuildContext c) => go(c, const NotificationsScreen());
  static Future<void> devices(BuildContext c) => go(c, const DevicesScreen());

  /// Opens the screen a notification or server action points to.
  static Future<void> action(BuildContext c, Map? a) async {
    if (a == null) return;
    final id = a['id'] as String?;
    switch (a['route']) {
      case 'txn' when id != null:
        await txn(c, id);
      case 'gift' when id != null:
        await gift(c, id);
      case 'knockout':
        await knockout(c);
      case 'referrals':
        await referrals(c);
      case 'rewards':
        await rewards(c);
      case 'fireload':
        await fireLoad(c);
      case 'devices':
        await devices(c);
      case 'verification':
        await verification(c);
      case 'rates':
        await rates(c);
      case 'watchlist':
        await watchlist(c);
      case 'sell' || 'draft':
        await sellGiftCard(c, brandId: a['brandId'] as String?, currency: a['currency'] as String?);
      case 'ticket' when id != null:
        await go(c, TicketScreen(ticketId: id));
      case 'wallet':
        tab(c, ShellTab.home);
      case 'gifts':
        tab(c, ShellTab.gifts);
      default:
        break;
    }
  }
}

