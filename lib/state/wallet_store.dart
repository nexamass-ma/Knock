import 'package:material_ui/material_ui.dart';

import '../app/app_scope.dart';
import '../models/asset.dart';
import '../models/ledger.dart';

enum LoadState { idle, loading, ready, error }

/// Holds the last values the server sent. Nothing here is computed on the
/// client; after any transaction we re-fetch instead of adjusting locally.
class WalletStore extends ChangeNotifier {
  WalletStore(this._services);
  final AppServices _services;

  LoadState state = LoadState.idle;
  String? error;
  PortfolioSummary? portfolio;
  List<LedgerBalance> balances = const [];
  List<Holding> holdings = const [];
  List<TransactionRecord> transactions = const [];
  ChartRange range = ChartRange.week;

  LedgerBalance? balance(LedgerKind k) {
    for (final b in balances) {
      if (b.kind == k) return b;
    }
    return null;
  }

  Future<void> load({bool silent = false}) async {
    if (!silent || state != LoadState.ready) {
      state = LoadState.loading;
      error = null;
      notifyListeners();
    }
    try {
      final results = await Future.wait([
        _services.wallet.portfolio(range),
        _services.wallet.balances(),
        _services.wallet.holdings(),
        _services.activity.transactions(),
      ]);
      portfolio = results[0] as PortfolioSummary;
      balances = results[1] as List<LedgerBalance>;
      holdings = results[2] as List<Holding>;
      transactions = results[3] as List<TransactionRecord>;
      state = LoadState.ready;
      error = null;
    } catch (e) {
      error = e.toString();
      state = state == LoadState.ready && silent ? LoadState.ready : LoadState.error;
    }
    notifyListeners();
  }

  Future<void> setRange(ChartRange r) async {
    if (r == range) return;
    range = r;
    notifyListeners();
    try {
      portfolio = await _services.wallet.portfolio(r);
    } catch (_) {}
    notifyListeners();
  }
}
