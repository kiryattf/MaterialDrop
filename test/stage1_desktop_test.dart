import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/transfer_coordinator.dart';
import 'package:material_drop/services/launch_config.dart';
import 'package:material_drop/services/settings_controller.dart';
import 'package:material_drop/theme/app_theme.dart';
import 'package:material_drop/ui/screens/send_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'SendScreen renders Supporting Pane Layout on >= 840dp and mobile layout on < 600dp',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController(
        launchConfig: const LaunchConfig(deviceName: 'Desktop-Host', port: 45875),
      );
      await tester.runAsync(() async {
        await settings.init();
        await settings.setLanguageCode('en');
      });

      final coordinator = TransferCoordinator(settings: settings);
      addTearDown(coordinator.dispose);

      Widget buildHost() {
        return MaterialApp(
          theme: AppTheme.buildTheme(
            brightness: Brightness.dark,
            style: AppThemeStyle.oled,
            useDynamicColor: false,
          ),
          home: Scaffold(
            body: SendScreen(
              settings: settings,
              coordinator: coordinator,
            ),
          ),
        );
      }

      // Desktop >= 840dp: Supporting Pane cards visible
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildHost());
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey('stage_desktop_supporting')), findsOneWidget);
      expect(find.text('Queue & Status'), findsOneWidget);
      expect(find.text('Nearby Devices'), findsOneWidget);
      expect(find.text('Recent Transfers'), findsOneWidget);
      expect(find.text('Quick Settings'), findsOneWidget);

      // Mobile < 600dp: vertical picker stage without supporting pane
      tester.view.physicalSize = const Size(400, 800);
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byKey(const ValueKey('stage_desktop_supporting')), findsNothing);
      expect(find.byKey(const ValueKey('stage_picker')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
