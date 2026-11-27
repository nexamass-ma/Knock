import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'api/api.dart';
import 'app/app_controller.dart';
import 'app/knock_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF14141A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final api = await KnockApi.open();
  runApp(KnockApp(controller: AppController(api)));
}
