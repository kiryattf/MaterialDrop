import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/services/launch_config.dart';
import 'package:material_drop/services/settings_controller.dart';
import 'package:material_drop/services/update_service.dart';
import 'package:material_drop/ui/screens/settings_screen.dart';
import 'package:material_drop/ui/widgets/update_dialog.dart';
import 'package:material_drop/protocol/transfer_coordinator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('SemVer parses, compares, and handles pre-releases and build metadata', () {
    final v200 = SemVer.tryParse('2.0.0+1')!;
    final v210 = SemVer.tryParse('v2.1.0')!;
    final v210Rc = SemVer.tryParse('2.1.0-rc.1')!;

    expect(v210 > v200, isTrue);
    expect(v210 > v210Rc, isTrue);
    expect(v210Rc > v200, isTrue);
    expect(SemVer.tryParse('v2.0.0') == v200, isTrue);
    expect(SemVer.tryParse('invalid'), isNull);
  });

  test('ChecksumsManifest parses sha256sum outputs with spaces, binary flag, and paths', () {
    final hashA = 'a' * 64;
    final hashB = 'B' * 64;
    final hashC = '0123456789abcdef' * 4;
    final manifest = ChecksumsManifest.parse('''
# Release checksums
$hashA  ./android-arm64.apk
$hashB *windows-x64.zip
$hashC  linux-x64.AppImage
''');

    expect(manifest.hashForAsset('android-arm64.apk'), hashA);
    expect(manifest.hashForAsset('windows-x64.zip'), hashB.toLowerCase());
    expect(manifest.hashForAsset('linux-x64.AppImage'), hashC);
    expect(manifest.hashForAsset('missing.tar.gz'), isNull);
  });

  test('UpdateService caches ETag, supports 304 Not Modified, verifies SHA-256, and rejects tampering', () async {
    final prevHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final tmpDir = await Directory.systemTemp.createTemp('md_upd_test_');
    final goodPayload = utf8.encode('fake-binary-release-payload-v2.1.0-' * 50);
    final goodSha = sha256.convert(goodPayload).toString();
    final badSha = 'f' * 64;

    var useTamperedChecksum = false;
    var etagRequests = 0;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}';
    final sub = server.listen((req) async {
      final path = req.uri.path;
      if (path == '/releases/latest') {
        final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
        if (inm == '"etag-v210"') {
          etagRequests++;
          req.response.statusCode = HttpStatus.notModified;
          await req.response.close();
          return;
        }
        req.response.headers.set(HttpHeaders.etagHeader, '"etag-v210"');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'tag_name': 'v2.1.0',
          'name': 'MaterialDrop v2.1.0',
          'body': '## Highlights\n- **Liquid Glass** shader\n- Auto updater with `SHA-256` verification',
          'published_at': '2026-11-20T12:00:00Z',
          'html_url': '$baseUrl/tag/v2.1.0',
          'assets': [
            {
              'name': 'linux-x64.AppImage',
              'browser_download_url': '$baseUrl/dl/linux-x64.AppImage',
              'size': goodPayload.length,
            },
            {
              'name': 'windows-x64.zip',
              'browser_download_url': '$baseUrl/dl/windows-x64.zip',
              'size': goodPayload.length,
            },
            {
              'name': 'android-arm64.apk',
              'browser_download_url': '$baseUrl/dl/android-arm64.apk',
              'size': goodPayload.length,
            },
            {
              'name': 'checksums.txt',
              'browser_download_url': '$baseUrl/dl/checksums.txt',
              'size': 256,
            },
          ],
        }));
        await req.response.close();
        return;
      }

      if (path == '/dl/checksums.txt') {
        final h = useTamperedChecksum ? badSha : goodSha;
        req.response.write('''
$h  linux-x64.AppImage
$h  windows-x64.zip
$h  android-arm64.apk
''');
        await req.response.close();
        return;
      }

      if (path.startsWith('/dl/')) {
        req.response.headers.set(HttpHeaders.contentLengthHeader, goodPayload.length);
        req.response.add(goodPayload);
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    try {
      final svc = UpdateService(
        currentVersionOverride: '2.0.0',
        latestReleaseUrl: '$baseUrl/releases/latest',
        platformOverride: UpdatePlatformTarget.linux,
        stagingDirOverride: p.join(tmpDir.path, 'stage'),
        appImageEnvOverride: p.join(tmpDir.path, 'MaterialDrop.AppImage'),
        skipProcessExitForTest: true,
      );

      // 1st check hits 200 OK & detects v2.1.0 > 2.0.0
      final first = await svc.checkForUpdates(force: true);
      expect(first, isNotNull);
      expect(svc.hasUpdate, isTrue);
      expect(svc.phase, UpdatePhase.available);

      // 2nd check sends ETag & honors 304 Not Modified
      final second = await svc.checkForUpdates();
      expect(second?.tagName, 'v2.1.0');
      expect(etagRequests, 1);

      // Tampered checksum must abort & delete partial download
      useTamperedChecksum = true;
      final badOk = await svc.downloadAndVerify();
      expect(badOk, isFalse);
      expect(svc.phase, UpdatePhase.error);
      expect(svc.errorCode, 'update_sha_mismatch');
      expect(svc.readyFilePath, isNull);

      // Valid checksum passes SHA-256 verification and replaces APPIMAGE atomically
      useTamperedChecksum = false;
      final appImageTarget = File(p.join(tmpDir.path, 'MaterialDrop.AppImage'));
      await appImageTarget.writeAsString('old-version');

      final goodOk = await svc.downloadAndVerify();
      expect(goodOk, isTrue);
      expect(svc.phase, UpdatePhase.readyToInstall);
      expect(svc.verifiedSha256, goodSha);

      final installRes = await svc.installDownloadedUpdate();
      expect(installRes, UpdateInstallResult.restarting);
      expect(await appImageTarget.readAsBytes(), goodPayload);

      svc.dispose();
    } finally {
      HttpOverrides.global = prevHttp;
      await sub.cancel();
      await server.close(force: true);
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    }
  });

  test('Windows portable bundle ZIP updater swaps full exe, DLLs, and data tree safely', () async {
    if (!Platform.isWindows) return;
    final prevHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final tmpDir = await Directory.systemTemp.createTemp('md_win_upd_');
    final srcBundle = Directory(p.join(tmpDir.path, 'new_bundle'));
    final dstBundle = Directory(p.join(tmpDir.path, 'live_bundle'));
    await Directory(p.join(srcBundle.path, 'data', 'flutter_assets')).create(recursive: true);
    await Directory(p.join(dstBundle.path, 'data', 'flutter_assets')).create(recursive: true);

    await File(p.join(dstBundle.path, 'material_drop.exe')).writeAsString('old-exe');
    await File(p.join(dstBundle.path, 'flutter_windows.dll')).writeAsString('old-dll');
    await File(p.join(dstBundle.path, 'data', 'flutter_assets', 'stale.txt')).writeAsString('stale');

    await File(p.join(srcBundle.path, 'material_drop.exe')).writeAsString('new-exe-v2.1.0');
    await File(p.join(srcBundle.path, 'flutter_windows.dll')).writeAsString('new-dll-v2.1.0');
    await File(p.join(srcBundle.path, 'data', 'flutter_assets', 'manifest.json')).writeAsString('{"v":"2.1.0"}');

    final zipFile = File(p.join(tmpDir.path, 'windows-x64.zip'));
    final psEscSrc = '${srcBundle.path}\\*'.replaceAll("'", "''");
    final psEscZip = zipFile.path.replaceAll("'", "''");
    final zipRes = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Compress-Archive -Path '$psEscSrc' -DestinationPath '$psEscZip' -Force",
    ]);
    expect(zipRes.exitCode, 0);

    final zipBytes = await zipFile.readAsBytes();
    final zipSha = sha256.convert(zipBytes).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}';
    final sub = server.listen((req) async {
      if (req.uri.path == '/releases/latest') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'tag_name': 'v2.1.0',
          'name': 'v2.1.0',
          'body': '- Windows portable update',
          'assets': [
            {
              'name': 'windows-x64.zip',
              'browser_download_url': '$baseUrl/dl/windows-x64.zip',
              'size': zipBytes.length,
            },
            {
              'name': 'checksums.txt',
              'browser_download_url': '$baseUrl/dl/checksums.txt',
              'size': 128,
            },
          ],
        }));
      } else if (req.uri.path == '/dl/checksums.txt') {
        req.response.write('$zipSha  windows-x64.zip\n');
      } else if (req.uri.path == '/dl/windows-x64.zip') {
        req.response.headers.contentLength = zipBytes.length;
        req.response.add(zipBytes);
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });

    try {
      final svc = UpdateService(
        currentVersionOverride: '2.0.0',
        latestReleaseUrl: '$baseUrl/releases/latest',
        platformOverride: UpdatePlatformTarget.windows,
        stagingDirOverride: p.join(tmpDir.path, 'stage'),
        appBundleDirOverride: dstBundle.path,
        skipProcessExitForTest: true,
      );
      await svc.checkForUpdates(force: true);
      expect(await svc.downloadAndVerify(), isTrue);
      final installRes = await svc.installDownloadedUpdate();
      expect(installRes, UpdateInstallResult.restarting);
      expect(await File(p.join(dstBundle.path, 'material_drop.exe')).readAsString(), 'new-exe-v2.1.0');
      expect(await File(p.join(dstBundle.path, 'flutter_windows.dll')).readAsString(), 'new-dll-v2.1.0');
      expect(await File(p.join(dstBundle.path, 'data', 'flutter_assets', 'manifest.json')).readAsString(), '{"v":"2.1.0"}');
      expect(await File(p.join(dstBundle.path, 'data', 'flutter_assets', 'stale.txt')).exists(), isFalse);
      svc.dispose();
    } finally {
      HttpOverrides.global = prevHttp;
      await sub.cancel();
      await server.close(force: true);
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    }
  });

  testWidgets('SettingsScreen Updates card and UpdateSheetDialog display release notes', (tester) async {
    SharedPreferences.setMockInitialValues({
      'md_update_cached_release_json': jsonEncode({
        'tag_name': 'v2.1.0',
        'name': 'v2.1.0',
        'body': '## Release 2.1.0\n- Added `OTA` updates\n- Fixed discovery',
        'published_at': '2026-11-20T12:00:00Z',
        'html_url': 'https://github.com/kiryattf/MaterialDrop/releases/tag/v2.1.0',
        'assets': [],
      }),
    });

    final settings = SettingsController(
      launchConfig: const LaunchConfig(deviceName: 'UpdHost', port: 45889),
    );
    late UpdateService updateService;
    await tester.runAsync(() async {
      await settings.init();
      await settings.setLanguageCode('en');
      updateService = UpdateService(currentVersionOverride: '2.0.0');
      await updateService.init();
    });

    final coordinator = TransferCoordinator(settings: settings);
    addTearDown(coordinator.dispose);
    addTearDown(updateService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: settings,
            coordinator: coordinator,
            updateService: updateService,
          ),
        ),
      ),
    );
    await tester.pump();

    final tileFinder = find.text('Version v2.1.0 available');
    await tester.scrollUntilVisible(
      tileFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tileFinder, findsOneWidget);
    await tester.tap(tileFinder);
    await tester.pumpAndSettle();

    expect(find.byType(UpdateSheetDialog), findsOneWidget);
    expect(find.text('Release 2.1.0'), findsOneWidget);
    expect(find.text('Download & Verify'), findsOneWidget);
  });
}
