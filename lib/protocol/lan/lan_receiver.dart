import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import '../direct/md_constants.dart';
import 'lan_constants.dart';
import 'tls_identity.dart';

class _PendingLanFile {
  final String id;
  final String rawName;
  final String safeLeafName;
  final String? relativePath;
  final int size;
  final String mimeType;
  final String token;

  _PendingLanFile({
    required this.id,
    required this.rawName,
    required this.safeLeafName,
    required this.relativePath,
    required this.size,
    required this.mimeType,
    required this.token,
  });
}

class _ActiveLanSession {
  final String sessionId;
  final IncomingOffer offer;
  final Map<String, _PendingLanFile> filesById;
  final Set<String> completedFileIds = {};
  final List<IncomingTransferItem> savedItems = [];
  final List<File> partialTempFiles = [];
  int totalBytesReceived = 0;
  bool canceled = false;

  _ActiveLanSession({
    required this.sessionId,
    required this.offer,
    required this.filesById,
  });
}

/// Incoming LAN transfer server implementing the v2 HTTP/HTTPS protocol with streaming I/O.
class LanReceiver {
  HttpServer? _server;
  int _boundPort = 0;
  bool _running = false;
  bool _useHttps = true;

  String deviceName;
  String downloadDir;
  final TlsIdentity identity;
  bool Function(String senderName, String senderIp) isTrustedFn;
  bool Function() autoAcceptAllFn;
  bool Function() autoAcceptTrustedFn;
  void Function(Map<String, dynamic> info, String remoteIp)? onPeerRegistered;
  void Function(IncomingOffer offer) onOffer;
  void Function(
    IncomingOffer offer,
    String fileName,
    int bytesReceived,
    int totalBytes,
    double speedBps,
  ) onProgress;
  void Function(IncomingOffer offer, List<IncomingTransferItem> items)
      onCompleted;
  void Function() onCanceled;
  void Function(String message) onError;

  Completer<bool>? _decisionCompleter;
  _ActiveLanSession? _activeSession;

  LanReceiver({
    required this.deviceName,
    required this.downloadDir,
    required this.identity,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    this.onPeerRegistered,
    required this.onOffer,
    required this.onProgress,
    required this.onCompleted,
    required this.onCanceled,
    required this.onError,
  });

  int get port => _boundPort;
  bool get isRunning => _running;
  bool get useHttps => _useHttps;

  Map<String, dynamic> buildInfoDto() {
    return {
      'alias': deviceName,
      'version': LanConstants.protocolVersion,
      'deviceModel': LanConstants.localDeviceModel,
      'deviceType': LanConstants.localDeviceType,
      'fingerprint': identity.fingerprint,
      'port': _boundPort,
      'protocol': _useHttps ? 'https' : 'http',
      'download': false,
    };
  }

  Future<void> start({
    int? explicitPort,
    String? bindAddress,
    bool useHttps = true,
  }) async {
    if (_running) return;
    _useHttps = useHttps;
    final host = (bindAddress != null && bindAddress.isNotEmpty)
        ? InternetAddress(bindAddress)
        : InternetAddress.anyIPv4;
    final targetPort = explicitPort ?? LanConstants.defaultPort;

    Future<HttpServer> bindPort(int pNum) {
      if (_useHttps) {
        return HttpServer.bindSecure(
          host,
          pNum,
          identity.createSecurityContext(),
          shared: !Platform.isWindows,
        );
      }
      return HttpServer.bind(
        host,
        pNum,
        shared: !Platform.isWindows,
      );
    }

    try {
      _server = await bindPort(targetPort);
    } on SocketException {
      _server = await bindPort(0);
    }
    _boundPort = _server!.port;
    _running = true;

    _server!.listen(
      _handleRequest,
      onError: (_) {},
    );
  }

  Future<void> stop() async {
    _running = false;
    await _cancelActiveSession();
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(false);
    }
    await _server?.close(force: true);
    _server = null;
  }

  void setDecision(bool accepted) {
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(accepted);
    }
  }

  Future<void> cancelActive() async {
    await _cancelActiveSession();
    onCanceled();
  }

  Future<void> _cancelActiveSession() async {
    final s = _activeSession;
    if (s == null) return;
    s.canceled = true;
    for (final pf in s.partialTempFiles) {
      try {
        if (await pf.exists()) await pf.delete();
      } catch (_) {}
    }
    _activeSession = null;
  }

  String _randomToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return TlsIdentity.bytesToUpperHex(bytes);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method.toUpperCase();

    try {
      if (method == 'GET' && path == LanConstants.pathInfo) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(buildInfoDto()));
        await request.response.close();
        return;
      }

      if (method == 'POST' && path == LanConstants.pathRegister) {
        final rawBody = await utf8.decodeStream(request);
        if (rawBody.isNotEmpty) {
          final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
          final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
          onPeerRegistered?.call(decoded, remoteIp);
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(buildInfoDto()));
        await request.response.close();
        return;
      }

      if (method == 'POST' && path == LanConstants.pathPrepareUpload) {
        await _handlePrepareUpload(request);
        return;
      }

      if (method == 'POST' && path == LanConstants.pathUpload) {
        await _handleUpload(request);
        return;
      }

      if (method == 'POST' && path == LanConstants.pathCancel) {
        final sid = request.uri.queryParameters['sessionId'];
        if (sid != null && _activeSession?.sessionId == sid) {
          await _cancelActiveSession();
          onCanceled();
        }
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      onError(e.toString());
    }
  }

  Future<void> _handlePrepareUpload(HttpRequest request) async {
    if (_activeSession != null && !_activeSession!.canceled) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }

    final raw = await utf8.decodeStream(request);
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final info = (payload['info'] as Map<String, dynamic>?) ?? const {};
    final filesRaw = (payload['files'] as Map<String, dynamic>?) ?? const {};

    final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
    final senderName = (info['alias'] as String? ?? 'Device').trim();
    if (filesRaw.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final filesMap = <String, _PendingLanFile>{};
    final metaList = <IncomingFileMeta>[];
    final tokenResponse = <String, String>{};
    var totalSize = 0;

    for (final entry in filesRaw.entries) {
      final fMap = entry.value as Map<String, dynamic>;
      final id = (fMap['id'] as String? ?? entry.key).trim();
      final rawName = fMap['fileName'] as String? ?? 'file';
      final size = (fMap['size'] as num?)?.toInt() ?? 0;
      final mime =
          fMap['fileType'] as String? ?? 'application/octet-stream';

      final sanitizedRel = rawName.contains('/') || rawName.contains('\\')
          ? MdConstants.sanitizeRelativePath(rawName)
          : null;
      final leafName = MdConstants.sanitizeFileName(rawName);
      final token = _randomToken();

      filesMap[id] = _PendingLanFile(
        id: id,
        rawName: rawName,
        safeLeafName: leafName,
        relativePath: sanitizedRel,
        size: size,
        mimeType: mime,
        token: token,
      );
      metaList.add(
        IncomingFileMeta(
          name: leafName,
          size: size,
          mimeType: mime,
          relativePath: sanitizedRel,
        ),
      );
      tokenResponse[id] = token;
      totalSize += size;
    }

    final sessionId = _randomToken();
    final trusted = isTrustedFn(senderName, remoteIp);
    final offer = IncomingOffer(
      id: 'lan_$sessionId',
      senderName: senderName.isEmpty ? 'Device' : senderName,
      senderAddress: remoteIp,
      protocol: TransferProtocol.lan,
      files: metaList,
      texts: const [],
      totalSize: totalSize,
      isTrusted: trusted,
      isUsb: false,
    );

    final autoAccept =
        autoAcceptAllFn() || (trusted && autoAcceptTrustedFn());

    var accepted = autoAccept;
    if (!autoAccept) {
      _decisionCompleter = Completer<bool>();
      onOffer(offer);
      try {
        accepted = await _decisionCompleter!.future
            .timeout(const Duration(seconds: 60), onTimeout: () => false);
      } finally {
        _decisionCompleter = null;
      }
    } else {
      onOffer(offer);
    }

    if (!accepted) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      onCanceled();
      return;
    }

    _activeSession = _ActiveLanSession(
      sessionId: sessionId,
      offer: offer,
      filesById: filesMap,
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'sessionId': sessionId,
      'files': tokenResponse,
    }));
    await request.response.close();
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final sid = request.uri.queryParameters['sessionId'];
    final fileId = request.uri.queryParameters['fileId'];
    final token = request.uri.queryParameters['token'];

    final session = _activeSession;
    if (session == null ||
        session.canceled ||
        sid == null ||
        fileId == null ||
        token == null ||
        session.sessionId != sid) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    final pending = session.filesById[fileId];
    if (pending == null || pending.token != token) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    File? partFile;
    try {
      final stagingDir = await PlatformBridge.instance.getTempStagingDir();
      partFile = File(
        p.join(
          stagingDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_${pending.safeLeafName}.part',
        ),
      );
      session.partialTempFiles.add(partFile);

      final sink = partFile.openWrite();
      var fileBytes = 0;
      final sw = Stopwatch()..start();
      var lastNotifyMs = 0;

      try {
        await for (final chunk in request) {
          if (session.canceled) {
            throw StateError('Transfer canceled');
          }
          sink.add(chunk);
          fileBytes += chunk.length;
          session.totalBytesReceived += chunk.length;

          final elapsedMs = sw.elapsedMilliseconds;
          if (elapsedMs - lastNotifyMs >= 80) {
            lastNotifyMs = elapsedMs;
            final bps = elapsedMs > 0
                ? session.totalBytesReceived / (elapsedMs / 1000.0)
                : 0.0;
            onProgress(
              session.offer,
              pending.safeLeafName,
              session.totalBytesReceived,
              session.offer.totalSize > 0
                  ? session.offer.totalSize
                  : fileBytes,
              bps,
            );
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      var targetBaseDir = downloadDir;
      final relPath = pending.relativePath;
      if (!Platform.isAndroid && relPath != null && relPath.contains('/')) {
        final relDir = p.posix.dirname(relPath);
        if (relDir.isNotEmpty && relDir != '.') {
          targetBaseDir = p.joinAll([downloadDir, ...relDir.split('/')]);
        }
      }

      final savedTarget = await PlatformBridge.instance.finalizeReceivedFile(
        tempFile: partFile,
        fileName: pending.safeLeafName,
        mimeType: pending.mimeType,
        windowsDownloadDir: targetBaseDir,
      );

      final item = IncomingTransferItem(
        name: pending.safeLeafName,
        size: fileBytes,
        mimeType: pending.mimeType,
        savedPathOrUri: savedTarget,
      );
      session.savedItems.add(item);
      session.completedFileIds.add(fileId);

      onProgress(
        session.offer,
        pending.safeLeafName,
        session.totalBytesReceived,
        session.offer.totalSize > 0 ? session.offer.totalSize : fileBytes,
        0,
      );

      request.response.statusCode = HttpStatus.ok;
      await request.response.close();

      if (session.completedFileIds.length >= session.filesById.length) {
        final finishedItems = List<IncomingTransferItem>.of(session.savedItems);
        final finishedOffer = session.offer;
        _activeSession = null;
        onCompleted(finishedOffer, finishedItems);
      }
    } catch (e) {
      if (partFile != null) {
        try {
          if (await partFile.exists()) await partFile.delete();
        } catch (_) {}
      }
      if (!session.canceled) {
        _activeSession = null;
        onError(e.toString());
      }
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }
}
