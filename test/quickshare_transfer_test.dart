import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/quickshare/proto_codec.dart';
import 'package:material_drop/protocol/quickshare/qs_receiver.dart';
import 'package:material_drop/protocol/quickshare/qs_sender.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Full loopback TCP Quick Share transfer (>200 KB) preserves SHA-256 and PIN', () async {
    final tempRoot = await Directory.systemTemp.createTemp('qs_loopback_');
    final sendFile = File(p.join(tempRoot.path, 'sample_payload.bin'));
    final recvDir = Directory(p.join(tempRoot.path, 'received'));
    await recvDir.create();

    // 220 KB deterministic payload spanning multiple 64 KiB chunks
    final payloadBytes = List<int>.generate(220 * 1024 + 37, (i) => (i * 31 + 7) & 0xFF);
    await sendFile.writeAsBytes(payloadBytes, flush: true);
    final expectedSha = sha256.convert(payloadBytes).toString();

    String? receiverPin;
    String? senderPin;
    final completedCompleter = Completer<List<IncomingTransferItem>>();
    var progressEvents = 0;

    final receiver = QsReceiver(
      deviceName: 'Test-Receiver',
      downloadDir: recvDir.path,
      isTrustedFn: (_, _) => true,
      autoAcceptAllFn: () => true,
      autoAcceptTrustedFn: () => true,
      onOffer: (offer) {
        receiverPin = offer.pin;
      },
      onProgress: (_, _, _, _, _) {
        progressEvents++;
      },
      onCompleted: (_, items, _) {
        if (!completedCompleter.isCompleted) {
          completedCompleter.complete(items);
        }
      },
      onCanceled: () {},
      onError: (msg) {
        if (!completedCompleter.isCompleted) {
          completedCompleter.completeError(StateError(msg));
        }
      },
    );

    await receiver.start(advertiseMdns: false);
    expect(receiver.port, greaterThan(0));

    try {
      final sender = QsSender();
      var senderProgressEvents = 0;
      final result = await sender.sendFiles(
        device: NearbyDevice(
          id: 'qs:test',
          name: 'Test-Receiver',
          ip: '127.0.0.1',
          port: receiver.port,
          kind: DeviceKind.pc,
          protocol: TransferProtocol.quickShare,
          isUsb: false,
          lastSeen: DateTime.now(),
        ),
        localDeviceName: 'Test-Sender',
        files: [
          StagedFile(
            name: 'sample_payload.bin',
            size: payloadBytes.length,
            mimeType: 'application/octet-stream',
            path: sendFile.path,
          ),
        ],
        onPin: (pin) => senderPin = pin,
        onProgress: (_, _, _, _) => senderProgressEvents++,
      );

      expect(result.isAccepted, isTrue);
      expect(result.status, SharingConnectionResponseFrame.statusAccept);
      expect(senderPin, isNotNull);
      expect(senderPin!.length, 4);

      final items = await completedCompleter.future
          .timeout(const Duration(seconds: 5));
      expect(items.length, 1);
      expect(receiverPin, senderPin);
      expect(progressEvents, greaterThan(0));
      expect(senderProgressEvents, greaterThan(0));

      final receivedFile = File(items.first.savedPathOrUri);
      expect(await receivedFile.exists(), isTrue);
      final actualBytes = await receivedFile.readAsBytes();
      expect(actualBytes.length, payloadBytes.length);
      expect(sha256.convert(actualBytes).toString(), expectedSha);
    } finally {
      await receiver.stop();
      await tempRoot.delete(recursive: true);
    }
  });
}

