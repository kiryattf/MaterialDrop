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
  String? _lastNotifiedOfferId;
  String? _lastCompletedOfferId;
  String? _lastWindowTitle;

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
