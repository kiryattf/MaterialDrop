import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/desktop_bridge.dart';
import '../../services/platform_bridge.dart';
import '../../services/settings_controller.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import '../motion/md3_springs.dart';
import '../widgets/update_dialog.dart';
import 'history_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;
  final UpdateService? updateService;
  final ShareLaunchPayload? shareLaunch;
  final VoidCallback? onExitShareSheet;

  const HomeShell({
    super.key,
    required this.settings,
    required this.coordinator,
    this.updateService,
    this.shareLaunch,
    this.onExitShareSheet,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;
  bool? _railExtendedOverride;
  StreamSubscription<String>? _traySub;

  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_onCoordinatorUpdate);
    widget.updateService?.addListener(_onUpdateServiceChanged);
    if (DesktopBridge.instance.isDesktop) {
      _traySub = DesktopBridge.instance.trayActionStream.listen((action) {
        if (!mounted) return;
        if (action == 'send' && _tabIndex != 0) {
          setState(() => _tabIndex = 0);
          _syncRadarVisibility();
        }
      });
    }
    _syncRadarVisibility();
  }

  void _onUpdateServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updateService != widget.updateService) {
      oldWidget.updateService?.removeListener(_onUpdateServiceChanged);
      widget.updateService?.addListener(_onUpdateServiceChanged);
    }
    _syncRadarVisibility();
  }

  void _syncRadarVisibility() {
    final isShare = widget.shareLaunch?.isShareSheet == true;
    widget.coordinator.setRadarVisible(isShare || _tabIndex == 0);
  }

  void _onCoordinatorUpdate() {
    if (!mounted) return;
    final incoming = widget.coordinator.incomingState;
    if (widget.shareLaunch?.isShareSheet != true &&
        (incoming is IncomingOfferPending || incoming is IncomingReceiving) &&
        _tabIndex != 1) {
      setState(() {
        _tabIndex = 1;
      });
      _syncRadarVisibility();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_traySub?.cancel());
    widget.coordinator.removeListener(_onCoordinatorUpdate);
    widget.updateService?.removeListener(_onUpdateServiceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.settings.strings;

    // Dedicated Android Share Sheet mode: pure radar & throw flow without nav chrome
    if (widget.shareLaunch != null &&
        widget.shareLaunch!.isShareSheet &&
        widget.shareLaunch!.files.isNotEmpty) {
      return Scaffold(
        body: SendScreen(
          settings: widget.settings,
          coordinator: widget.coordinator,
          initialFiles: widget.shareLaunch!.files,
          isShareSheet: true,
          onCloseShareSheet: () {
            widget.onExitShareSheet?.call();
            PlatformBridge.instance.finishActivity();
          },
        ),
      );
    }

    final hasIncomingBadge =
        widget.coordinator.incomingState is! IncomingIdle;
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 600;
    final canExpandRail = width >= 840;
    final railExtended = canExpandRail
        ? (_railExtendedOverride ?? (width >= 960))
        : false;

    final body = ExpressiveStageSwitcher(
      duration: const Duration(milliseconds: 280),
      child: KeyedSubtree(
        key: ValueKey(_tabIndex),
        child: switch (_tabIndex) {
          0 => SendScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
              onOpenReceiveTab: () {
                setState(() => _tabIndex = 1);
                _syncRadarVisibility();
              },
              onOpenHistoryTab: () {
                setState(() => _tabIndex = 2);
                _syncRadarVisibility();
              },
            ),
          1 => ReceiveScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
            ),
          2 => HistoryScreen(settings: widget.settings),
          _ => SettingsScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
              updateService: widget.updateService,
            ),
        },
      ),
    );

    final showUpdateBanner = widget.updateService?.shouldShowBanner == true &&
        widget.updateService?.latestRelease != null;
    final bodyWithUpdateBanner = showUpdateBanner
        ? Column(
            children: [
              _UpdateAvailableBanner(
                updateService: widget.updateService!,
                strings: strings,
              ),
              Expanded(child: body),
            ],
          )
        : body;

    final hasUpdateBadge = widget.updateService?.hasUpdate == true;

    if (isWide) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: scheme.surfaceContainerLow,
        body: Row(
          children: [
            _buildNavigationRail(
              context,
              strings,
              railExtended,
              canExpandRail,
              hasIncomingBadge,
              hasUpdateBadge,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: Material(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(28),
                  clipBehavior: Clip.antiAlias,
                  child: bodyWithUpdateBanner,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: bodyWithUpdateBanner,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) {
          setState(() => _tabIndex = idx);
          _syncRadarVisibility();
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.send_outlined),
            selectedIcon: const Icon(Icons.send_rounded),
            label: strings.tr('tab_send'),
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: hasIncomingBadge,
              child: const Icon(Icons.download_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: hasIncomingBadge,
              child: const Icon(Icons.download_rounded),
            ),
            label: strings.tr('tab_receive'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.history_outlined),
            selectedIcon: const Icon(Icons.history_rounded),
            label: strings.tr('tab_history'),
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: hasUpdateBadge,
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: hasUpdateBadge,
              child: const Icon(Icons.settings_rounded),
            ),
            label: strings.tr('tab_settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationRail(
    BuildContext context,
    AppStrings strings,
    bool extended,
    bool canExpand,
    bool hasIncomingBadge,
    bool hasUpdateBadge,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final launch = widget.settings.launchConfig;

    return NavigationRail(
      extended: extended,
      selectedIndex: _tabIndex,
      onDestinationSelected: (idx) {
        setState(() => _tabIndex = idx);
        _syncRadarVisibility();
      },
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              extended ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.near_me_rounded,
                    color: scheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                if (extended) ...[
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MaterialDrop', style: textTheme.titleMedium),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: AppTheme.statusGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            launch.isMultiInstance
                                ? '${strings.tr('online')} • :${launch.port ?? 45873}'
                                : strings.tr('online'),
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (canExpand) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: () {
                        setState(() => _railExtendedOverride = false);
                      },
                      icon: const Icon(Icons.menu_open_rounded, size: 18),
                    ),
                  ],
                ],
              ],
            ),
            if (!extended && canExpand) ...[
              const SizedBox(height: 8),
              IconButton(
                onPressed: () {
                  setState(() => _railExtendedOverride = true);
                },
                icon: const Icon(Icons.menu_rounded, size: 20),
              ),
            ],
          ],
        ),
      ),
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.send_outlined),
          selectedIcon: const Icon(Icons.send_rounded),
          label: Text(strings.tr('tab_send')),
        ),
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: hasIncomingBadge,
            child: const Icon(Icons.download_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: hasIncomingBadge,
            child: const Icon(Icons.download_rounded),
          ),
          label: Text(strings.tr('tab_receive')),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.history_outlined),
          selectedIcon: const Icon(Icons.history_rounded),
          label: Text(strings.tr('tab_history')),
        ),
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: hasUpdateBadge,
            child: const Icon(Icons.settings_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: hasUpdateBadge,
            child: const Icon(Icons.settings_rounded),
          ),
          label: Text(strings.tr('tab_settings')),
        ),
      ],
    );
  }
}

class _UpdateAvailableBanner extends StatelessWidget {
  final UpdateService updateService;
  final AppStrings strings;

  const _UpdateAvailableBanner({
    required this.updateService,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tag = updateService.latestRelease?.tagName ?? '';

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_rounded,
                  color: scheme.onPrimaryContainer,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.tr('update_available_title', {'version': tag}),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => UpdateSheetDialog.show(
                    context,
                    updateService: updateService,
                    strings: strings,
                  ),
                  child: Text(strings.tr('update_banner_action')),
                ),
                IconButton(
                  onPressed: updateService.dismissBanner,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

