import 'package:material_drop/l10n/app_strings.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/theme/app_theme.dart';
import 'package:material_drop/ui/widgets/sonar_radar.dart';
import 'package:material_drop/ui/widgets/swipeable_file_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SonarRadar and SwipeableFileCard render and trigger callbacks', (
    WidgetTester tester,
  ) async {
    final testDevice = NearbyDevice(
      id: 'md:192.168.1.50:45873',
      name: 'DESKTOP-TEST',
      ip: '192.168.1.50',
      port: 45873,
      kind: DeviceKind.pc,
      protocol: TransferProtocol.materialDrop,
      isUsb: false,
      lastSeen: DateTime.now(),
    );

    NearbyDevice? selected;
    var thrown = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.buildTheme(
          brightness: Brightness.dark,
          style: AppThemeStyle.oled,
          useDynamicColor: false,
        ),
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 260,
                child: SonarRadar(
                  devices: [testDevice],
                  isTrusted: (_) => true,
                  onDeviceSelected: (d) => selected = d,
                  thisDeviceLabel: 'This device',
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: SwipeableFileCard(
                    files: const [
                      StagedFile(
                        name: 'photo.png',
                        size: 2048,
                        mimeType: 'image/png',
                      ),
                    ],
                    targetDevice: testDevice,
                    strings: const AppStrings('en'),
                    onThrowSuccess: () => thrown = true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('DESKTOP-TEST'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);

    await tester.tap(find.text('DESKTOP-TEST'));
    expect(selected?.id, testDevice.id);

    final sendBtn = find.text('Send now');
    await tester.ensureVisible(sendBtn);
    await tester.pump();
    await tester.tap(sendBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(thrown, isTrue);
  });
}
