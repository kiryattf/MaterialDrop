import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/theme/app_theme.dart';
import 'package:material_drop/ui/widgets/sonar_radar.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('SonarRadar positions tapProximity peers by proximity zone with sensor badge', (
    WidgetTester tester,
  ) async {
    final proximityPeer = NearbyDevice(
      id: 'tap:AABBCCDD',
      name: 'Phone-NFC',
      ip: 'AA:BB:CC:DD:EE:FF',
      port: 53317,
      kind: DeviceKind.phone,
      protocol: TransferProtocol.tapProximity,
      isUsb: false,
      rssi: -46,
      proximityZone: 'immediate',
      lastSeen: DateTime.now(),
    );

    NearbyDevice? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.buildTheme(
          brightness: Brightness.dark,
          style: AppThemeStyle.oled,
          useDynamicColor: false,
        ),
        home: Scaffold(
          body: SizedBox(
            height: 360,
            width: 360,
            child: SonarRadar(
              devices: [proximityPeer],
              isTrusted: (_) => false,
              onDeviceSelected: (d) => selected = d,
              thisDeviceLabel: 'This PC',
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Phone-NFC'), findsOneWidget);
    expect(find.byIcon(Icons.sensors_rounded), findsOneWidget);

    await tester.tap(find.text('Phone-NFC'));
    expect(selected?.id, proximityPeer.id);
  });
}
