import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera_android/camera_android.dart';
import 'app.dart';
import 'data/inventory_database.dart';
import 'state/pharmacy_controller.dart';
import 'ui/design.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The Android Camera2 implementation supplies the NV21 format ML Kit expects.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
    AndroidCamera.registerWith();
  runApp(const PharmacyBootstrap());
}

class PharmacyBootstrap extends StatefulWidget {
  const PharmacyBootstrap({super.key});
  @override
  State<PharmacyBootstrap> createState() => _PharmacyBootstrapState();
}

class _PharmacyBootstrapState extends State<PharmacyBootstrap> {
  late final PharmacyController controller = PharmacyController(
    SqliteInventoryStorage(),
  );
  late Future<void> load = controller.initialize();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: load,
    builder: (context, result) {
      if (result.connectionState == ConnectionState.done && !result.hasError)
        return PharmacyApp(controller: controller);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: pharmacyTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: result.hasError
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.storage_rounded,
                            color: red,
                            size: 42,
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            'Your inventory could not be opened.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Your saved data has not been replaced. Close other instances or try again.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: () =>
                                setState(() => load = controller.initialize()),
                            child: const Text('Try again'),
                          ),
                        ],
                      )
                    : const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.local_pharmacy_rounded,
                            color: ink,
                            size: 52,
                          ),
                          SizedBox(height: 18),
                          Text(
                            'Aaris Pharmacy',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 24,
                            ),
                          ),
                          SizedBox(height: 28),
                          CircularProgressIndicator(),
                        ],
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
