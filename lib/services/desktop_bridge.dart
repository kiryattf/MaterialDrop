import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum ClipboardContentType { empty, files, imageFile, text }

class ClipboardPayload {
  final ClipboardContentType type;
  final List<String> paths;
  final String? text;

  const ClipboardPayload({
    required this.type,
    this.paths = const [],
    this.text,
  });

  bool get isEmpty => type == ClipboardContentType.empty;
}

class TrayLabels {
  final String openLabel;
  final String sendLabel;
  final String downloadsLabel;
  final String autoAcceptLabel;
  final String soundsLabel;
  final String exitLabel;
  final String tooltip;

  const TrayLabels({
    required this.openLabel,
    required this.sendLabel,
    required this.downloadsLabel,
    required this.autoAcceptLabel,
    required this.soundsLabel,
    required this.exitLabel,
    required this.tooltip,
  });

  Map<String, dynamic> toMap() => {
        'open': openLabel,
        'send': sendLabel,
        'downloads': downloadsLabel,
        'autoAccept': autoAcceptLabel,
        'sounds': soundsLabel,
        'exit': exitLabel,
        'tooltip': tooltip,
      };
}

/// Native Windows (Win32) & Linux (GTK3 / XDG) desktop integration bridge:
/// System Tray, minimize-on-close, native notifications, Ctrl+V clipboard read/write,
/// and D3D fullscreen game detection.
class DesktopBridge {
  static const MethodChannel _channel =
      MethodChannel('dev.materialdrop.flutter/desktop');

  static final DesktopBridge instance = DesktopBridge._();
  DesktopBridge._();

  final StreamController<String> _trayActions =
      StreamController<String>.broadcast();
  final StreamController<String> _deepLinks =
      StreamController<String>.broadcast();
  final StreamController<String> _islandActions =
      StreamController<String>.broadcast();
  bool _handlerBound = false;

  bool get isDesktop => Platform.isWindows || Platform.isLinux;

  Stream<String> get trayActionStream => _trayActions.stream;
  Stream<String> get deepLinkStream => _deepLinks.stream;
  Stream<String> get islandActionStream => _islandActions.stream;

  void _ensureHandler() {
    if (_handlerBound || !isDesktop) return;
    _handlerBound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTrayAction') {
        final action = call.arguments as String? ?? '';
        if (action.isNotEmpty) {
          _trayActions.add(action);
        }
      } else if (call.method == 'onDeepLink') {
        final url = call.arguments as String? ?? '';
        if (url.isNotEmpty) {
          _deepLinks.add(url);
        }
      } else if (call.method == 'onIslandAction') {
        final action = call.arguments as String? ?? '';
        if (action.isNotEmpty) {
          _islandActions.add(action);
        }
      }
    });
  }

  Future<void> showDynamicIsland({
    required String mode,
    required String position,
    required String title,
    required String subtitle,
    required int accentColor,
    double progress = 0.0,
    bool hasProgress = false,
    Uint8List? thumbnailPng,
    List<Map<String, dynamic>> buttons = const [],
  }) async {
    if (!isDesktop) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('showDynamicIsland', {
        'mode': mode,
        'position': position,
        'title': title,
        'subtitle': subtitle,
        'accentColor': accentColor,
        'progress': progress,
        'hasProgress': hasProgress,
        if (thumbnailPng != null && thumbnailPng.isNotEmpty)
          'thumbnailPng': thumbnailPng,
        'buttons': buttons,
      });
    } catch (_) {}
  }

  Future<void> hideDynamicIsland() async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('hideDynamicIsland');
    } catch (_) {}
  }

  Future<void> registerUrlProtocol() async {
    if (!isDesktop) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('registerUrlProtocol');
    } catch (_) {}
  }

  Future<void> initTray({
    required TrayLabels labels,
    required bool autoAccept,
    required bool soundsEnabled,
    required bool minimizeToTray,
    bool startHidden = false,
  }) async {
    if (!isDesktop) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('initTray', {
        ...labels.toMap(),
        'autoAccept': autoAccept,
        'sounds': soundsEnabled,
        'minimizeToTray': minimizeToTray,
        'startHidden': startHidden,
      });
    } catch (_) {}
  }

  Future<void> updateTrayState({
    required TrayLabels labels,
    required bool autoAccept,
    required bool soundsEnabled,
    required bool minimizeToTray,
  }) async {
    if (!isDesktop) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('updateTrayState', {
        ...labels.toMap(),
        'autoAccept': autoAccept,
        'sounds': soundsEnabled,
        'minimizeToTray': minimizeToTray,
      });
    } catch (_) {}
  }

  Future<void> showWindow() async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('showWindow');
    } catch (_) {}
  }

  Future<void> hideWindow() async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('hideWindow');
    } catch (_) {}
  }

  Future<void> setWindowTitle(String title) async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('setWindowTitle', {'title': title});
    } catch (_) {}
  }

  Future<void> showNotification({
    required String title,
    required String body,
  }) async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('showNotification', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  Future<bool> isWindowVisible() async {
    if (!isDesktop) return true;
    try {
      return await _channel.invokeMethod<bool>('isWindowVisible') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> isFullscreenGameRunning() async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('isFullscreenGameRunning') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> quitApp() async {
    if (!isDesktop) return;
    try {
      await _channel.invokeMethod('quitApp');
    } catch (_) {
      exit(0);
    }
  }

  Future<ClipboardPayload> readClipboardPayload(String tempStagingDir) async {
    if (isDesktop) {
      try {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'readClipboard',
          {'tempDir': tempStagingDir},
        );
        if (raw != null) {
          final kind = raw['type'] as String? ?? 'empty';
          if (kind == 'files') {
            final paths = (raw['paths'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList();
            if (paths.isNotEmpty) {
              return ClipboardPayload(
                type: ClipboardContentType.files,
                paths: paths,
              );
            }
          } else if (kind == 'imageFile') {
            final path = raw['path'] as String? ?? '';
            if (path.isNotEmpty) {
              return ClipboardPayload(
                type: ClipboardContentType.imageFile,
                paths: [path],
              );
            }
          } else if (kind == 'text') {
            final text = raw['text'] as String? ?? '';
            if (text.isNotEmpty) {
              return ClipboardPayload(
                type: ClipboardContentType.text,
                text: text,
              );
            }
          }
        }
      } catch (_) {}
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      return ClipboardPayload(type: ClipboardContentType.text, text: text);
    }
    return const ClipboardPayload(type: ClipboardContentType.empty);
  }

  Future<bool> writeImageToClipboard(String filePath) async {
    if (!isDesktop) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'writeImageToClipboard',
            {'path': filePath},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
