import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

import 'models/models.dart';
import 'protocol/transfer_coordinator.dart';
import 'services/platform_bridge.dart';
import 'services/settings_controller.dart';
import 'theme/app_theme.dart';
import 'ui/screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = SettingsController();
  await settings.init();

  final coordinator = TransferCoordinator(settings: settings);
  await coordinator.startServices();

  final initialShareRaw = await PlatformBridge.instance.getInitialSharedFiles();
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

  @override
  void initState() {
    super.initState();
    _shareLaunch = widget.initialShare;
    WidgetsBinding.instance.addObserver(this);
    _shareSub = PlatformBridge.instance.shareIntentStream.listen((payload) async {
      final normalized = await _normalizeSharePayload(payload);
      if (mounted && normalized != null) {
        setState(() {
          _shareLaunch = normalized;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.coordinator.startDiscovery());
    } else if (state == AppLifecycleState.paused) {
      unawaited(widget.coordinator.stopDiscovery());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shareSub?.cancel());
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
