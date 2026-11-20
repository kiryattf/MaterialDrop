import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/platform_bridge.dart';
import '../../services/settings_controller.dart';
import '../../theme/app_theme.dart';
import '../motion/md3_springs.dart';
import 'history_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;
  final ShareLaunchPayload? shareLaunch;
  final VoidCallback? onExitShareSheet;

  const HomeShell({
    super.key,
    required this.settings,
    required this.coordinator,
    this.shareLaunch,
    this.onExitShareSheet,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_onCoordinatorUpdate);
    _syncRadarVisibility();
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    widget.coordinator.removeListener(_onCoordinatorUpdate);
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
    final isWide = width >= 720;

    final body = ExpressiveStageSwitcher(
      duration: const Duration(milliseconds: 280),
      child: KeyedSubtree(
        key: ValueKey(_tabIndex),
        child: switch (_tabIndex) {
          0 => SendScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
            ),
          1 => ReceiveScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
            ),
          2 => HistoryScreen(settings: widget.settings),
          _ => SettingsScreen(
              settings: widget.settings,
              coordinator: widget.coordinator,
            ),
        },
      ),
    );

    if (isWide) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: scheme.surfaceContainerLow,
        body: Row(
          children: [
            _buildNavigationRail(context, strings, width >= 960, hasIncomingBadge),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: Material(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(28),
                  clipBehavior: Clip.antiAlias,
                  child: body,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
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
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
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
    bool hasIncomingBadge,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return NavigationRail(
      extended: extended,
      selectedIndex: _tabIndex,
      onDestinationSelected: (idx) {
        setState(() => _tabIndex = idx);
        _syncRadarVisibility();
      },
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 20),
        child: Row(
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
                        strings.tr('online'),
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
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
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings_rounded),
          label: Text(strings.tr('tab_settings')),
        ),
      ],
    );
  }
}

