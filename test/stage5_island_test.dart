import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/direct/md_receiver.dart';
import 'package:material_drop/protocol/gesture/gesture_client.dart';
import 'package:material_drop/protocol/gesture/gesture_models.dart';
import 'package:material_drop/protocol/gesture/preview_extractor.dart';
import 'package:material_drop/protocol/lan/lan_receiver.dart';
import 'package:material_drop/protocol/lan/tls_identity.dart';
import 'package:material_drop/protocol/transfer_coordinator.dart';
import 'package:material_drop/services/launch_config.dart';
import 'package:material_drop/services/settings_controller.dart';
import 'package:material_drop/ui/widgets/dynamic_island.dart';
import 'package:material_drop/ui/widgets/swipeable_file_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('PreviewExtractor computes vivid dominant color from RGBA pixels', () {
    // 4x1 image: 2 transparent pixels, 2 vivid orange pixels (#FFFF6D00)
    final rgba = Uint8List.fromList([
      0, 0, 0, 0,
      250, 250, 250, 10,
      255, 109, 0, 255,
      255, 109, 0, 255,
    ]);
    final color = PreviewExtractor.computeDominantColorFromRgba(rgba);
    expect((color >> 16) & 0xFF, greaterThan(230));
    expect((color >> 8) & 0xFF, inInclusiveRange(90, 130));
    expect(color & 0xFF, lessThan(25));
  });

  test('GesturePreviewEvent encodes and decodes trigger with thumbnail', () {
    final thumb = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4]);
    final ev = GesturePreviewEvent(
      eventType: 'drop_gesture_trigger',
      senderName: 'Pixel 9',
      fileName: 'vacation.jpg',
      fileCount: 2,
      totalBytes: 409600,
      mimeType: 'image/jpeg',
      dominantColor: 0xFFE91E63,
      dragProgress: 0.28,
      thumbnailBytes: thumb,
    );
    final decoded = GesturePreviewEvent.fromJsonString(jsonEncode(ev.toJson()));
    expect(decoded, isNotNull);
    expect(decoded!.eventType, 'drop_gesture_trigger');
    expect(decoded.dominantColor, 0xFFE91E63);
    expect(decoded.thumbnailBytes, thumb);
    expect(decoded.fileCount, 2);
  });

  test('WebSocket /ws/gesture delivers drop_gesture_trigger and cancel on Direct & HTTPS LAN', () async {
    final prevHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    final tmpDir = await Directory.systemTemp.createTemp('md_ws_test_');
    try {
      final receivedEvents = <GesturePreviewEvent>[];
      final receiver = MaterialDropReceiver(
        deviceName: 'WinHost',
        downloadDir: tmpDir.path,
        treatLoopbackAsUsb: true,
        isTrustedFn: (_, _) => false,
        autoAcceptAllFn: () => false,
        autoAcceptTrustedFn: () => false,
        onOffer: (_) {},
        onProgress: (_, _, _, _, _) {},
        onCompleted: (_, _) {},
        onCanceled: () {},
        onError: (_) {},
        onGestureEvent: receivedEvents.add,
      );
      await receiver.start(explicitPort: 0, bindAddress: '127.0.0.1', enableBeacon: false);

      // Also test pinned WSS /ws/gesture on LanReceiver
      final lanId = TlsIdentity.generate(commonName: 'LanHost');
      final lanReceived = <GesturePreviewEvent>[];
      final lanReceiver = LanReceiver(
        deviceName: 'LanHost',
        downloadDir: tmpDir.path,
        identity: lanId,
        isTrustedFn: (_, _) => false,
        autoAcceptAllFn: () => false,
        autoAcceptTrustedFn: () => false,
        onOffer: (_) {},
        onProgress: (_, _, _, _, _) {},
        onCompleted: (_, _) {},
        onCanceled: () {},
        onError: (_) {},
        onGestureEvent: lanReceived.add,
      );
      await lanReceiver.start(explicitPort: 0, bindAddress: '127.0.0.1', useHttps: true);

      final client = GestureClient();
      final directPeer = NearbyDevice(
        id: 'd1',
        name: 'WinHost',
        ip: '127.0.0.1',
        port: receiver.port,
        kind: DeviceKind.pc,
        protocol: TransferProtocol.materialDrop,
        isUsb: false,
        lastSeen: DateTime.now(),
      );

      final sampleEvent = GesturePreviewEvent(
        eventType: 'drop_gesture_trigger',
        senderName: 'AndroidPhone',
        fileName: 'shot.png',
        fileCount: 1,
        totalBytes: 2048,
        mimeType: 'image/png',
        dominantColor: 0xFF00BFA5,
        dragProgress: 0.25,
        thumbnailBytes: Uint8List.fromList([1, 2, 3, 4]),
      );

      await client.sendTrigger(directPeer, sampleEvent);
      await client.sendCancel(directPeer, senderName: 'AndroidPhone');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(receivedEvents.length, 2);
      expect(receivedEvents[0].eventType, 'drop_gesture_trigger');
      expect(receivedEvents[0].dominantColor, 0xFF00BFA5);
      expect(receivedEvents[1].isCancel, isTrue);

      final lanPeer = NearbyDevice(
        id: 'l1',
        name: 'LanHost',
        ip: '127.0.0.1',
        port: lanReceiver.port,
        kind: DeviceKind.pc,
        protocol: TransferProtocol.lan,
        isUsb: false,
        useHttps: true,
        tlsFingerprint: lanId.fingerprint,
        lastSeen: DateTime.now(),
      );
      await client.sendTrigger(lanPeer, sampleEvent);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(lanReceived.length, 1);
      expect(lanReceived.first.fileName, 'shot.png');

      await client.close();
      await receiver.stop();
      await lanReceiver.stop();
    } finally {
      HttpOverrides.global = prevHttp;
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    }
  });

  testWidgets('SwipeableFileCard triggers pre-gesture at 20% and DynamicIsland renders positions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController(
      launchConfig: const LaunchConfig(deviceName: 'Test-Island-Host', port: 45877),
    );
    await tester.runAsync(() async {
      await settings.init();
      await settings.setLanguageCode('en');
      await settings.setIslandPosition(IslandPosition.bottomCenter);
    });
    expect(settings.islandPosition, IslandPosition.bottomCenter);

    final coordinator = TransferCoordinator(settings: settings);
    addTearDown(coordinator.dispose);
    var preTriggeredCount = 0;
    var canceledCount = 0;

    final device = NearbyDevice(
      id: 'p1',
      name: 'Arch Hyprland',
      ip: '127.0.0.1',
      port: 45873,
      kind: DeviceKind.pc,
      protocol: TransferProtocol.materialDrop,
      isUsb: false,
      lastSeen: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Center(
                child: SwipeableFileCard(
                  files: const [
                    StagedFile(
                      name: 'clip.mp4',
                      size: 1024 * 1024,
                      mimeType: 'video/mp4',
                    ),
                  ],
                  targetDevice: device,
                  strings: settings.strings,
                  onPreGestureTrigger: () => preTriggeredCount++,
                  onPreGestureCancel: () => canceledCount++,
                  onThrowSuccess: () {},
                ),
              ),
              DynamicIslandOverlay(
                coordinator: coordinator,
                settings: settings,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Drag up past touch slop + >= 20% of 115px threshold without throwing (<115px)
    final card = find.text('clip.mp4');
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -25));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(preTriggeredCount, 1);

    // Release gently to trigger snap-back + cancel
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(canceledCount, 1);
  });
}
