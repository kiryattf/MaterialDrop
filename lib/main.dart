import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

import 'models/models.dart';
import 'protocol/transfer_coordinator.dart';
import 'services/desktop_bridge.dart';
import 'services/launch_config.dart';
import 'services/platform_bridge.dart';
import 'services/settings_controller.dart';
import 'theme/app_theme.dart';
import 'ui/screens/home_shell.dart';
import 'ui/widgets/dynamic_island.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final launchConfig = LaunchConfig.fromArgs(args);
  final settings = SettingsController(launchConfig: launchConfig);
  await settings.init();

  final coordinator = TransferCoordinator(settings: settings);
  await coordinator.startServices();

  final initialShareRaw = await PlatformBridge.instance.getInitialSharedFiles();
  if (initialShareRaw?.deepLink != null && initialShareRaw!.deepLink!.isNotEmpty) {
    coordinator.connectIrohLink(initialShareRaw.deepLink!);
  }
  final initialShare = await _normalizeSharePayload(initialShareRaw);
  unawaited(PlatformBridge.instance.requestNotificationPermission());

  runApp(
    MaterialDropRoot(
      settings: settings,
      coordinator: coordinator,
      initialShare: initialShare,
    ),
  );
}

Future<ShareLaunchPayload?> _normalizeSharePayload(
  ShareLaunchPayload? payload,
) async {
  if (payload == null) return null;
  if (payload.files.isNotEmpty) return payload;
  final text = payload.sharedText;
  if (text == null || text.isEmpty) return null;

  final dir = await PlatformBridge.instance.getTempStagingDir();
  final out = File('${dir.path}/shared_text_${DateTime.now().millisecondsSinceEpoch}.txt');
  await out.writeAsString(text, flush: true);
  final len = await out.length();
  return ShareLaunchPayload(
    isShareSheet: payload.isShareSheet,
    files: [
      StagedFile(
        name: 'shared_text.txt',
        size: len,
        mimeType: 'text/plain',
        path: out.path,
      ),
    ],
    sharedText: text,
  );
}

class MaterialDropRoot extends StatefulWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;
  final ShareLaunchPayload? initialShare;

  const MaterialDropRoot({
    super.key,
    required this.settings,
    required this.coordinator,
    this.initialShare,
  });

  @override
  State<MaterialDropRoot> createState() => _MaterialDropRootState();
}

class _MaterialDropRootState extends State<MaterialDropRoot>
    with WidgetsBindingObserver {
  ShareLaunchPayload? _shareLaunch;
  StreamSubscription<ShareLaunchPayload>? _shareSub;
  StreamSubscription<String>? _traySub;
  StreamSubscription<String>? _deepLinkSub;
  StreamSubscription<String>? _islandActionSub;
  String? _lastNotifiedOfferId;
  String? _lastCompletedOfferId;
  String? _lastWindowTitle;
  bool _appFocused = true;

  @override
  void initState() {
    super.initState();
    _shareLaunch = widget.initialShare;
    WidgetsBinding.instance.addObserver(this);
    _shareSub = PlatformBridge.instance.shareIntentStream.listen((payload) async {
      if (payload.deepLink != null && payload.deepLink!.isNotEmpty) {
        widget.coordinator.connectIrohLink(payload.deepLink!);
      }
      final normalized = await _normalizeSharePayload(payload);
      if (mounted && normalized != null) {
        setState(() {
          _shareLaunch = normalized;
        });
      }
    });
    widget.settings.addListener(_onSettingsUpdated);
    widget.coordinator.addListener(_onCoordinatorUpdated);
    if (DesktopBridge.instance.isDesktop) {
      _initDesktopLifecycle();
    }
  }

  TrayLabels _buildTrayLabels() {
    final strings = widget.settings.strings;
    final launch = widget.settings.launchConfig;
    final tooltip = launch.isMultiInstance
        ? 'MaterialDrop — ${widget.settings.deviceName} (:${launch.port ?? 45873})'
        : 'MaterialDrop';
    return TrayLabels(
      openLabel: strings.tr('tray_open'),
      sendLabel: strings.tr('tray_send'),
      downloadsLabel: strings.tr('tray_downloads'),
      autoAcceptLabel: strings.tr('tray_auto'),
      soundsLabel: strings.tr('tray_sounds'),
      exitLabel: strings.tr('tray_exit'),
      tooltip: tooltip,
    );
  }

  void _initDesktopLifecycle() {
    unawaited(DesktopBridge.instance.registerUrlProtocol());
    unawaited(
      DesktopBridge.instance.initTray(
        labels: _buildTrayLabels(),
        autoAccept: widget.settings.autoAcceptAll,
        soundsEnabled: widget.settings.soundsEnabled,
        minimizeToTray: widget.settings.minimizeToTray,
        startHidden: widget.settings.launchConfig.startInTray,
      ),
    );
    _syncWindowTitle();
    _traySub = DesktopBridge.instance.trayActionStream.listen(_handleTrayAction);
    _deepLinkSub = DesktopBridge.instance.deepLinkStream.listen((link) {
      widget.coordinator.connectIrohLink(link);
      unawaited(DesktopBridge.instance.showWindow());
    });
    _islandActionSub =
        DesktopBridge.instance.islandActionStream.listen(_handleIslandAction);
  }

  Future<void> _handleIslandAction(String action) async {
    switch (action) {
      case 'accept':
        await widget.coordinator.acceptIncoming();
      case 'decline':
        widget.coordinator.declineIncoming();
      case 'cancel':
        await widget.coordinator.cancelIncoming();
      case 'dismiss':
        widget.coordinator.dismissIsland();
      case 'open_app':
        await DesktopBridge.instance.showWindow();
      case 'copy':
        final st = widget.coordinator.islandState;
        if (st is IslandCompleted) {
          await _copyCompleted(st.completed);
        }
      case 'open':
        final st = widget.coordinator.islandState;
        if (st is IslandCompleted) {
          await _openCompleted(st.completed);
        }
      case 'folder':
        final st = widget.coordinator.islandState;
        if (st is IslandCompleted) {
          await _showCompletedFolder(st.completed);
        }
    }
  }

  Future<void> _copyCompleted(IncomingCompleted completed) async {
    if (completed.receivedTexts.isNotEmpty) {
      await PlatformBridge.instance
          .copyTextToClipboard(completed.receivedTexts.first.body);
    } else if (completed.savedItems.isNotEmpty) {
      await PlatformBridge.instance
          .copyFileOrImageToClipboard(completed.savedItems.first.savedPathOrUri);
    }
  }

  Future<void> _openCompleted(IncomingCompleted completed) async {
    if (completed.savedItems.isNotEmpty) {
      final first = completed.savedItems.first;
      await PlatformBridge.instance
          .openFile(first.savedPathOrUri, mimeType: first.mimeType);
    }
  }

  Future<void> _showCompletedFolder(IncomingCompleted completed) async {
    final path = completed.savedItems.isNotEmpty
        ? completed.savedItems.first.savedPathOrUri
        : '';
    await PlatformBridge.instance.showInFolder(path, widget.settings.downloadDir);
  }

  void _syncWindowTitle() {
    if (!DesktopBridge.instance.isDesktop) return;
    final launch = widget.settings.launchConfig;
    final title = launch.isMultiInstance
        ? 'MaterialDrop — ${widget.settings.deviceName} (:${launch.port ?? 45873})'
        : 'MaterialDrop';
    if (_lastWindowTitle != title) {
      _lastWindowTitle = title;
      unawaited(DesktopBridge.instance.setWindowTitle(title));
    }
  }

  void _onSettingsUpdated() {
    if (!DesktopBridge.instance.isDesktop) return;
    _syncWindowTitle();
    unawaited(
      DesktopBridge.instance.updateTrayState(
        labels: _buildTrayLabels(),
        autoAccept: widget.settings.autoAcceptAll,
        soundsEnabled: widget.settings.soundsEnabled,
        minimizeToTray: widget.settings.minimizeToTray,
      ),
    );
  }

  Future<void> _handleTrayAction(String action) async {
    switch (action) {
      case 'open':
      case 'send':
        await DesktopBridge.instance.showWindow();
      case 'downloads':
        await PlatformBridge.instance.showInFolder(
          '',
          widget.settings.downloadDir,
        );
      case 'toggleAutoAccept':
        await widget.settings.setAutoAcceptAll(!widget.settings.autoAcceptAll);
        await widget.coordinator.onSettingsUpdated();
      case 'toggleSounds':
        await widget.settings.setSoundsEnabled(!widget.settings.soundsEnabled);
        await widget.coordinator.onSettingsUpdated();
      case 'exit':
        await DesktopBridge.instance.quitApp();
    }
  }

  void _onCoordinatorUpdated() {
    if (!DesktopBridge.instance.isDesktop) return;
    unawaited(_syncDesktopIslandOverlay());
    final incoming = widget.coordinator.incomingState;
    if (incoming is IncomingOfferPending &&
        incoming.offer.id != _lastNotifiedOfferId) {
      _lastNotifiedOfferId = incoming.offer.id;
      unawaited(_notifyIncomingOffer(incoming.offer));
    } else if (incoming is IncomingCompleted &&
        incoming.offer.id != _lastCompletedOfferId) {
      _lastCompletedOfferId = incoming.offer.id;
      unawaited(_notifyIncomingCompleted(incoming));
    }
  }

  Future<void> _syncDesktopIslandOverlay() async {
    if (!DesktopBridge.instance.isDesktop) return;
    if (!widget.settings.islandEnabled) {
      await DesktopBridge.instance.hideDynamicIsland();
      return;
    }

    final state = widget.coordinator.islandState;
    final winVisible = await DesktopBridge.instance.isWindowVisible();
    // Show floating borderless OS island whenever main window is hidden/unfocused
    if ((winVisible && _appFocused) || state is IslandHidden) {
      await DesktopBridge.instance.hideDynamicIsland();
      return;
    }

    final strings = widget.settings.strings;
    final pos = widget.settings.islandPosition.name;

    switch (state) {
      case IslandHidden():
        await DesktopBridge.instance.hideDynamicIsland();
      case IslandPreGesturePeek(:final preview):
        final title = preview.fileCount > 1
            ? '${preview.fileName} (+${preview.fileCount - 1})'
            : preview.fileName;
        await DesktopBridge.instance.showDynamicIsland(
          mode: 'peek',
          position: pos,
          title: title,
          subtitle: '${preview.senderName} • ${formatFileSize(preview.totalBytes)}',
          accentColor: preview.dominantColor,
          progress: preview.dragProgress,
          hasProgress: false,
          thumbnailPng: preview.thumbnailBytes,
        );
      case IslandOffer(:final offer, :final dominantColor, :final thumbnailBytes):
        final count = offer.files.length + offer.texts.length;
        await DesktopBridge.instance.showDynamicIsland(
          mode: 'offer',
          position: pos,
          title: offer.pin != null
              ? '${offer.senderName} • PIN ${offer.pin}'
              : offer.senderName,
          subtitle: '$count • ${formatFileSize(offer.totalSize)}',
          accentColor: dominantColor,
          thumbnailPng: thumbnailBytes,
          buttons: [
            {'action': 'decline', 'label': strings.tr('decline'), 'primary': false},
            {'action': 'accept', 'label': strings.tr('accept'), 'primary': true},
          ],
        );
      case IslandProgress(
          :final fileName,
          :final progress,
          :final speedBps,
          :final dominantColor,
          :final thumbnailBytes,
        ):
        await DesktopBridge.instance.showDynamicIsland(
          mode: 'progress',
          position: pos,
          title: fileName,
          subtitle: formatSpeed(speedBps),
          accentColor: dominantColor,
          progress: progress,
          hasProgress: true,
          thumbnailPng: thumbnailBytes,
          buttons: [
            {'action': 'cancel', 'label': '×', 'primary': false},
          ],
        );
      case IslandCompleted(
          :final completed,
          :final dominantColor,
          :final thumbnailBytes,
        ):
        final first = completed.savedItems.isNotEmpty
            ? completed.savedItems.first.name
            : (completed.receivedTexts.isNotEmpty
                ? completed.receivedTexts.first.body
                : completed.offer.senderName);
        await DesktopBridge.instance.showDynamicIsland(
          mode: 'completed',
          position: pos,
          title: strings.tr('transfer_complete'),
          subtitle: first,
          accentColor: dominantColor,
          thumbnailPng: thumbnailBytes,
          buttons: [
            {'action': 'copy', 'label': strings.tr('ctx_copy_path'), 'primary': false},
            if (completed.savedItems.isNotEmpty)
              {'action': 'open', 'label': strings.tr('open_file'), 'primary': true},
            {'action': 'dismiss', 'label': '×', 'primary': false},
          ],
        );
    }
  }

  Future<void> _notifyIncomingOffer(IncomingOffer offer) async {
    final visible = await DesktopBridge.instance.isWindowVisible();
    if (!visible) {
      final strings = widget.settings.strings;
      final count = offer.files.length + offer.texts.length;
      await DesktopBridge.instance.showNotification(
        title: strings.tr('tray_incoming_title', {'device': offer.senderName}),
        body: strings.tr('tray_incoming_body', {
          'count': '$count',
          'size': formatFileSize(offer.totalSize),
        }),
      );
      if (!await DesktopBridge.instance.isFullscreenGameRunning()) {
        await DesktopBridge.instance.showWindow();
      }
    }
  }

  Future<void> _notifyIncomingCompleted(IncomingCompleted completed) async {
    final visible = await DesktopBridge.instance.isWindowVisible();
    if (!visible) {
      final strings = widget.settings.strings;
      final count = completed.savedItems.length + completed.receivedTexts.length;
      await DesktopBridge.instance.showNotification(
        title: strings.tr('tray_received_title'),
        body: strings.tr('tray_received_body', {
          'device': completed.offer.senderName,
          'count': '$count',
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appFocused = state == AppLifecycleState.resumed;
    if (DesktopBridge.instance.isDesktop) {
      unawaited(_syncDesktopIslandOverlay());
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.coordinator.startDiscovery());
    } else if (state == AppLifecycleState.paused && !DesktopBridge.instance.isDesktop) {
      unawaited(widget.coordinator.stopDiscovery());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(_onSettingsUpdated);
    widget.coordinator.removeListener(_onCoordinatorUpdated);
    unawaited(_traySub?.cancel());
    unawaited(_shareSub?.cancel());
    unawaited(_deepLinkSub?.cancel());
    unawaited(_islandActionSub?.cancel());
    unawaited(DesktopBridge.instance.hideDynamicIsland());
    widget.coordinator.dispose();
    super.dispose();
  }

  ThemeMode _resolveThemeMode(AppThemeStyle style) {
    return switch (style) {
      AppThemeStyle.system => ThemeMode.system,
      AppThemeStyle.light => ThemeMode.light,
      AppThemeStyle.dark || AppThemeStyle.oled => ThemeMode.dark,
    };
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) {
            final style = widget.settings.themeStyle;
            final dynamicEnabled = widget.settings.useDynamicColor;

            return MaterialApp(
              title: 'MaterialDrop',
              debugShowCheckedModeBanner: false,
              locale: Locale(widget.settings.languageCode),
              supportedLocales: const [
                Locale('ru'),
                Locale('en'),
                Locale('de'),
              ],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              themeMode: _resolveThemeMode(style),
              theme: AppTheme.buildTheme(
                brightness: Brightness.light,
                style: style,
                useDynamicColor: dynamicEnabled,
                dynamicLight: lightDynamic,
                dynamicDark: darkDynamic,
              ),
              darkTheme: AppTheme.buildTheme(
                brightness: Brightness.dark,
                style: style,
                useDynamicColor: dynamicEnabled,
                dynamicLight: lightDynamic,
                dynamicDark: darkDynamic,
              ),
              builder: (context, child) {
                return Stack(
                  children: [
                    child ?? const SizedBox.shrink(),
                    DynamicIslandOverlay(
                      coordinator: widget.coordinator,
                      settings: widget.settings,
                      onCopy: _copyCompleted,
                      onOpenFile: _openCompleted,
                      onShowFolder: _showCompletedFolder,
                    ),
                  ],
                );
              },
              home: HomeShell(
                settings: widget.settings,
                coordinator: widget.coordinator,
                shareLaunch: _shareLaunch,
                onExitShareSheet: () {
                  setState(() => _shareLaunch = null);
                },
              ),
            );
          },
        );
      },
    );
  }
}
