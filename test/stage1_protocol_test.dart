import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/direct/md_constants.dart';
import 'package:material_drop/protocol/direct/md_receiver.dart';
import 'package:material_drop/protocol/direct/md_sender.dart';
import 'package:material_drop/services/launch_config.dart';
import 'package:path/path.dart' as p;

void main() {
  test('LaunchConfig parses CLI flags and isolates multi-instance prefixes', () {
    const defaultCfg = LaunchConfig();
    expect(defaultCfg.isMultiInstance, isFalse);
    expect(defaultCfg.profilePrefix, isEmpty);

    final cfgA = LaunchConfig.fromArgs([
      '--name',
      'PC-2',
      '--bind',
      '127.0.0.2',
      '--port',
      '45875',
      '--tray',
    ]);
    expect(cfgA.isMultiInstance, isTrue);
    expect(cfgA.deviceName, 'PC-2');
    expect(cfgA.bindAddress, '127.0.0.2');
    expect(cfgA.port, 45875);
    expect(cfgA.startInTray, isTrue);
    expect(cfgA.profilePrefix, 'inst_PC_2_127_0_0_2_45875_');

    final cfgB = LaunchConfig.fromArgs([
      '--name=PC-3',
      '--bind=127.0.0.3',
      '--port=45876',
      '--minimized',
    ]);
    expect(cfgB.isMultiInstance, isTrue);
    expect(cfgB.deviceName, 'PC-3');
    expect(cfgB.bindAddress, '127.0.0.3');
    expect(cfgB.port, 45876);
    expect(cfgB.startInTray, isTrue);
    expect(cfgB.profilePrefix, isNot(equals(cfgA.profilePrefix)));
  });

  test('MdConstants.sanitizeRelativePath preserves safe trees and strips traversal', () {
    expect(
      MdConstants.sanitizeRelativePath('FolderA/sub/hello.txt'),
      'FolderA/sub/hello.txt',
    );
    expect(
      MdConstants.sanitizeRelativePath(r'FolderA\sub\hello.txt'),
      'FolderA/sub/hello.txt',
    );
    expect(
      MdConstants.sanitizeRelativePath('../../etc/passwd'),
      'etc/passwd',
    );
    expect(
      MdConstants.sanitizeRelativePath(r'C:\Users\..hidden\doc:1.txt'),
      'Users/hidden/doc_1.txt',
    );
    expect(MdConstants.sanitizeRelativePath(''), 'unnamed_file');
  });

  test('Folder upload via MaterialDropReceiver preserves relativePath on disk', () async {
    final tempRoot = await Directory.systemTemp.createTemp('md_folder_');
    final recvDir = Directory(p.join(tempRoot.path, 'recv'));
    await recvDir.create();

    final srcFile = File(p.join(tempRoot.path, 'hello.txt'));
    const payload = 'Nested folder payload from Stage 1 test';
    await srcFile.writeAsString(payload, flush: true);

    final completed = <IncomingTransferItem>[];
    final receiver = MaterialDropReceiver(
      deviceName: 'PC-Folder-Test',
      downloadDir: recvDir.path,
      instanceId: 'inst-folder-test',
      treatLoopbackAsUsb: false,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => true,
      autoAcceptTrustedFn: () => true,
      onOffer: (_) {},
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, item) => completed.add(item),
      onCanceled: () {},
      onError: (e) => fail('Unexpected receiver error: $e'),
    );

    await receiver.start(bindAddress: '127.0.0.1', explicitPort: 0, enableBeacon: false);
    final port = receiver.port;

    try {
      final sender = MaterialDropSender();
      final dev = NearbyDevice(
        id: 'md:127.0.0.1:$port',
        name: 'PC-Folder-Test',
        ip: '127.0.0.1',
        port: port,
        kind: DeviceKind.pc,
        protocol: TransferProtocol.materialDrop,
        isUsb: false,
        lastSeen: DateTime.now(),
      );

      await sender.sendBatch(
        device: dev,
        localDeviceName: 'PC-1',
        files: [
          StagedFile(
            name: 'hello.txt',
            size: utf8.encode(payload).length,
            mimeType: 'text/plain',
            path: srcFile.path,
            relativePath: 'FolderA/sub/hello.txt',
          ),
        ],
        onProgress: (_, _, _, _) {},
      );

      if (completed.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(completed.length, 1);

      final expectedFile = File(p.join(recvDir.path, 'FolderA', 'sub', 'hello.txt'));
      expect(expectedFile.existsSync(), isTrue);
      expect(await expectedFile.readAsString(), payload);
    } finally {
      await receiver.stop();
      await tempRoot.delete(recursive: true);
    }
  });

  test('Dual receivers on 127.0.0.1 and 127.0.0.2 expose distinct instanceIds', () async {
    final tempRoot = await Directory.systemTemp.createTemp('md_dual_');
    final r1 = MaterialDropReceiver(
      deviceName: 'PC-1',
      downloadDir: tempRoot.path,
      instanceId: 'inst-pc1',
      treatLoopbackAsUsb: false,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => false,
      autoAcceptTrustedFn: () => false,
      onOffer: (_) {},
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, _) {},
      onCanceled: () {},
      onError: (_) {},
    );
    final r2 = MaterialDropReceiver(
      deviceName: 'PC-2',
      downloadDir: tempRoot.path,
      instanceId: 'inst-pc2',
      treatLoopbackAsUsb: false,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => false,
      autoAcceptTrustedFn: () => false,
      onOffer: (_) {},
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, _) {},
      onCanceled: () {},
      onError: (_) {},
    );

    await r1.start(bindAddress: '127.0.0.1', explicitPort: 0, enableBeacon: false);
    await r2.start(bindAddress: '127.0.0.2', explicitPort: 0, enableBeacon: false);

    final client = HttpClient();
    try {
      Future<Map<String, dynamic>> ping(String ip, int port) async {
        final req = await client.getUrl(Uri.parse('http://$ip:$port/ping'));
        final resp = await req.close();
        expect(resp.statusCode, 200);
        return jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
      }

      final p1 = await ping('127.0.0.1', r1.port);
      final p2 = await ping('127.0.0.2', r2.port);
      expect(p1['name'], 'PC-1');
      expect(p1['instanceId'], 'inst-pc1');
      expect(p2['name'], 'PC-2');
      expect(p2['instanceId'], 'inst-pc2');
    } finally {
      client.close();
      await r1.stop();
      await r2.stop();
      await tempRoot.delete(recursive: true);
    }
  });
}
