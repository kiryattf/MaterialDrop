import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import 'proto_codec.dart';
import 'qs_crypto.dart';
import 'qs_framing.dart';
import 'qs_mdns.dart';
import 'qs_receiver.dart';
import 'qs_secure_channel.dart';
import 'qs_ukey2.dart';

class QsSendResult {
  final int status;
  final bool userCanceled;
  final bool receiverCanceled;

  const QsSendResult({
    required this.status,
    this.userCanceled = false,
    this.receiverCanceled = false,
  });

  bool get isAccepted =>
      !userCanceled &&
      !receiverCanceled &&
      status == SharingConnectionResponseFrame.statusAccept;
}

class QsSender {
  static const int chunkSize = 64 * 1024;

  bool _canceled = false;
  Socket? _activeSocket;

  void cancel() {
    _canceled = true;
    try {
      _activeSocket?.destroy();
    } catch (_) {}
  }

  Future<QsSendResult> sendFiles({
    required NearbyDevice device,
    required String localDeviceName,
    required List<StagedFile> files,
    void Function(String pin)? onPin,
    void Function(
      String fileName,
      int bytesSent,
      int totalBytes,
      double speedBps,
    )? onProgress,
  }) async {
    _canceled = false;
    final socket = await Socket.connect(
      device.ip,
      device.port,
      timeout: const Duration(seconds: 10),
    );
    _activeSocket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = FrameSocketReader(socket);

    try {
      final endpointId = QsMdns.stableEndpointId(
        Platform.localHostname.isNotEmpty
            ? Platform.localHostname
            : localDeviceName,
      );
      final targetType = Platform.isAndroid
          ? ShareTargetType.phone
          : ShareTargetType.laptop;
      final endpointInfo = QsMdns.buildEndpointInfo(localDeviceName, targetType);

      // 1. ConnectionRequest
      socket.add(packQuickShareFrame(_buildConnectionRequest(endpointId, endpointInfo)));
      await socket.flush();

      // 2. UKEY2 Client handshake
      final handshake = await QsUkey2.runClientHandshake(
        sendClientInit: (ciBytes) async {
          socket.add(packQuickShareFrame(ciBytes));
          await socket.flush();
        },
        recvServerInit: () => reader.readFrame(),
        sendClientFinished: (cfBytes) async {
          socket.add(packQuickShareFrame(cfBytes));
          await socket.flush();
        },
      );

      // 3. Plaintext ConnectionResponse exchange
      socket.add(packQuickShareFrame(_buildConnectionResponseAccept()));
      await socket.flush();

      final peerRespBytes = await reader.readFrame();
      final peerResp = OfflineFrame.parse(peerRespBytes);
      if (peerResp.v1?.type != OfflineFrameType.connectionResponse) {
        throw Ukey2Exception('Expected peer ConnectionResponse');
      }

      final channel = QsSecureChannel.fromKeys(handshake.keys);
      final pin = handshake.keys.pin;
      onPin?.call(pin);

      Future<void> channelSend(Uint8List payload) async {
        socket.add(packQuickShareFrame(channel.encrypt(payload)));
      }

      // 4. Paired-key exchange
      for (final f in QsReceiver.buildPairedKeyEncryptionFrames()) {
        await channelSend(f);
      }
      await socket.flush();
      await _recvSharingFrame(reader, channel); // peer PairedKeyEncryption

      for (final f in QsReceiver.buildPairedKeyResultFrames()) {
        await channelSend(f);
      }
      await socket.flush();
      await _recvSharingFrame(reader, channel); // peer PairedKeyResult

      // 5. IntroductionFrame
      final prepared = [
        for (var i = 0; i < files.length; i++)
          _FileToSend(
            file: files[i],
            payloadId: QsCrypto.randomPositive63BitId(),
            attachmentId: i,
          ),
      ];

      for (final f in _buildIntroductionFrame(prepared)) {
        await channelSend(f);
      }
      await socket.flush();

      final respSharingBytes = await _recvSharingFrame(reader, channel);
      final sharingResp = SharingFrame.parse(respSharingBytes);
      if (sharingResp.v1?.type != SharingFrameType.response ||
          sharingResp.v1?.connectionResponse == null) {
        throw StateError('Expected sharing RESPONSE frame');
      }
      final status = sharingResp.v1!.connectionResponse!.status;
      if (status != SharingConnectionResponseFrame.statusAccept) {
        return QsSendResult(status: status);
      }

      // 6. Listen in background for peer cancel/ack frames without interfering with send loop
      var receiverCanceled = false;
      final ackCompleter = Completer<void>();
      final lastPayloadId = prepared.last.payloadId;

      unawaited(() async {
        try {
          while (true) {
            final enc = await reader.readFrame();
            final plain = channel.decrypt(enc);
            final frame = OfflineFrame.parse(plain);
            if (frame.v1?.type != OfflineFrameType.payloadTransfer) continue;
            final pt = frame.v1!.payloadTransfer!;
            if (pt.packetType != PayloadTransferFrame.packetControl) continue;
            final ev = pt.controlMessage?.event ?? 0;
            if (ev == ControlMessage.eventPayloadCanceled ||
                ev == ControlMessage.eventPayloadError) {
              receiverCanceled = true;
              if (!ackCompleter.isCompleted) ackCompleter.complete();
              break;
            }
            if (ev == ControlMessage.eventPayloadReceivedAck &&
                pt.payloadHeader?.id == lastPayloadId) {
              if (!ackCompleter.isCompleted) ackCompleter.complete();
            }
          }
        } catch (_) {
          if (!ackCompleter.isCompleted) ackCompleter.complete();
        }
      }());

      // 7. Stream file payloads in <= 64 KiB encrypted FILE chunks
      final totalBytes = prepared.fold<int>(0, (a, f) => a + f.file.size);
      var sentSoFar = 0;
      final sw = Stopwatch()..start();
      var lastProgEmit = DateTime.fromMillisecondsSinceEpoch(0);

      for (final item in prepared) {
        var offset = 0;
        await for (final rawChunk
            in PlatformBridge.instance.openFileReadStream(item.file)) {
          if (_canceled) {
            try {
              await channelSend(_buildPayloadCanceled(item.payloadId));
              await socket.flush();
            } catch (_) {}
            return const QsSendResult(
              status: SharingConnectionResponseFrame.statusUnknown,
              userCanceled: true,
            );
          }
          if (receiverCanceled) {
            return const QsSendResult(
              status: SharingConnectionResponseFrame.statusUnknown,
              receiverCanceled: true,
            );
          }

          var pos = 0;
          while (pos < rawChunk.length) {
            if (_canceled || receiverCanceled) break;
            final end = (pos + chunkSize).clamp(0, rawChunk.length);
            final slice = Uint8List.sublistView(rawChunk, pos, end);
            pos = end;

            await channelSend(
              _buildPayloadChunk(
                payloadId: item.payloadId,
                offset: offset,
                body: slice,
                totalSize: item.file.size,
                fileName: item.file.name,
                isLast: false,
              ),
            );
            offset += slice.length;
            sentSoFar += slice.length;

            final now = DateTime.now();
            if (now.difference(lastProgEmit).inMilliseconds >= 50 ||
                sentSoFar >= totalBytes) {
              lastProgEmit = now;
              final sec = sw.elapsedMilliseconds / 1000.0;
              final speed = sec > 0 ? sentSoFar / sec : 0.0;
              onProgress?.call(item.file.name, sentSoFar, totalBytes, speed);
            }
          }
        }

        if (_canceled) {
          return const QsSendResult(
            status: SharingConnectionResponseFrame.statusUnknown,
            userCanceled: true,
          );
        }
        if (receiverCanceled) {
          return const QsSendResult(
            status: SharingConnectionResponseFrame.statusUnknown,
            receiverCanceled: true,
          );
        }

        // Empty LAST_CHUNK terminator
        await channelSend(
          _buildPayloadChunk(
            payloadId: item.payloadId,
            offset: offset,
            body: Uint8List(0),
            totalSize: item.file.size,
            fileName: item.file.name,
            isLast: true,
          ),
        );
        await socket.flush();
      }

      // Brief synchronization wait for PAYLOAD_RECEIVED_ACK (benign if peer closes)
      try {
        await ackCompleter.future.timeout(const Duration(seconds: 3));
      } catch (_) {}

      return const QsSendResult(
        status: SharingConnectionResponseFrame.statusAccept,
      );
    } finally {
      _activeSocket = null;
      await reader.dispose();
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _recvSharingFrame(
    FrameSocketReader reader,
    QsSecureChannel channel,
  ) async {
    final reassembly = BytesBuilder(copy: false);
    while (true) {
      final offlineBytes = channel.decrypt(await reader.readFrame());
      final frame = OfflineFrame.parse(offlineBytes);
      if (frame.v1?.type != OfflineFrameType.payloadTransfer) continue;
      final pt = frame.v1!.payloadTransfer!;
      if (pt.packetType != PayloadTransferFrame.packetData) continue;
      final chunk = pt.payloadChunk;
      if (chunk == null) continue;
      if (chunk.body.isNotEmpty) {
        reassembly.add(chunk.body);
      }
      if ((chunk.flags & PayloadChunk.flagLastChunk) != 0) {
        return reassembly.toBytes();
      }
    }
  }

  static Uint8List _buildConnectionRequest(
    Uint8List endpointId,
    Uint8List endpointInfo,
  ) {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.connectionRequest,
        connectionRequest: ConnectionRequestFrame(
          endpointId: ascii.decode(endpointId),
          endpointName: latin1.decode(endpointInfo),
          endpointInfo: endpointInfo,
          mediums: [ConnectionRequestFrame.mediumWifiLan],
        ),
      ),
    ).toBytes();
  }

  static Uint8List _buildConnectionResponseAccept() {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.connectionResponse,
        connectionResponse: OfflineConnectionResponseFrame(
          response: OfflineConnectionResponseFrame.statusAccept,
          osInfo: OsInfo(
            type: Platform.isAndroid ? OsInfo.osAndroid : OsInfo.osWindows,
          ),
          safeToDisconnectVersion: 0,
        ),
      ),
    ).toBytes();
  }

  static List<Uint8List> _buildIntroductionFrame(List<_FileToSend> files) {
    final metadata = files.map((f) {
      return SharingFileMetadata(
        name: f.file.name,
        type: _guessFileType(f.file.name),
        payloadId: f.payloadId,
        size: f.file.size,
        mimeType: f.file.mimeType.isNotEmpty
            ? f.file.mimeType
            : 'application/octet-stream',
        id: f.attachmentId,
      );
    }).toList();

    final frame = SharingFrame(
      version: SharingFrame.versionV1,
      v1: SharingV1Frame(
        type: SharingFrameType.introduction,
        introduction: IntroductionFrame(
          fileMetadata: metadata,
          startTransfer: true,
        ),
      ),
    ).toBytes();
    return QsReceiver.wrapOfflineBytesPayload(frame);
  }

  static Uint8List _buildPayloadChunk({
    required int payloadId,
    required int offset,
    required Uint8List body,
    required int totalSize,
    required String fileName,
    required bool isLast,
  }) {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.payloadTransfer,
        payloadTransfer: PayloadTransferFrame(
          packetType: PayloadTransferFrame.packetData,
          payloadHeader: PayloadHeader(
            id: payloadId,
            type: PayloadHeader.typeFile,
            totalSize: totalSize,
            fileName: fileName,
          ),
          payloadChunk: PayloadChunk(
            flags: isLast ? PayloadChunk.flagLastChunk : 0,
            offset: offset,
            body: body,
          ),
        ),
      ),
    ).toBytes();
  }

  static Uint8List _buildPayloadCanceled(int payloadId) {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.payloadTransfer,
        payloadTransfer: PayloadTransferFrame(
          packetType: PayloadTransferFrame.packetControl,
          payloadHeader: PayloadHeader(id: payloadId),
          controlMessage: ControlMessage(
            event: ControlMessage.eventPayloadCanceled,
          ),
        ),
      ),
    ).toBytes();
  }

  static int _guessFileType(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.bmp' =>
        SharingFileType.image,
      '.mp4' || '.mov' || '.mkv' || '.webm' => SharingFileType.video,
      '.mp3' || '.wav' || '.flac' || '.ogg' => SharingFileType.audio,
      '.apk' => SharingFileType.androidApp,
      '.pdf' || '.doc' || '.docx' || '.txt' => SharingFileType.document,
      '.vcf' => SharingFileType.contactCard,
      _ => SharingFileType.unknown,
    };
  }
}

class _FileToSend {
  final StagedFile file;
  final int payloadId;
  final int attachmentId;
  _FileToSend({
    required this.file,
    required this.payloadId,
    required this.attachmentId,
  });
}

