import 'package:material_ui/material_ui.dart';

import '../models/quote.dart';

enum AppTab { home, activity, knock, wallet, profile }

/// A request to open the assistant with an intent already chosen, so the
/// user never repeats what they tapped.
class AssistantLaunch {
  AssistantLaunch(this.flow, {this.fields = const {}}) : id = DateTime.now().microsecondsSinceEpoch;
  final int id;
  final TxFlow flow;
  final Map<String, String> fields;
}

class ShellController extends ChangeNotifier {
  AppTab tab = AppTab.home;
  AssistantLaunch? pendingLaunch;

  void select(AppTab t) {
    if (t == tab) return;
    tab = t;
    notifyListeners();
  }

  void openAssistant(TxFlow flow, {Map<String, String> fields = const {}}) {
    pendingLaunch = AssistantLaunch(flow, fields: fields);
    tab = AppTab.knock;
    notifyListeners();
  }

  AssistantLaunch? takeLaunch() {
    final l = pendingLaunch;
    pendingLaunch = null;
    return l;
  }
}
