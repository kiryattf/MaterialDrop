import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import '../direct/md_constants.dart';
import 'proto_codec.dart';
import 'qs_crypto.dart';
import 'qs_framing.dart';
import 'qs_mdns.dart';
import 'qs_mdns_service.dart';
import 'qs_secure_channel.dart';
import 'qs_ukey2.dart';

class _IncomingQsFile {
  final int payloadId;
  final String safeName;
  final int size;
  final String mimeType;
  final File partFile;
  RandomAccessFile? _raf;
  int bytesWritten = 0;
  bool finalized = false;
  String? savedPathOrUri;

  _IncomingQsFile({
    required this.payloadId,
    required this.safeName,
    required this.size,
    required this.mimeType,
    required this.partFile,
  });

  bool get complete => bytesWritten >= size;

  Future<void> open() async {
    await partFile.parent.create(recursive: true);
    _raf = await partFile.open(mode: FileMode.write);
  }

  Future<void> writeChunk(int offset, Uint8List data) async {
    final raf = _raf;
    if (raf == null) return;
    await raf.setPosition(offset);
    await raf.writeFrom(data);
    bytesWritten += data.length;
  }

  Future<void> close() async {
    final raf = _raf;
    _raf = null;
    if (raf != null) {
      await raf.close();
    }
  }

  Future<void> discard() async {
    await close();
    if (await partFile.exists()) {
      await partFile.delete();
    }
  }
}

class _IncomingQsText {
  final int payloadId;
  final String title;
  final String typeName;
  final int size;
  String body = '';
  bool received = false;

  _IncomingQsText({
    required this.payloadId,
    required this.title,
    required this.typeName,
    required this.size,
  });
}

class QsReceiver {
  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSub;
  final QsMdnsService _mdns = QsMdnsService();

  bool _running = false;
  int _port = 0;
  String _advertisedIp = '';

  String deviceName;
  String downloadDir;
  bool Function(String senderName, String senderIp) isTrustedFn;
  bool Function() autoAcceptAllFn;
  bool Function() autoAcceptTrustedFn;

  final void Function(IncomingOffer offer) onOffer;
  final void Function(
    IncomingOffer offer,
    String fileName,
    int bytesReceived,
    int totalBytes,
    double speedBps,
  ) onProgress;
  final void Function(
    IncomingOffer offer,
    List<IncomingTransferItem> items,
    List<IncomingTextItem> texts,
  ) onCompleted;
  final void Function() onCanceled;
  final void Function(String message) onError;

  Completer<bool>? _decisionCompleter;
  bool _userCanceledActive = false;
  QsSecureChannel? _activeChannel;
  Socket? _activeSocket;
  final Map<int, _IncomingQsFile> _activeFiles = {};

  QsReceiver({
    required this.deviceName,
    required this.downloadDir,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    required this.onOffer,
    required this.onProgress,
    required this.onCompleted,
    required this.onCanceled,
    required this.onError,
  });

  int get port => _port;
  String get advertisedIp => _advertisedIp;
  bool get isRunning => _running;

  Future<void> start({bool advertiseMdns = true}) async {
    if (_running) return;
    _running = true;

    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0, shared: true);
    _port = _server!.port;

    final ips = await PlatformBridge.instance.getLocalIpv4Addresses();
    _advertisedIp = ips.isNotEmpty ? ips.first : '127.0.0.1';

    _acceptSub = _server!.listen((socket) {
      unawaited(_handleConnection(socket));
    });

    if (advertiseMdns) {
      await _mdns.startAdvertising(
        deviceName: deviceName,
        port: _port,
        ipAddress: _advertisedIp,
      );
    }
  }

  Future<void> updateAdvertisement() async {
    if (!_running || _port <= 0) return;
    await _mdns.startAdvertising(
      deviceName: deviceName,
      port: _port,
      ipAddress: _advertisedIp,
    );
  }

  Future<void> stop() async {
    _running = false;
    await _mdns.stopAdvertising();
    await _acceptSub?.cancel();
    _acceptSub = null;
    await _server?.close();
    _server = null;
    _port = 0;
  }

  void setDecision(bool accept) {
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(accept);
    }
  }

  Future<void> cancelActiveTransfer() async {
    _userCanceledActive = true;
    final sock = _activeSocket;
    final ch = _activeChannel;
    if (sock != null && ch != null) {
      for (final f in _activeFiles.values) {
        if (!f.complete) {
          try {
            sock.add(packQuickShareFrame(
              ch.encrypt(_buildPayloadCanceled(f.payloadId)),
            ));
          } catch (_) {}
        }
      }
      try {
        await sock.flush();
      } catch (_) {}
    }
    try {
      await sock?.close();
    } catch (_) {}
  }

  Future<void> _handleConnection(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = FrameSocketReader(socket);
    final peerIp = socket.remoteAddress.address;
    final filesById = <int, _IncomingQsFile>{};
    final textsById = <int, _IncomingQsText>{};
    final bytesReassembly = <int, BytesBuilder>{};
    _userCanceledActive = false;

    try {
      final firstFrameBytes = await reader.readFrame(isFirstFrame: true);
      final connReqFrame = OfflineFrame.parse(firstFrameBytes);
      if (connReqFrame.v1?.type != OfflineFrameType.connectionRequest ||
          connReqFrame.v1?.connectionRequest == null) {
        throw Ukey2Exception('Expected ConnectionRequest as first frame');
      }

      final cr = connReqFrame.v1!.connectionRequest!;
      var senderName = 'Quick Share Device';
      if (cr.endpointInfo != null && cr.endpointInfo!.isNotEmpty) {
        final adv = QsMdns.parseEndpointInfo(cr.endpointInfo!);
        if (adv?.deviceName != null && adv!.deviceName!.isNotEmpty) {
          senderName = adv.deviceName!;
        }
      }
      if (senderName == 'Quick Share Device' &&
          cr.endpointName != null &&
          cr.endpointName!.isNotEmpty) {
        senderName = cr.endpointName!;
      }

      final clientInitBytes = await reader.readFrame();
      final handshake = await QsUkey2.runServerHandshake(
        clientInitBytes: clientInitBytes,
        sendServerInit: (serverInitBytes) async {
          socket.add(packQuickShareFrame(serverInitBytes));
          await socket.flush();
        },
        recvClientFinished: () => reader.readFrame(),
      );

      socket.add(packQuickShareFrame(_buildOfflineConnectionResponseAccept()));
      await socket.flush();

      final peerConnRespBytes = await reader.readFrame();
      final peerConnResp = OfflineFrame.parse(peerConnRespBytes);
      if (peerConnResp.v1?.type != OfflineFrameType.connectionResponse) {
        throw Ukey2Exception('Expected peer ConnectionResponse');
      }

      final channel = QsSecureChannel.fromKeys(handshake.keys);
      final pin = handshake.keys.pin;
      _activeChannel = channel;
      _activeSocket = socket;

      Future<void> sendEncrypted(Uint8List offlineFrameBytes) async {
        socket.add(packQuickShareFrame(channel.encrypt(offlineFrameBytes)));
        await socket.flush();
      }

      // Kick off PairedKey exchange immediately after handshake
      for (final f in buildPairedKeyEncryptionFrames()) {
        await sendEncrypted(f);
      }

      IncomingOffer? currentOffer;
      var offerAccepted = false;
      var totalBytes = 0;
      var totalWritten = 0;
      final startedAt = Stopwatch();
      var lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);

      Future<void> finalizeAndCheckComplete() async {
        if (!offerAccepted) return;
        if (!filesById.values.every((f) => f.finalized)) return;
        if (!textsById.values.every((t) => t.received)) return;

        final savedItems = filesById.values
            .map(
              (f) => IncomingTransferItem(
                name: f.safeName,
                size: f.size,
                mimeType: f.mimeType,
                savedPathOrUri: f.savedPathOrUri ?? f.partFile.path,
              ),
            )
            .toList();
        final receivedTexts = textsById.values
            .map(
              (t) => IncomingTextItem(
                title: t.title,
                body: t.body,
                typeName: t.typeName,
              ),
            )
            .toList();

        onCompleted(currentOffer!, savedItems, receivedTexts);
      }

      while (true) {
        Uint8List encryptedBytes;
        try {
          encryptedBytes = await reader.readFrame();
        } on FrameException {
          if (filesById.isNotEmpty || textsById.isNotEmpty) {
            for (final f in filesById.values) {
              if (!f.finalized) await f.discard();
            }
            if (_userCanceledActive) {
              onCanceled();
            } else if (!filesById.values.every((f) => f.finalized) ||
                !textsById.values.every((t) => t.received)) {
              onError('Sender disconnected mid-transfer');
            }
          }
          break;
        }

        final offlineBytes = channel.decrypt(encryptedBytes);
        final frame = OfflineFrame.parse(offlineBytes);
        if (frame.v1?.type != OfflineFrameType.payloadTransfer ||
            frame.v1?.payloadTransfer == null) {
          continue;
        }
        final pt = frame.v1!.payloadTransfer!;
        final header = pt.payloadHeader;
        if (header == null) continue;

        if (pt.packetType == PayloadTransferFrame.packetControl) {
          final ev = pt.controlMessage?.event ?? 0;
          if (ev == ControlMessage.eventPayloadCanceled ||
              ev == ControlMessage.eventPayloadError) {
            for (final f in filesById.values) {
              if (!f.finalized) await f.discard();
            }
            onCanceled();
            break;
          }
          continue;
        }

        if (header.type == PayloadHeader.typeBytes) {
          final chunk = pt.payloadChunk;
          if (chunk == null) continue;
          final isLast = (chunk.flags & PayloadChunk.flagLastChunk) != 0;
          final buf = bytesReassembly.putIfAbsent(
            header.id,
            () => BytesBuilder(copy: false),
          );
          if (chunk.body.isNotEmpty) {
            buf.add(chunk.body);
          }
          if (!isLast) continue;

          final payloadBytes = bytesReassembly.remove(header.id)!.toBytes();
          final textMeta = textsById[header.id];
          if (textMeta != null) {
            textMeta.body = utf8.decode(payloadBytes, allowMalformed: true);
            textMeta.received = true;
            await sendEncrypted(
              _buildPayloadReceivedAck(header.id, payloadBytes.length),
            );
            await finalizeAndCheckComplete();
            if (filesById.values.every((f) => f.finalized) &&
                textsById.values.every((t) => t.received)) {
              break;
            }
            continue;
          }

          final sharingFrame = SharingFrame.parse(payloadBytes);
          final sv1 = sharingFrame.v1;
          if (sv1 == null) continue;

          if (sv1.type == SharingFrameType.pairedKeyEncryption) {
            for (final f in buildPairedKeyResultFrames()) {
              await sendEncrypted(f);
            }
          } else if (sv1.type == SharingFrameType.introduction &&
              sv1.introduction != null) {
            final intro = sv1.introduction!;
            final offerFiles = intro.fileMetadata
                .map(
                  (m) => IncomingFileMeta(
                    name: MdConstants.sanitizeFileName(m.name),
                    size: m.size,
                    mimeType: m.mimeType,
                  ),
                )
                .toList();
            final offerTexts = intro.textMetadata
                .map(
                  (t) => IncomingTextItem(
                    title: t.textTitle,
                    body: '',
                    typeName: t.typeName,
                  ),
                )
                .toList();

            totalBytes = intro.fileMetadata.fold<int>(0, (a, b) => a + b.size);
            final isUsb = peerIp == '127.0.0.1';
            final trusted = isTrustedFn(senderName, peerIp);
            final autoAccept =
                autoAcceptAllFn() || isUsb || (trusted && autoAcceptTrustedFn());

            currentOffer = IncomingOffer(
              id: '${DateTime.now().millisecondsSinceEpoch}',
              senderName: senderName,
              senderAddress: peerIp,
              protocol: TransferProtocol.quickShare,
              pin: pin,
              files: offerFiles,
              texts: offerTexts,
              totalSize: totalBytes,
              isTrusted: trusted,
              isUsb: isUsb,
            );

            onOffer(currentOffer);

            bool accepted;
            if (autoAccept) {
              accepted = true;
            } else {
              _decisionCompleter = Completer<bool>();
              try {
                accepted = await _decisionCompleter!.future
                    .timeout(const Duration(seconds: 45));
              } on TimeoutException {
                accepted = false;
              } finally {
                _decisionCompleter = null;
              }
            }

            offerAccepted = accepted;
            if (accepted) {
              final stagingDir =
                  await PlatformBridge.instance.getTempStagingDir();
              for (final meta in intro.fileMetadata) {
                final safeName = meta.name.isNotEmpty
                    ? MdConstants.sanitizeFileName(meta.name)
                    : 'file-${meta.payloadId}';
                final partFile = File(
                  p.join(
                    stagingDir.path,
                    '${DateTime.now().microsecondsSinceEpoch}_$safeName.part',
                  ),
                );
                final inc = _IncomingQsFile(
                  payloadId: meta.payloadId,
                  safeName: safeName,
                  size: meta.size,
                  mimeType: meta.mimeType,
                  partFile: partFile,
                );
                await inc.open();
                filesById[meta.payloadId] = inc;
                _activeFiles[meta.payloadId] = inc;
              }
              for (final tmeta in intro.textMetadata) {
                textsById[tmeta.payloadId] = _IncomingQsText(
                  payloadId: tmeta.payloadId,
                  title: tmeta.textTitle,
                  typeName: tmeta.typeName,
                  size: tmeta.size,
                );
              }
              startedAt.start();
            }

            for (final rf in buildSharingConnectionResponse(accepted)) {
              await sendEncrypted(rf);
            }
            if (!accepted) {
              onCanceled();
              break;
            }
          }
        } else if (header.type == PayloadHeader.typeFile) {
          final incoming = filesById[header.id];
          if (incoming == null) {
            throw StateError('Unknown FILE payload_id ${header.id}');
          }
          if (incoming.finalized) continue;

          final chunk = pt.payloadChunk;
          if (chunk == null) continue;
          final isLast = (chunk.flags & PayloadChunk.flagLastChunk) != 0;

          if (chunk.body.isNotEmpty) {
            await incoming.writeChunk(chunk.offset, chunk.body);
            totalWritten += chunk.body.length;

            final now = DateTime.now();
            if (now.difference(lastProgressEmit).inMilliseconds >= 60 ||
                totalWritten >= totalBytes) {
              lastProgressEmit = now;
              final elapsedSec = startedAt.elapsedMilliseconds / 1000.0;
              final speed = elapsedSec > 0 ? totalWritten / elapsedSec : 0.0;
              onProgress(
                currentOffer!,
                incoming.safeName,
                totalWritten,
                totalBytes,
                speed,
              );
            }
          }

          if (isLast || incoming.complete) {
            if (incoming.complete) {
              await incoming.close();
              incoming.savedPathOrUri =
                  await PlatformBridge.instance.finalizeReceivedFile(
                tempFile: incoming.partFile,
                fileName: incoming.safeName,
                mimeType: incoming.mimeType,
                windowsDownloadDir: downloadDir,
              );
              incoming.finalized = true;
            } else {
              await incoming.discard();
            }
            await sendEncrypted(
              _buildPayloadReceivedAck(header.id, incoming.bytesWritten),
            );
            await finalizeAndCheckComplete();
            if (filesById.values.every((f) => f.finalized) &&
                textsById.values.every((t) => t.received)) {
              break;
            }
          }
        }
      }
    } on ConnectionClosedImmediately {
      // Benign Windows Quick Share reachability probe — ignore silently
    } catch (e) {
      for (final f in filesById.values) {
        if (!f.finalized) {
          try {
            await f.discard();
          } catch (_) {}
        }
      }
      onError(e.toString());
    } finally {
      _activeChannel = null;
      _activeSocket = null;
      _activeFiles.clear();
      await reader.dispose();
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  static Uint8List _buildOfflineConnectionResponseAccept() {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.connectionResponse,
        connectionResponse: OfflineConnectionResponseFrame(
          response: OfflineConnectionResponseFrame.statusAccept,
          osInfo: OsInfo(
            type: Platform.isAndroid ? OsInfo.osAndroid : OsInfo.osWindows,
          ),
        ),
      ),
    ).toBytes();
  }

  static List<Uint8List> buildPairedKeyEncryptionFrames() {
    final inner = SharingFrame(
      version: SharingFrame.versionV1,
      v1: SharingV1Frame(
        type: SharingFrameType.pairedKeyEncryption,
        pairedKeyEncryption: PairedKeyEncryptionFrame(
          secretIdHash: QsCrypto.randomBytes(6),
          signedData: QsCrypto.randomBytes(72),
        ),
      ),
    ).toBytes();
    return wrapOfflineBytesPayload(inner);
  }

  static List<Uint8List> buildPairedKeyResultFrames() {
    final inner = SharingFrame(
      version: SharingFrame.versionV1,
      v1: SharingV1Frame(
        type: SharingFrameType.pairedKeyResult,
        pairedKeyResult: PairedKeyResultFrame(
          status: PairedKeyResultFrame.statusUnable,
          osType: Platform.isAndroid ? 1 : 4,
        ),
      ),
    ).toBytes();
    return wrapOfflineBytesPayload(inner);
  }

  static List<Uint8List> buildSharingConnectionResponse(bool accept) {
    final inner = SharingFrame(
      version: SharingFrame.versionV1,
      v1: SharingV1Frame(
        type: SharingFrameType.response,
        connectionResponse: SharingConnectionResponseFrame(
          status: accept
              ? SharingConnectionResponseFrame.statusAccept
              : SharingConnectionResponseFrame.statusReject,
        ),
      ),
    ).toBytes();
    return wrapOfflineBytesPayload(inner);
  }

  static Uint8List _buildPayloadReceivedAck(int payloadId, int offset) {
    return OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.payloadTransfer,
        payloadTransfer: PayloadTransferFrame(
          packetType: PayloadTransferFrame.packetControl,
          payloadHeader: PayloadHeader(id: payloadId),
          controlMessage: ControlMessage(
            event: ControlMessage.eventPayloadReceivedAck,
            offset: offset,
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

  static List<Uint8List> wrapOfflineBytesPayload(Uint8List sharingFrameBytes) {
    final payloadId = QsCrypto.randomPositive63BitId();
    final dataFrame = OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.payloadTransfer,
        payloadTransfer: PayloadTransferFrame(
          packetType: PayloadTransferFrame.packetData,
          payloadHeader: PayloadHeader(
            id: payloadId,
            type: PayloadHeader.typeBytes,
            totalSize: sharingFrameBytes.length,
          ),
          payloadChunk: PayloadChunk(
            flags: 0,
            offset: 0,
            body: sharingFrameBytes,
          ),
        ),
      ),
    ).toBytes();

    final terminator = OfflineFrame(
      version: OfflineFrame.versionV1,
      v1: OfflineV1Frame(
        type: OfflineFrameType.payloadTransfer,
        payloadTransfer: PayloadTransferFrame(
          packetType: PayloadTransferFrame.packetData,
          payloadHeader: PayloadHeader(
            id: payloadId,
            type: PayloadHeader.typeBytes,
            totalSize: sharingFrameBytes.length,
          ),
          payloadChunk: PayloadChunk(
            flags: PayloadChunk.flagLastChunk,
            offset: sharingFrameBytes.length,
            body: Uint8List(0),
          ),
        ),
      ),
    ).toBytes();

    return [dataFrame, terminator];
  }
}

