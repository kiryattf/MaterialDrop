import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_bridge.dart';
import 'platform_bridge.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  readyToInstall,
  installing,
  error,
}

enum UpdateInstallResult {
  launched,
  needsPermission,
  restarting,
  savedToDownloads,
  failed,
}

enum UpdatePlatformTarget {
  android,
  windows,
  linux,
  unsupported;

  String? get assetFileName => switch (this) {
        UpdatePlatformTarget.android => 'android-arm64.apk',
        UpdatePlatformTarget.windows => 'windows-x64.zip',
        UpdatePlatformTarget.linux => 'linux-x64.AppImage',
        UpdatePlatformTarget.unsupported => null,
      };
}

class SemVer implements Comparable<SemVer> {
  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  const SemVer(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease,
  });

  static SemVer? tryParse(String raw) {
    var clean = raw.trim();
    if (clean.isEmpty) return null;
    if (clean.startsWith('v') || clean.startsWith('V')) {
      clean = clean.substring(1).trim();
    }
    final plusIdx = clean.indexOf('+');
    if (plusIdx >= 0) {
      clean = clean.substring(0, plusIdx);
    }
    String? pre;
    final dashIdx = clean.indexOf('-');
    if (dashIdx >= 0) {
      pre = clean.substring(dashIdx + 1).trim();
      if (pre.isEmpty) pre = null;
      clean = clean.substring(0, dashIdx);
    }
    final parts = clean.split('.');
    if (parts.length < 2 || parts.length > 3) return null;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length == 3 ? int.tryParse(parts[2]) : 0;
    if (major == null || minor == null || patch == null) return null;
    if (major < 0 || minor < 0 || patch < 0) return null;
    return SemVer(major, minor, patch, preRelease: pre);
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // Stable release > pre-release with same major.minor.patch
    if (preRelease == null && other.preRelease != null) return 1;
    if (preRelease != null && other.preRelease == null) return -1;
    if (preRelease != null && other.preRelease != null) {
      return preRelease!.compareTo(other.preRelease!);
    }
    return 0;
  }

  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  String toString() => preRelease == null
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-$preRelease';

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      preRelease == other.preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);
}

class ReleaseAssetInfo {
  final String name;
  final String downloadUrl;
  final int size;

  const ReleaseAssetInfo({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  factory ReleaseAssetInfo.fromJson(Map<String, dynamic> json) {
    return ReleaseAssetInfo(
      name: json['name'] as String? ?? '',
      downloadUrl: json['browser_download_url'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'browser_download_url': downloadUrl,
        'size': size,
      };
}

class ReleaseInfo {
  final String tagName;
  final SemVer version;
  final String name;
  final String body;
  final DateTime? publishedAt;
  final String htmlUrl;
  final List<ReleaseAssetInfo> assets;

  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.htmlUrl,
    required this.assets,
  });

  ReleaseAssetInfo? findAsset(String fileName) {
    final target = fileName.toLowerCase();
    for (final asset in assets) {
      if (asset.name.toLowerCase() == target) return asset;
    }
    return null;
  }

  static ReleaseInfo? fromGitHubJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    final ver = SemVer.tryParse(tag);
    if (ver == null) return null;
    final rawAssets = (json['assets'] as List?) ?? const [];
    final assets = rawAssets
        .whereType<Map>()
        .map((e) => ReleaseAssetInfo.fromJson(Map<String, dynamic>.from(e)))
        .where((a) => a.name.isNotEmpty && a.downloadUrl.isNotEmpty)
        .toList(growable: false);

    return ReleaseInfo(
      tagName: tag,
      version: ver,
      name: (json['name'] as String? ?? tag).trim(),
      body: (json['body'] as String? ?? '').trim(),
      publishedAt: json['published_at'] is String
          ? DateTime.tryParse(json['published_at'] as String)
          : null,
      htmlUrl: json['html_url'] as String? ?? '',
      assets: assets,
    );
  }

  Map<String, dynamic> toJson() => {
        'tag_name': tagName,
        'name': name,
        'body': body,
        'published_at': publishedAt?.toIso8601String(),
        'html_url': htmlUrl,
        'assets': assets.map((a) => a.toJson()).toList(growable: false),
      };
}

class ChecksumsManifest {
  final Map<String, String> hashes;

  const ChecksumsManifest(this.hashes);

  static final _shaLineRe = RegExp(
    r'^([a-fA-F0-9]{64})\s+[* ]?(.+?)\s*$',
  );

  static ChecksumsManifest parse(String content) {
    final map = <String, String>{};
    for (final line in const LineSplitter().convert(content)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final m = _shaLineRe.firstMatch(trimmed);
      if (m == null) continue;
      final digest = m.group(1)!.toLowerCase();
      var rawFile = m.group(2)!.trim();
      if (rawFile.startsWith('./')) {
        rawFile = rawFile.substring(2);
      }
      map[rawFile.toLowerCase()] = digest;
      final base = p.posix.basename(rawFile.replaceAll('\\', '/')).toLowerCase();
      if (base.isNotEmpty) {
        map.putIfAbsent(base, () => digest);
      }
    }
    return ChecksumsManifest(map);
  }

  String? hashForAsset(String assetName) {
    return hashes[assetName.toLowerCase()];
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class UpdateService extends ChangeNotifier {
  static const String currentVersionRaw = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.0.0',
  );
  static const String defaultLatestReleaseUrl =
      'https://api.github.com/repos/kiryattf/MaterialDrop/releases/latest';

  static const _kEtagKey = 'md_update_etag';
  static const _kLastCheckMsKey = 'md_update_last_check_ms';
  static const _kCachedReleaseJsonKey = 'md_update_cached_release_json';

  final String latestReleaseUrl;
  final HttpClient Function() _httpClientFactory;
  final UpdatePlatformTarget? platformOverride;
  final String? stagingDirOverride;
  final String? appBundleDirOverride;
  final String? appImageEnvOverride;
  final String? downloadsDirOverride;
  final bool skipProcessExitForTest;
  final SharedPreferences? initialPrefs;

  late final SemVer currentVersion;
  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _bannerDismissed = false;

  UpdatePhase _phase = UpdatePhase.idle;
  ReleaseInfo? _latestRelease;
  DateTime? _lastCheckedAt;
  double _downloadProgress = 0.0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  String? _readyFilePath;
  String? _verifiedSha256;
  String? _errorCode;
  String? _errorDetail;

  UpdateService({
    this.initialPrefs,
    String? currentVersionOverride,
    this.latestReleaseUrl = defaultLatestReleaseUrl,
    HttpClient Function()? httpClientFactory,
    this.platformOverride,
    this.stagingDirOverride,
    this.appBundleDirOverride,
    this.appImageEnvOverride,
    this.downloadsDirOverride,
    this.skipProcessExitForTest = false,
  }) : _httpClientFactory = httpClientFactory ?? _defaultHttpClient {
    currentVersion = SemVer.tryParse(currentVersionOverride ?? currentVersionRaw) ??
        const SemVer(2, 0, 0);
  }

  static HttpClient _defaultHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    return client;
  }

  UpdatePlatformTarget get platformTarget {
    if (platformOverride != null) return platformOverride!;
    if (Platform.isAndroid) return UpdatePlatformTarget.android;
    if (Platform.isWindows) return UpdatePlatformTarget.windows;
    if (Platform.isLinux) return UpdatePlatformTarget.linux;
    return UpdatePlatformTarget.unsupported;
  }

  UpdatePhase get phase => _phase;
  ReleaseInfo? get latestRelease => _latestRelease;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  double get downloadProgress => _downloadProgress;
  int get downloadedBytes => _downloadedBytes;
  int get totalBytes => _totalBytes;
  String? get readyFilePath => _readyFilePath;
  String? get verifiedSha256 => _verifiedSha256;
  String? get errorCode => _errorCode;
  String? get errorDetail => _errorDetail;
  bool get isBusy =>
      _phase == UpdatePhase.checking ||
      _phase == UpdatePhase.downloading ||
      _phase == UpdatePhase.verifying ||
      _phase == UpdatePhase.installing;

  bool get hasUpdate =>
      _latestRelease != null && _latestRelease!.version > currentVersion;

  bool get shouldShowBanner => hasUpdate && !_bannerDismissed;

  void dismissBanner() {
    _bannerDismissed = true;
    notifyListeners();
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _prefs ??= initialPrefs ?? await SharedPreferences.getInstance();

    final lastMs = _prefs!.getInt(_kLastCheckMsKey);
    if (lastMs != null && lastMs > 0) {
      _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }

    final cachedJsonStr = _prefs!.getString(_kCachedReleaseJsonKey);
    if (cachedJsonStr != null && cachedJsonStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedJsonStr);
        if (decoded is Map<String, dynamic>) {
          final parsed = ReleaseInfo.fromGitHubJson(decoded);
          if (parsed != null) {
            _latestRelease = parsed;
            _phase = parsed.version > currentVersion
                ? UpdatePhase.available
                : UpdatePhase.upToDate;
          }
        }
      } catch (_) {
        // Ignore corrupt cache entry and wait for next refresh
      }
    }
    notifyListeners();
  }

  Future<void> checkInBackgroundIfDue({
    Duration interval = const Duration(hours: 12),
  }) async {
    await init();
    if (_lastCheckedAt != null &&
        DateTime.now().difference(_lastCheckedAt!) < interval) {
      return;
    }
    await checkForUpdates(force: false);
  }

  Future<ReleaseInfo?> checkForUpdates({bool force = false}) async {
    await init();
    if (isBusy) return _latestRelease;

    _errorCode = null;
    _errorDetail = null;
    _phase = UpdatePhase.checking;
    notifyListeners();

    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(latestReleaseUrl);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'MaterialDrop/$currentVersion',
      );
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');

      final cachedEtag = _prefs?.getString(_kEtagKey);
      if (cachedEtag != null &&
          cachedEtag.isNotEmpty &&
          _latestRelease != null) {
        req.headers.set(HttpHeaders.ifNoneMatchHeader, cachedEtag);
      }

      final resp = await req.close().timeout(const Duration(seconds: 20));
      final now = DateTime.now();

      if (resp.statusCode == HttpStatus.notModified && _latestRelease != null) {
        await resp.drain<void>();
        _lastCheckedAt = now;
        await _prefs?.setInt(_kLastCheckMsKey, now.millisecondsSinceEpoch);
        _phase = hasUpdate ? UpdatePhase.available : UpdatePhase.upToDate;
        notifyListeners();
        return _latestRelease;
      }

      final bodyText = await utf8.decodeStream(resp);
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException(
          'HTTP ${resp.statusCode}',
          uri: uri,
        );
      }

      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid release payload');
      }
      final parsed = ReleaseInfo.fromGitHubJson(decoded);
      if (parsed == null) {
        throw const FormatException('Missing valid tag_name');
      }

      _latestRelease = parsed;
      _lastCheckedAt = now;
      await _prefs?.setInt(_kLastCheckMsKey, now.millisecondsSinceEpoch);
      await _prefs?.setString(_kCachedReleaseJsonKey, jsonEncode(parsed.toJson()));

      final newEtag = resp.headers.value(HttpHeaders.etagHeader);
      if (newEtag != null && newEtag.isNotEmpty) {
        await _prefs?.setString(_kEtagKey, newEtag);
      }

      if (parsed.version > currentVersion) {
        _bannerDismissed = false;
        _phase = UpdatePhase.available;
      } else {
        _readyFilePath = null;
        _verifiedSha256 = null;
        _phase = UpdatePhase.upToDate;
      }
      notifyListeners();
      return _latestRelease;
    } catch (e) {
      if (!force && _latestRelease != null) {
        _phase = hasUpdate ? UpdatePhase.available : UpdatePhase.upToDate;
      } else {
        _errorCode = 'update_check_failed';
        _errorDetail = e.toString();
        _phase = UpdatePhase.error;
      }
      notifyListeners();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> downloadAndVerify({String? targetAssetOverride}) async {
    final release = _latestRelease;
    if (release == null) {
      _setError('update_no_release');
      return false;
    }

    final assetName = targetAssetOverride ?? platformTarget.assetFileName;
    if (assetName == null) {
      _setError('update_unsupported_platform');
      return false;
    }

    final asset = release.findAsset(assetName);
    if (asset == null) {
      _setError('update_asset_missing', detail: assetName);
      return false;
    }

    final checksumsAsset = release.findAsset('checksums.txt');
    if (checksumsAsset == null) {
      _setError('update_checksum_missing');
      return false;
    }

    _errorCode = null;
    _errorDetail = null;
    _readyFilePath = null;
    _verifiedSha256 = null;
    _downloadProgress = 0.0;
    _downloadedBytes = 0;
    _totalBytes = asset.size;
    _phase = UpdatePhase.downloading;
    notifyListeners();

    final client = _httpClientFactory();
    File? partFile;
    try {
      // 1. Fetch checksums.txt first so we never execute unverified binaries
      final checksumReq = await client.getUrl(Uri.parse(checksumsAsset.downloadUrl));
      checksumReq.headers.set(
        HttpHeaders.userAgentHeader,
        'MaterialDrop/$currentVersion',
      );
      final checksumResp =
          await checksumReq.close().timeout(const Duration(seconds: 20));
      if (checksumResp.statusCode != HttpStatus.ok) {
        await checksumResp.drain<void>();
        _setError(
          'update_checksum_missing',
          detail: 'HTTP ${checksumResp.statusCode}',
        );
        return false;
      }
      final checksumsText = await utf8.decodeStream(checksumResp);
      final manifest = ChecksumsManifest.parse(checksumsText);
      final expectedHash = manifest.hashForAsset(asset.name);
      if (expectedHash == null || expectedHash.length != 64) {
        _setError('update_checksum_missing', detail: asset.name);
        return false;
      }

      // 2. Stream platform package into temp directory while hashing incrementally
      final stageDir = await _resolveStagingDir();
      final finalFile = File(p.join(stageDir.path, asset.name));
      partFile = File('${finalFile.path}.part');
      if (await partFile.exists()) await partFile.delete();
      if (await finalFile.exists()) await finalFile.delete();

      final pkgReq = await client.getUrl(Uri.parse(asset.downloadUrl));
      pkgReq.headers.set(
        HttpHeaders.userAgentHeader,
        'MaterialDrop/$currentVersion',
      );
      final pkgResp = await pkgReq.close().timeout(const Duration(seconds: 30));
      if (pkgResp.statusCode != HttpStatus.ok) {
        await pkgResp.drain<void>();
        _setError(
          'update_download_failed',
          detail: 'HTTP ${pkgResp.statusCode}',
        );
        return false;
      }

      final expectedLen =
          pkgResp.contentLength > 0 ? pkgResp.contentLength : asset.size;
      _totalBytes = expectedLen;

      final digestSink = _DigestSink();
      final hashConversion = sha256.startChunkedConversion(digestSink);
      final fileSink = partFile.openWrite();
      var received = 0;
      var lastNotifyMs = 0;

      try {
        await for (final chunk in pkgResp) {
          fileSink.add(chunk);
          hashConversion.add(chunk);
          received += chunk.length;
          _downloadedBytes = received;
          if (_totalBytes > 0) {
            _downloadProgress = (received / _totalBytes).clamp(0.0, 1.0);
          }
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastNotifyMs >= 80) {
            lastNotifyMs = nowMs;
            notifyListeners();
          }
        }
        await fileSink.flush();
      } finally {
        await fileSink.close();
      }
      hashConversion.close();

      _phase = UpdatePhase.verifying;
      _downloadProgress = 1.0;
      notifyListeners();

      final actualHash = digestSink.value?.toString().toLowerCase() ?? '';
      if (actualHash != expectedHash.toLowerCase()) {
        if (await partFile.exists()) await partFile.delete();
        _setError(
          'update_sha_mismatch',
          detail: '$actualHash != $expectedHash',
        );
        return false;
      }

      await partFile.rename(finalFile.path);
      _readyFilePath = finalFile.path;
      _verifiedSha256 = actualHash;
      _phase = UpdatePhase.readyToInstall;
      notifyListeners();
      return true;
    } catch (e) {
      if (partFile != null && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      _setError('update_download_failed', detail: e.toString());
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<UpdateInstallResult> installDownloadedUpdate() async {
    final filePath = _readyFilePath;
    final expectedSha = _verifiedSha256;
    if (filePath == null || expectedSha == null) {
      _setError('update_no_release');
      return UpdateInstallResult.failed;
    }

    final pkgFile = File(filePath);
    if (!await pkgFile.exists()) {
      _setError('update_asset_missing');
      return UpdateInstallResult.failed;
    }

    _phase = UpdatePhase.installing;
    _errorCode = null;
    _errorDetail = null;
    notifyListeners();

    try {
      // Re-verify SHA256 on disk right before executing/replacing
      final onDiskSha = await _computeFileSha256(pkgFile);
      if (onDiskSha != expectedSha.toLowerCase()) {
        await pkgFile.delete();
        _readyFilePath = null;
        _setError('update_sha_mismatch');
        return UpdateInstallResult.failed;
      }

      switch (platformTarget) {
        case UpdatePlatformTarget.android:
          final res = await PlatformBridge.instance.installApk(pkgFile.path);
          if (res == 'needs_permission') {
            _phase = UpdatePhase.readyToInstall;
            notifyListeners();
            return UpdateInstallResult.needsPermission;
          }
          if (res == 'launched') {
            _phase = UpdatePhase.readyToInstall;
            notifyListeners();
            return UpdateInstallResult.launched;
          }
          _setError('update_install_failed', detail: res);
          return UpdateInstallResult.failed;

        case UpdatePlatformTarget.windows:
          return await _installWindowsBundle(pkgFile);

        case UpdatePlatformTarget.linux:
          return await _installLinuxAppImage(pkgFile);

        case UpdatePlatformTarget.unsupported:
          _setError('update_unsupported_platform');
          return UpdateInstallResult.failed;
      }
    } catch (e) {
      _setError('update_install_failed', detail: e.toString());
      return UpdateInstallResult.failed;
    }
  }

  Future<UpdateInstallResult> _installWindowsBundle(File zipFile) async {
    final stageRoot = Directory(
      p.join(
        zipFile.parent.path,
        'win_stage_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    if (await stageRoot.exists()) {
      await stageRoot.delete(recursive: true);
    }
    await stageRoot.create(recursive: true);

    final extractRes = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Expand-Archive -LiteralPath '${_psEscape(zipFile.path)}' -DestinationPath '${_psEscape(stageRoot.path)}' -Force",
    ]);
    if (extractRes.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        ['Expand-Archive'],
        '${extractRes.stderr}',
        extractRes.exitCode,
      );
    }

    final bundleSource = _locateExeDir(stageRoot, 'material_drop.exe');
    if (bundleSource == null) {
      throw StateError('windows-x64.zip missing material_drop.exe');
    }

    final targetAppDir =
        appBundleDirOverride ?? File(Platform.resolvedExecutable).parent.path;
    final exePath = p.join(targetAppDir, 'material_drop.exe');
    final scriptFile = File(
      p.join(zipFile.parent.path, 'md_apply_update_$pid.ps1'),
    );

    final waitBlock = skipProcessExitForTest
        ? ''
        : '''
\$appPid = $pid
for (\$i = 0; \$i -lt 120; \$i++) {
  if (-not (Get-Process -Id \$appPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 250
}
''';
    final relaunchBlock = skipProcessExitForTest
        ? ''
        : '''
if (Test-Path -LiteralPath '${_psEscape(exePath)}') {
  Start-Process -FilePath '${_psEscape(exePath)}'
}
''';

    final scriptBody = '''
\$ErrorActionPreference = 'Stop'
$waitBlock
\$src = '${_psEscape(bundleSource.path)}'
\$dst = '${_psEscape(targetAppDir)}'
\$srcData = Join-Path \$src 'data'
\$dstData = Join-Path \$dst 'data'
if (Test-Path -LiteralPath \$srcData) {
  if (Test-Path -LiteralPath \$dstData) {
    Remove-Item -LiteralPath \$dstData -Recurse -Force
  }
  Copy-Item -LiteralPath \$srcData -Destination \$dstData -Recurse -Force
}
Get-ChildItem -LiteralPath \$src | Where-Object { \$_.Name -ne 'data' } | ForEach-Object {
  Copy-Item -LiteralPath \$_.FullName -Destination (Join-Path \$dst \$_.Name) -Recurse -Force
}
$relaunchBlock
Remove-Item -LiteralPath '${_psEscape(stageRoot.path)}' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath '${_psEscape(zipFile.path)}' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
''';

    // UTF-8 with BOM ensures Windows PowerShell 5.1 reads non-ASCII paths cleanly
    await scriptFile.writeAsBytes(
      <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(scriptBody)],
      flush: true,
    );

    if (skipProcessExitForTest) {
      // Execute synchronously in test harness so we verify bundle swap without killing test VM
      final runRes = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]);
      if (runRes.exitCode != 0) {
        throw ProcessException(
          'powershell.exe',
          [scriptFile.path],
          '${runRes.stderr}',
          runRes.exitCode,
        );
      }
      _phase = UpdatePhase.upToDate;
      notifyListeners();
      return UpdateInstallResult.restarting;
    }

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.detached,
    );

    _scheduleGracefulShutdown();
    return UpdateInstallResult.restarting;
  }

  Future<UpdateInstallResult> _installLinuxAppImage(File newAppImage) async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', newAppImage.path]);
    }

    final appImagePath =
        (appImageEnvOverride ?? Platform.environment['APPIMAGE'] ?? '').trim();

    if (appImagePath.isNotEmpty) {
      final targetFile = File(appImagePath);
      final targetDir = targetFile.parent;
      final siblingStage = File(
        p.join(targetDir.path, '.${p.basename(appImagePath)}.new.$pid'),
      );
      if (await siblingStage.exists()) await siblingStage.delete();
      await newAppImage.copy(siblingStage.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', siblingStage.path]);
      }
      // Same-directory rename uses atomic POSIX rename(2)
      await siblingStage.rename(targetFile.path);
      try {
        await newAppImage.delete();
      } catch (_) {}

      if (!skipProcessExitForTest) {
        await Process.start(
          targetFile.path,
          const [],
          mode: ProcessStartMode.detached,
        );
        _scheduleGracefulShutdown();
      } else {
        _phase = UpdatePhase.upToDate;
        notifyListeners();
      }
      return UpdateInstallResult.restarting;
    }

    // Fallback when running outside AppImage: place executable AppImage in Downloads
    final dlDir =
        downloadsDirOverride ?? await PlatformBridge.instance.getDefaultDownloadDir();
    await Directory(dlDir).create(recursive: true);
    final destName = _latestRelease != null
        ? 'MaterialDrop-${_latestRelease!.tagName}-linux-x64.AppImage'
        : 'MaterialDrop-linux-x64.AppImage';
    final destFile = File(p.join(dlDir, destName));
    if (await destFile.exists()) await destFile.delete();
    try {
      await newAppImage.rename(destFile.path);
    } catch (_) {
      await newAppImage.copy(destFile.path);
      await newAppImage.delete();
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', destFile.path]);
    }
    if (!skipProcessExitForTest) {
      unawaited(PlatformBridge.instance.showInFolder(destFile.path, dlDir));
    }
    _readyFilePath = destFile.path;
    _phase = UpdatePhase.readyToInstall;
    notifyListeners();
    return UpdateInstallResult.savedToDownloads;
  }

  Directory? _locateExeDir(Directory root, String exeName) {
    final direct = File(p.join(root.path, exeName));
    if (direct.existsSync()) return root;
    for (final entry in root.listSync()) {
      if (entry is Directory) {
        final nested = File(p.join(entry.path, exeName));
        if (nested.existsSync()) return entry;
      }
    }
    return null;
  }

  Future<Directory> _resolveStagingDir() async {
    Directory base;
    if (stagingDirOverride != null) {
      base = Directory(stagingDirOverride!);
    } else if (Platform.isAndroid) {
      final cache = await PlatformBridge.instance.getCacheDir();
      base = Directory(p.join(cache.path, 'updates'));
    } else {
      base = Directory(p.join(Directory.systemTemp.path, 'materialdrop_updates'));
    }
    await base.create(recursive: true);
    return base;
  }

  Future<String> _computeFileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  void _scheduleGracefulShutdown() {
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      try {
        unawaited(DesktopBridge.instance.quitApp());
      } catch (_) {}
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        exit(0);
      });
    });
  }

  void _setError(String code, {String? detail}) {
    _errorCode = code;
    _errorDetail = detail;
    _phase = UpdatePhase.error;
    notifyListeners();
  }

  static String _psEscape(String value) => value.replaceAll("'", "''");
}
