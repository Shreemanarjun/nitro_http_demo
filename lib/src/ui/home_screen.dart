import 'package:dartnative/dartnative.dart';

import '../state/benchmark_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.controller});

  final BenchmarkController? controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final BenchmarkController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = BenchmarkController();
      _ownsController = true;
    }
    _controller.runBenchmark();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reactive signal subscriptions
    final reportText = _controller.report.watch(context);
    final buttonText = _controller.buttonLabel.watch(context);
    final canExecute = _controller.canRun.watch(context);

    return Scaffold(
      brightness: Brightness.light,
      appBar: AppBar(title: const Text('nitro_http benchmark')),
      backgroundColor: const Color(0xFFFFFFFF),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ElevatedButton(
              onPressed: canExecute ? _controller.runBenchmark : null,
              child: Text(buttonText),
            ),
            const SizedBox(height: 16),
            Text(
              reportText,
              style: const TextStyle(fontSize: 11, fontFamily: 'Menlo'),
            ),
          ],
        ),
      ),
    );
  }
}
