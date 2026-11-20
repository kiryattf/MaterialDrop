import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/direct/md_constants.dart';
import 'package:material_drop/protocol/direct/md_receiver.dart';
import 'package:material_drop/protocol/direct/md_sender.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sanitizeFileName prevents path traversal and invalid characters', () {
    expect(MdConstants.sanitizeFileName('../../.ssh/authorized_keys'), 'authorized_keys');
    expect(MdConstants.sanitizeFileName(r'..\..\evil.exe'), 'evil.exe');
    expect(MdConstants.sanitizeFileName('...hidden.txt'), 'hidden.txt');
    expect(MdConstants.sanitizeFileName('normal file (1).jpg'), 'normal file (1).jpg');
    expect(MdConstants.sanitizeFileName(''), 'unnamed_file');
  });

  test('Loopback MaterialDrop Direct HTTP /ping, accept, decline (403), and batch upload', () async {
    final tempRoot = await Directory.systemTemp.createTemp('md_direct_');
    final recvDir = Directory(p.join(tempRoot.path, 'received'));
    await recvDir.create();

    final f1 = File(p.join(tempRoot.path, 'doc1.bin'));
    final f2 = File(p.join(tempRoot.path, 'doc2.txt'));
    final bytes1 = List<int>.generate(130 * 1024, (i) => (i * 13) & 0xFF);
    final bytes2 = utf8.encode('MaterialDrop Flutter Rewrite Test');
    await f1.writeAsBytes(bytes1, flush: true);
    await f2.writeAsBytes(bytes2, flush: true);

    var shouldAccept = true;
    final completedItems = <IncomingTransferItem>[];
    Completer<void>? itemDone;

    // Bind ephemeral port (0) so tests don't clash with anything on 45873/45874
    late MaterialDropReceiver receiver;
    receiver = MaterialDropReceiver(
      deviceName: 'Direct-Test-PC',
      downloadDir: recvDir.path,
      treatLoopbackAsUsb: false,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => false,
      autoAcceptTrustedFn: () => false,
      onOffer: (_) {
        Future<void>.delayed(const Duration(milliseconds: 20), () {
          receiver.setDecision(shouldAccept);
        });
      },
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, item) {
        completedItems.add(item);
        final done = itemDone;
        if (done != null && !done.isCompleted) {
          done.complete();
        }
      },
      onCanceled: () {},
      onError: (e) {
        final done = itemDone;
        if (done != null && !done.isCompleted) {
          done.completeError(StateError(e));
        }
      },
    );

    await receiver.start(explicitPort: 0, enableBeacon: false);
    final port = receiver.port;
    expect(port, greaterThan(0));

    try {
      // 1. Verify GET /ping JSON
      final client = HttpClient();
      final pingReq = await client.getUrl(Uri.parse('http://127.0.0.1:$port/ping'));
      final pingResp = await pingReq.close();
      expect(pingResp.statusCode, 200);
      final pingJson = jsonDecode(await utf8.decodeStream(pingResp)) as Map<String, dynamic>;
      expect(pingJson['name'], 'Direct-Test-PC');
      expect(pingJson['status'], 'online');
      client.close();

      // 2. Verify untrusted decline returns 403 error
      final sender = MaterialDropSender();
      final dev = NearbyDevice(
        id: 'md:127.0.0.1:$port',
        name: 'Direct-Test-PC',
        ip: '127.0.0.1',
        port: port,
        kind: DeviceKind.pc,
        protocol: TransferProtocol.materialDrop,
        isUsb: false,
        lastSeen: DateTime.now(),
      );

      shouldAccept = false;
      await expectLater(
        sender.sendBatch(
          device: dev,
          localDeviceName: 'Flutter-Test-Phone',
          files: [
            StagedFile(
              name: 'doc2.txt',
              size: bytes2.length,
              mimeType: 'text/plain',
              path: f2.path,
            ),
          ],
          onProgress: (_, _, _, _) {},
        ),
        throwsA(isA<MaterialDropSendException>()),
      );
      expect(completedItems, isEmpty);

      // 3. Verify accepted batch upload of 2 files preserves SHA-256
      shouldAccept = true;
      itemDone = Completer<void>();
      var progUpdates = 0;
      await sender.sendBatch(
        device: dev,
        localDeviceName: 'Flutter-Test-Phone',
        files: [
          StagedFile(
            name: 'doc1.bin',
            size: bytes1.length,
            mimeType: 'application/octet-stream',
            path: f1.path,
          ),
          StagedFile(
            name: 'doc2.txt',
            size: bytes2.length,
            mimeType: 'text/plain',
            path: f2.path,
          ),
        ],
        onProgress: (_, _, _, _) => progUpdates++,
      );
      if (completedItems.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(progUpdates, greaterThan(0));
      expect(completedItems.length, 2);
      expect(
        sha256.convert(await File(completedItems[0].savedPathOrUri).readAsBytes()).toString(),
        sha256.convert(bytes1).toString(),
      );
      expect(
        await File(completedItems[1].savedPathOrUri).readAsBytes(),
        bytes2,
      );
    } finally {
      await receiver.stop();
      await tempRoot.delete(recursive: true);
    }
  });
}
