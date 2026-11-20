import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'desktop_bridge.dart';

class NsdDiscoveryEvent {
  final String type; // 'found' or 'lost'
  final String instanceName;
  final String host;
  final int port;
  final String txtN;
  final String txtIpv4;

  const NsdDiscoveryEvent({
    required this.type,
    required this.instanceName,
    this.host = '',
    this.port = 0,
    this.txtN = '',
    this.txtIpv4 = '',
  });

  factory NsdDiscoveryEvent.fromMap(Map<dynamic, dynamic> map) {
    return NsdDiscoveryEvent(
      type: map['type'] as String? ?? 'found',
      instanceName: map['instanceName'] as String? ?? '',
      host: map['host'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ?? 0,
      txtN: map['txtN'] as String? ?? '',
      txtIpv4: map['txtIpv4'] as String? ?? '',
    );
  }
}

class DeviceHardwareInfo {
  final String model;
  final String manufacturer;
  final int sdkInt;

  const DeviceHardwareInfo({
    required this.model,
    required this.manufacturer,
    required this.sdkInt,
  });
}

class PlatformBridge {
  static const _method = MethodChannel('dev.materialdrop.flutter/platform');
  static const _shareChannel =
      EventChannel('dev.materialdrop.flutter/share_events');
  static const _nsdChannel =
      EventChannel('dev.materialdrop.flutter/nsd_events');

  static final PlatformBridge instance = PlatformBridge._();
  PlatformBridge._();

  Stream<ShareLaunchPayload>? _shareStream;
  Stream<NsdDiscoveryEvent>? _nsdStream;

  Future<DeviceHardwareInfo> getDeviceInfo() async {
    if (Platform.isAndroid) {
      try {
        final map = await _method.invokeMapMethod<String, dynamic>('getDeviceInfo');
        if (map != null) {
          return DeviceHardwareInfo(
            model: map['model'] as String? ?? 'Android Phone',
            manufacturer: map['manufacturer'] as String? ?? 'Android',
            sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 33,
          );
        }
      } catch (_) {}
      return const DeviceHardwareInfo(
        model: 'Android Phone',
        manufacturer: 'Android',
        sdkInt: 33,
      );
    }

    final host = Platform.environment['COMPUTERNAME'] ??
        Platform.localHostname;
    return DeviceHardwareInfo(
      model: host.isNotEmpty ? host : 'Windows PC',
      manufacturer: Platform.operatingSystem.toUpperCase(),
      sdkInt: 0,
    );
  }

  Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('acquireMulticastLock');
    } catch (_) {}
  }

  Future<void> releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }

  Future<ShareLaunchPayload?> getInitialSharedFiles() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _method.invokeMapMethod<String, dynamic>('getInitialSharedFiles');
      if (raw == null) return null;
      return _parseShareMap(raw);
    } catch (_) {
      return null;
    }
  }

  Stream<ShareLaunchPayload> get shareIntentStream {
    if (!Platform.isAndroid) {
      return const Stream.empty();
    }
    _shareStream ??= _shareChannel.receiveBroadcastStream().map((event) {
      return _parseShareMap(Map<String, dynamic>.from(event as Map));
    });
    return _shareStream!;
  }

  ShareLaunchPayload _parseShareMap(Map<String, dynamic> map) {
    final filesRaw = map['files'] as List<dynamic>? ?? const [];
    final files = filesRaw.map((entry) {
      final m = Map<String, dynamic>.from(entry as Map);
      return StagedFile(
        name: m['name'] as String? ?? 'file',
        size: (m['size'] as num?)?.toInt() ?? 0,
        mimeType: m['mimeType'] as String? ?? 'application/octet-stream',
        contentUri: m['uri'] as String?,
      );
    }).toList();
    return ShareLaunchPayload(
      isShareSheet: map['isShareSheet'] as bool? ?? false,
      files: files,
      sharedText: map['sharedText'] as String?,
      deepLink: map['deepLink'] as String?,
    );
  }

  Future<bool> shareViaSystemQuickShare(
    List<StagedFile> files, {
    String? text,
  }) async {
    if (!Platform.isAndroid || (files.isEmpty && (text == null || text.isEmpty))) {
      return false;
    }
    try {
      final res = await _method.invokeMethod<bool>('shareViaSystemQuickShare', {
        'files': files
            .map((f) => {
                  'path': f.path,
                  'uri': f.contentUri,
                  'name': f.name,
                  'mimeType': f.mimeType,
                })
            .toList(),
        'text': text,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Streams a [StagedFile] in 64 KiB chunks without loading it into memory.
  Stream<Uint8List> openFileReadStream(
    StagedFile file, {
    int chunkSize = 64 * 1024,
  }) async* {
    if (file.path != null && file.path!.isNotEmpty) {
      final ioFile = File(file.path!);
      if (await ioFile.exists()) {
        await for (final chunk in ioFile.openRead()) {
          if (chunk is Uint8List) {
            yield chunk;
          } else {
            yield Uint8List.fromList(chunk);
          }
        }
        return;
      }
    }

    if (Platform.isAndroid &&
        file.contentUri != null &&
        file.contentUri!.isNotEmpty) {
      final handleId = await _method.invokeMethod<int>('openContentStream', {
        'uri': file.contentUri,
      });
      if (handleId == null) {
        throw StateError('Failed to open content URI ${file.contentUri}');
      }
      try {
        while (true) {
          final chunk = await _method.invokeMethod<Uint8List>(
            'readContentChunk',
            {'handleId': handleId, 'maxBytes': chunkSize},
          );
          if (chunk == null || chunk.isEmpty) break;
          yield chunk;
        }
      } finally {
        try {
          await _method.invokeMethod('closeContentStream', {'handleId': handleId});
        } catch (_) {}
      }
      return;
    }

    throw StateError('No readable path or contentUri for ${file.name}');
  }

  Future<String> getDefaultDownloadDir() async {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) {
        final dl = Directory(p.join(profile, 'Downloads', 'MaterialDrop'));
        await dl.create(recursive: true);
        return dl.path;
      }
    }
    try {
      final dl = await getDownloadsDirectory();
      if (dl != null) {
        final dir = Directory(p.join(dl.path, 'MaterialDrop'));
        await dir.create(recursive: true);
        return dir.path;
      }
    } catch (_) {}
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DOWNLOAD_DIR'];
      if (xdg != null && xdg.isNotEmpty) {
        final dir = Directory(p.join(xdg, 'MaterialDrop'));
        await dir.create(recursive: true);
        return dir.path;
      }
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final dir = Directory(p.join(home, 'Downloads', 'MaterialDrop'));
        await dir.create(recursive: true);
        return dir.path;
      }
    }
    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final fallback = Directory(p.join(baseDir.path, 'MaterialDrop'));
    await fallback.create(recursive: true);
    return fallback.path;
  }

  Future<Directory> getCacheDir() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<String> installApk(String apkPath) async {
    if (!Platform.isAndroid) return 'unsupported';
    try {
      return await _method.invokeMethod<String>('installApk', {
            'path': apkPath,
          }) ??
          'failed';
    } catch (e) {
      return 'error: $e';
    }
  }

  Future<Directory> getTempStagingDir() async {
    Directory tmp;
    try {
      tmp = await getTemporaryDirectory();
    } catch (_) {
      tmp = Directory.systemTemp;
    }
    final dir = Directory(p.join(tmp.path, 'material_drop_staging'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Moves/saves a completed temp file into Downloads (MediaStore on Android Q+).
  Future<String> finalizeReceivedFile({
    required File tempFile,
    required String fileName,
    required String mimeType,
    required String windowsDownloadDir,
  }) async {
    if (Platform.isAndroid) {
      try {
        final res = await _method.invokeMethod<String>('saveToDownloads', {
          'tempPath': tempFile.path,
          'fileName': fileName,
          'mimeType': mimeType,
        });
        if (res != null && res.isNotEmpty) return res;
      } catch (_) {
        // Fall through to app-accessible directory if MediaStore fails in headless test
      }
    }

    final targetDir = Directory(windowsDownloadDir);
    await targetDir.create(recursive: true);
    final destPath = _uniquePath(targetDir.path, fileName);
    try {
      await tempFile.rename(destPath);
    } catch (_) {
      await tempFile.copy(destPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
    return destPath;
  }

  String _uniquePath(String dir, String fileName) {
    var candidate = p.join(dir, fileName);
    if (!File(candidate).existsSync()) return candidate;
    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var counter = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
  }

  Future<void> openFile(String pathOrUri, {String mimeType = '*/*'}) async {
    if (Platform.isAndroid) {
      await _method.invokeMethod('openFile', {
        'pathOrUri': pathOrUri,
        'mimeType': mimeType,
      });
      return;
    }
    if (Platform.isWindows) {
      final normalized = pathOrUri.replaceAll('/', '\\');
      await Process.start('cmd', ['/c', 'start', '', normalized],
          mode: ProcessStartMode.detached);
    }
  }

  Future<void> showInFolder(String pathOrUri, String downloadDir) async {
    if (Platform.isAndroid) {
      await _method.invokeMethod('openDownloadsFolder');
      return;
    }
    if (Platform.isWindows) {
      final normalized = pathOrUri.replaceAll('/', '\\');
      if (normalized.isNotEmpty && File(normalized).existsSync()) {
        await Process.start('explorer.exe', ['/select,$normalized'],
            mode: ProcessStartMode.detached);
      } else {
        await Process.start('explorer.exe', [downloadDir.replaceAll('/', '\\')],
            mode: ProcessStartMode.detached);
      }
    }
  }

  Future<void> copyTextToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> copyFileOrImageToClipboard(String pathOrUri) async {
    if (pathOrUri.isEmpty || Platform.isAndroid) return;
    if (Platform.isWindows || Platform.isLinux) {
      final ext = p.extension(pathOrUri).toLowerCase();
      final isImg = ['.png', '.jpg', '.jpeg', '.bmp', '.webp'].contains(ext);
      if (isImg && File(pathOrUri).existsSync()) {
        final ok = await DesktopBridge.instance.writeImageToClipboard(pathOrUri);
        if (ok) return;
      }
    }
    await Clipboard.setData(ClipboardData(text: pathOrUri));
  }

  Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('requestNotificationPermission');
    } catch (_) {}
  }

  Future<void> startForegroundTransfer(String title, String text) async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('startForegroundTransfer', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  Future<void> stopForegroundTransfer() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('stopForegroundTransfer');
    } catch (_) {}
  }

  Future<void> startNsdDiscovery() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('startNsdDiscovery');
    } catch (_) {}
  }

  Future<void> stopNsdDiscovery() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('stopNsdDiscovery');
    } catch (_) {}
  }

  Stream<NsdDiscoveryEvent> get nsdEvents {
    if (!Platform.isAndroid) return const Stream.empty();
    _nsdStream ??= _nsdChannel.receiveBroadcastStream().map((event) {
      return NsdDiscoveryEvent.fromMap(event as Map);
    });
    return _nsdStream!;
  }

  Future<void> registerNsdService({
    required String instanceName,
    required int port,
    required String txtN,
    required String txtIpv4,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('registerNsdService', {
        'instanceName': instanceName,
        'port': port,
        'txtN': txtN,
        'txtIpv4': txtIpv4,
      });
    } catch (_) {}
  }

  Future<void> unregisterNsdService() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('unregisterNsdService');
    } catch (_) {}
  }

  Future<void> finishActivity() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('finishActivity');
    } catch (_) {}
  }

  Future<String?> findAdbExecutable() async {
    if (!Platform.isWindows) return null;
    const candidates = [
      r'C:\Android\platform-tools\adb.exe',
      r'C:\platform-tools\adb.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    try {
      final res = await Process.run('where.exe', ['adb']);
      if (res.exitCode == 0) {
        final lines = (res.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        if (lines.isNotEmpty) return lines.first;
      }
    } catch (_) {}
    return null;
  }

  /// Returns every non-link-local IPv4 address assigned to ANY local interface
  /// (including VPN/virtual adapters and 127.0.0.1) for strict self-filtering.
  Future<Set<String>> getAllOwnIpv4Addresses() async {
    final ips = <String>{'127.0.0.1', '0.0.0.0'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      for (final intf in interfaces) {
        for (final addr in intf.addresses) {
          ips.add(addr.address);
        }
      }
    } catch (_) {}
    return ips;
  }

  Future<List<String>> getLocalIpv4Addresses() async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer Wi-Fi / Ethernet over virtual or VPN adapters
      interfaces.sort((a, b) {
        int score(NetworkInterface n) {
          final lower = n.name.toLowerCase();
          if (lower.startsWith('wlan') ||
              lower.contains('wi-fi') ||
              lower.contains('wifi') ||
              lower.contains('беспроводн')) {
            return 0;
          }
          if (lower.startsWith('eth') || lower.contains('ethernet')) return 1;
          if (lower.contains('docker') ||
              lower.contains('vmware') ||
              lower.contains('vmnet') ||
              lower.contains('vethernet') ||
              lower.contains('radmin') ||
              lower.contains('tailscale') ||
              lower.contains('zerotier') ||
              lower.contains('hamachi') ||
              lower.contains('veth')) {
            return 9;
          }
          return 3;
        }
        return score(a).compareTo(score(b));
      });
      for (final intf in interfaces) {
        final lower = intf.name.toLowerCase();
        if (lower.startsWith('vmnet') ||
            lower.startsWith('docker') ||
            lower.startsWith('veth') ||
            lower.startsWith('vethernet') ||
            lower.startsWith('virbr') ||
            lower.startsWith('br-') ||
            lower.contains('vmware') ||
            lower.contains('virtualbox') ||
            lower.contains('radmin') ||
            lower.contains('hamachi') ||
            lower.contains('wsl')) {
          continue;
        }
        for (final addr in intf.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
            result.add(addr.address);
          }
        }
      }
    } catch (_) {}
    return result;
  }
}
