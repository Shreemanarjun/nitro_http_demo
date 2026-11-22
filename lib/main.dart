import 'package:dartnative/dartnative.dart';

import 'dartnative_plugin_registrant.dart';
import 'src/ui/home_screen.dart';

export 'src/models/benchmark_config.dart';
export 'src/services/benchmark_client_pool.dart';
export 'src/services/benchmark_reporter.dart';
export 'src/services/benchmark_runner.dart';
export 'src/services/benchmark_server.dart';
export 'src/state/benchmark_controller.dart';
export 'src/ui/home_screen.dart';

void main() {
  // Platform bindings + (once you add plugins) their FFI symbols. Keep this
  // as the FIRST line of main() — see lib/dartnative_plugin_registrant.dart.
  DartNativePluginRegistrant.registerAll();

  // App-wide system chrome default for the white template: dark status-bar
  // icons over the light background, transparent strips. Screens can override
  // in initState; the navigator restores this default on pop.
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  );

  runApp(const HomeScreen());
}
