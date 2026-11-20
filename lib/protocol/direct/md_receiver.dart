import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import '../gesture/gesture_models.dart';
import 'md_constants.dart';

class MaterialDropReceiver {
  HttpServer? _server;
  Timer? _beaconTimer;
  RawDatagramSocket? _beaconSocket;
  bool _running = false;
  int _boundPort = 0;

  final String instanceId;
  String deviceName;
  String downloadDir;
  final bool treatLoopbackAsUsb;
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
    IncomingTransferItem item,
  ) onCompleted;
  final void Function() onCanceled;
  final void Function(String message) onError;
  final void Function(GesturePreviewEvent event)? onGestureEvent;

  Completer<bool>? _decisionCompleter;

  MaterialDropReceiver({
    required this.deviceName,
    required this.downloadDir,
    this.instanceId = '',
    this.treatLoopbackAsUsb = true,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    required this.onOffer,
    required this.onProgress,
    required this.onCompleted,
    required this.onCanceled,
    required this.onError,
    this.onGestureEvent,
  });

  int get port => _boundPort;
  bool get isRunning => _running;

  Future<void> start({
    int? explicitPort,
    String? bindAddress,
    bool enableBeacon = true,
  }) async {
    if (_running) return;
    _running = true;

    final targetPort = explicitPort ?? MdConstants.localHttpPort;
    final bindIp = (bindAddress != null && bindAddress.isNotEmpty)
        ? (InternetAddress.tryParse(bindAddress) ?? InternetAddress.anyIPv4)
        : InternetAddress.anyIPv4;
    _server = await HttpServer.bind(
      bindIp,
      targetPort,
      shared: true,
    );
    _boundPort = _server!.port;

    _server!.listen((request) {
      unawaited(_handleRequest(request));
    });

    if (enableBeacon) {
      await _startPresenceBeacon();
    }
  }

  Future<void> stop() async {
    _running = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconSocket?.close();
    _beaconSocket = null;
    await _server?.close(force: true);
    _server = null;
    _boundPort = 0;
  }

  void setDecision(bool accept) {
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(accept);
    }
  }

  Future<void> _startPresenceBeacon() async {
    try {
      _beaconSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _beaconSocket?.broadcastEnabled = true;
    } catch (_) {
      return;
    }

    Future<void> sendBeacon() async {
      final sock = _beaconSocket;
      if (sock == null || !_running) return;
      final msg = utf8.encode(jsonEncode({
        'magic': MdConstants.magic,
        'type': 'ping',
        'name': deviceName,
        'port': _boundPort,
        'platform': Platform.isAndroid ? 'Android' : 'Windows',
        if (instanceId.isNotEmpty) 'instanceId': instanceId,
      }));
      final targets = <String>{'255.255.255.255'};
      final ips = await PlatformBridge.instance.getLocalIpv4Addresses();
      for (final ip in ips) {
        final parts = ip.split('.');
        if (parts.length == 4) {
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      for (final b in targets) {
        try {
          sock.send(msg, InternetAddress(b), MdConstants.udpPort);
        } catch (_) {}
      }
    }

    unawaited(sendBeacon());
    _beaconTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_running) unawaited(sendBeacon());
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method.toUpperCase();

    if (path == '/ws/gesture' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      await _handleGestureWebSocket(request);
      return;
    }

    if (method == 'GET' && path == '/ping') {
      final body = jsonEncode({
        'name': deviceName,
        'status': 'online',
        'type': Platform.isAndroid ? 'phone' : 'pc',
        'platform': Platform.isAndroid ? 'Android' : 'Windows',
        if (instanceId.isNotEmpty) 'instanceId': instanceId,
      });
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
      return;
    }

    if (method == 'POST' && path == '/upload') {
      await _handleUpload(request);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handleGestureWebSocket(HttpRequest request) async {
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen(
        (msg) {
          if (msg is String) {
            final parsed = GesturePreviewEvent.fromJsonString(msg);
            if (parsed != null) {
              onGestureEvent?.call(parsed);
            }
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  Future<void> _handleUpload(HttpRequest request) async {
    File? partFile;
    IOSink? sink;

    try {
      final rawRel = request.uri.queryParameters['rel'];
      final relPath = (rawRel != null && rawRel.isNotEmpty)
          ? MdConstants.sanitizeRelativePath(rawRel)
          : null;
      final rawName = request.uri.queryParameters['name'] ??
          (relPath != null ? p.posix.basename(relPath) : 'file');
      final fileName = MdConstants.sanitizeFileName(rawName);
      final senderName = request.uri.queryParameters['device'] ?? 'Peer Device';
      final contentLength = request.headers.contentLength;
      final totalBytes = contentLength > 0 ? contentLength : 0;
      final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
      final isUsb = treatLoopbackAsUsb && remoteIp == '127.0.0.1';
      final trusted = isTrustedFn(senderName, remoteIp);
      final autoAccept =
          autoAcceptAllFn() || isUsb || (trusted && autoAcceptTrustedFn());
      final mime =
          lookupMimeType(fileName) ?? 'application/octet-stream';

      final offer = IncomingOffer(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        senderName: senderName,
        senderAddress: remoteIp,
        protocol: TransferProtocol.materialDrop,
        files: [
          IncomingFileMeta(
            name: fileName,
            size: totalBytes,
            mimeType: mime,
            relativePath: relPath,
          ),
        ],
        texts: const [],
        totalSize: totalBytes,
        isTrusted: trusted,
        isUsb: isUsb,
      );

      onOffer(offer);

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

      if (!accepted) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        onCanceled();
        return;
      }

      final stagingDir = await PlatformBridge.instance.getTempStagingDir();
      partFile = File(
        p.join(
          stagingDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$fileName.part',
        ),
      );
      await partFile.parent.create(recursive: true);
      sink = partFile.openWrite();

      var bytesRead = 0;
      final sw = Stopwatch()..start();
      var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in request) {
        sink.add(chunk);
        bytesRead += chunk.length;

        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 50 ||
            (totalBytes > 0 && bytesRead >= totalBytes)) {
          lastEmit = now;
          final sec = sw.elapsedMilliseconds / 1000.0;
          final speed = sec > 0 ? bytesRead / sec : 0.0;
          onProgress(offer, fileName, bytesRead, totalBytes, speed);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      var targetBaseDir = downloadDir;
      if (!Platform.isAndroid && relPath != null && relPath.contains('/')) {
        final relDir = p.posix.dirname(relPath);
        if (relDir.isNotEmpty && relDir != '.') {
          targetBaseDir = p.joinAll([downloadDir, ...relDir.split('/')]);
        }
      }
      final savedTarget = await PlatformBridge.instance.finalizeReceivedFile(
        tempFile: partFile,
        fileName: fileName,
        mimeType: mime,
        windowsDownloadDir: targetBaseDir,
      );

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"status":"ok"}');
      await request.response.close();

      onCompleted(
        offer,
        IncomingTransferItem(
          name: fileName,
          size: bytesRead,
          mimeType: mime,
          savedPathOrUri: savedTarget,
        ),
      );
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (partFile != null && await partFile.exists()) {
          await partFile.delete();
        }
      } catch (_) {}
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      onError(e.toString());
    }
  }
}
