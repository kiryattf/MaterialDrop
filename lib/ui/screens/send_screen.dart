import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/settings_controller.dart';
import '../../theme/app_theme.dart';
import '../motion/md3_springs.dart';
import '../widgets/scallop_shape.dart';
import '../widgets/sonar_radar.dart';
import '../widgets/swipeable_file_card.dart';

class SendScreen extends StatefulWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;
  final List<StagedFile> initialFiles;
  final bool isShareSheet;
  final VoidCallback? onCloseShareSheet;

  const SendScreen({
    super.key,
    required this.settings,
    required this.coordinator,
    this.initialFiles = const [],
    this.isShareSheet = false,
    this.onCloseShareSheet,
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  List<StagedFile> _stagedFiles = [];
  NearbyDevice? _selectedDevice;
  bool _draggingOver = false;
  Timer? _autoClearTimer;

  @override
  void initState() {
    super.initState();
    if (widget.initialFiles.isNotEmpty) {
      _stagedFiles = List.of(widget.initialFiles);
    }
    widget.coordinator.addListener(_onCoordinatorChanged);
  }

  @override
  void didUpdateWidget(covariant SendScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFiles != oldWidget.initialFiles &&
        widget.initialFiles.isNotEmpty) {
      setState(() {
        _stagedFiles = List.of(widget.initialFiles);
        _selectedDevice = null;
      });
    }
  }

  void _onCoordinatorChanged() {
    if (!mounted) return;
    final status = widget.coordinator.outgoingState;
    if (status is OutgoingCompleted) {
      _autoClearTimer?.cancel();
      _autoClearTimer = Timer(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        if (widget.isShareSheet) {
          widget.coordinator.resetOutgoing();
          widget.onCloseShareSheet?.call();
          return;
        }
        setState(() {
          _selectedDevice = null;
          _stagedFiles = [];
        });
        widget.coordinator.resetOutgoing();
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _autoClearTimer?.cancel();
    widget.coordinator.removeListener(_onCoordinatorChanged);
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final picked = <StagedFile>[];
    for (final pf in result.files) {
      final path = pf.path;
      var size = pf.size;
      if (size <= 0 && path != null) {
        try {
          size = await File(path).length();
        } catch (_) {}
      }
      picked.add(
        StagedFile(
          name: pf.name,
          size: size,
          mimeType: lookupMimeType(pf.name) ?? 'application/octet-stream',
          path: path,
        ),
      );
    }
    if (picked.isNotEmpty && mounted) {
      setState(() {
        _stagedFiles = picked;
      });
    }
  }

  void _handleDroppedFiles(List<String> paths) {
    final picked = <StagedFile>[];
    for (final path in paths) {
      final f = File(path);
      if (f.existsSync()) {
        final name = p.basename(path);
        picked.add(
          StagedFile(
            name: name,
            size: f.lengthSync(),
            mimeType: lookupMimeType(name) ?? 'application/octet-stream',
            path: path,
          ),
        );
      }
    }
    if (picked.isNotEmpty && mounted) {
      setState(() {
        _stagedFiles = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.settings.strings;
    final stage = _selectedDevice != null && _stagedFiles.isNotEmpty
        ? 2
        : (_stagedFiles.isNotEmpty ? 1 : 0);

    return DropTarget(
      onDragEntered: (_) => setState(() => _draggingOver = true),
      onDragExited: (_) => setState(() => _draggingOver = false),
      onDragDone: (details) {
        setState(() => _draggingOver = false);
        _handleDroppedFiles(details.files.map((x) => x.path).toList());
      },
      child: SafeArea(
        child: Column(
          children: [
            if (widget.isShareSheet) _buildShareSheetHeader(context, strings),
            Expanded(
              child: ExpressiveStageSwitcher(
                child: switch (stage) {
                  0 => _buildPickerStage(context, strings),
                  1 => _buildRadarStage(context, strings),
                  _ => _buildThrowStage(context, strings),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareSheetHeader(BuildContext context, AppStrings strings) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
      child: Row(
        children: [
          Icon(
            Icons.near_me_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text('MaterialDrop', style: textTheme.titleLarge),
          const Spacer(),
          IconButton.filledTonal(
            onPressed: () {
              widget.coordinator.cancelOutgoing();
              widget.onCloseShareSheet?.call();
            },
            icon: const Icon(Icons.close_rounded),
            tooltip: strings.tr('close'),
          ),
        ],
      ),
    );
  }

  Widget _buildPickerStage(BuildContext context, AppStrings strings) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      key: const ValueKey('stage_picker'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 44),
            decoration: BoxDecoration(
              color: _draggingOver
                  ? scheme.primaryContainer.withValues(alpha: 0.35)
                  : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: _draggingOver
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.6),
                width: _draggingOver ? 2.2 : 1.2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  shape: const ScallopBorder(lobes: 12, depth: 0.14),
                  color: scheme.primaryContainer,
                  child: SizedBox(
                    width: 104,
                    height: 104,
                    child: Center(
                      child: Icon(
                        Icons.upload_file_rounded,
                        size: 46,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _draggingOver
                      ? strings.tr('drop_files_here')
                      : strings.tr('select_file'),
                  textAlign: TextAlign.center,
                  style: textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  Platform.isAndroid
                      ? strings.tr('select_file_hint_mobile')
                      : strings.tr('select_file_hint'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(strings.tr('choose_files')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStagedFilesCard(
    BuildContext context,
    AppStrings strings,
    int totalBytes,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                _stagedFiles.length > 1
                    ? Icons.inventory_2_rounded
                    : Icons.insert_drive_file_rounded,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _stagedFiles.length == 1
                        ? _stagedFiles.first.name
                        : strings.tr('files_ready', {
                            'count': '${_stagedFiles.length}',
                          }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall,
                  ),
                  Text(
                    formatFileSize(totalBytes),
                    style: textTheme.bodySmall?.tabular.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _pickFiles,
              child: Text(strings.tr('change')),
            ),
            if (!widget.isShareSheet)
              IconButton(
                onPressed: () => setState(() => _stagedFiles = []),
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: strings.tr('clear'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadarStage(BuildContext context, AppStrings strings) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final devices = widget.coordinator.devices;
    final totalBytes = _stagedFiles.fold<int>(0, (s, f) => s + f.size);
    final isDesktopWide = MediaQuery.sizeOf(context).width >= 820;

    if (isDesktopWide) {
      return Padding(
        key: const ValueKey('stage_radar_desktop'),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SonarRadar(
                          devices: devices,
                          thisDeviceLabel: strings.tr('this_device'),
                          isTrusted: (d) => widget.settings.isDeviceTrusted(d),
                          onDeviceSelected: (dev) {
                            setState(() => _selectedDevice = dev);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      devices.isEmpty
                          ? strings.tr('searching_devices')
                          : strings.tr('select_device_first'),
                      style: textTheme.bodyMedium?.copyWith(
                        color: devices.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 20),
            SizedBox(
              width: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStagedFilesCard(context, strings, totalBytes),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Card(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    devices.isEmpty
                                        ? strings.tr('searching_devices')
                                        : strings.tr('found_devices', {
                                            'count': '${devices.length}',
                                          }),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall,
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed: () =>
                                      widget.coordinator.refreshDiscovery(),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 18,
                                  ),
                                  tooltip: strings.tr('refresh'),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          Expanded(
                            child: devices.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(
                                            width: 28,
                                            height: 28,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            strings.tr('searching_devices'),
                                            textAlign: TextAlign.center,
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.all(12),
                                    itemCount: devices.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, idx) {
                                      final dev = devices[idx];
                                      final trusted = widget.settings
                                          .isDeviceTrusted(dev);
                                      final protoLabel = dev.protocol ==
                                              TransferProtocol.quickShare
                                          ? strings.tr('protocol_quickshare')
                                          : (dev.isUsb
                                              ? strings.tr('usb_badge')
                                              : strings.tr('protocol_direct'));
                                      return ListTile(
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                        ),
                                        tileColor: scheme.surfaceContainerLow,
                                        onTap: () => setState(
                                            () => _selectedDevice = dev),
                                        leading: CircleAvatar(
                                          backgroundColor: trusted
                                              ? scheme.primaryContainer
                                              : scheme.surfaceContainerHighest,
                                          child: Icon(
                                            dev.isUsb
                                                ? Icons.usb_rounded
                                                : (dev.kind == DeviceKind.pc
                                                    ? Icons
                                                        .laptop_windows_rounded
                                                    : Icons.smartphone_rounded),
                                            size: 20,
                                            color: trusted
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurface,
                                          ),
                                        ),
                                        title: Text(
                                          dev.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '$protoLabel • ${dev.ip}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.bodySmall?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                        trailing: Icon(
                                          trusted
                                              ? Icons.star_rounded
                                              : Icons.chevron_right_rounded,
                                          color: trusted
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant,
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      key: const ValueKey('stage_radar'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          // Staged files summary bar
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _buildStagedFilesCard(context, strings, totalBytes),
          ),

          const SizedBox(height: 8),

          // Sonar Radar
          Expanded(
            child: Center(
              child: SonarRadar(
                devices: devices,
                thisDeviceLabel: strings.tr('this_device'),
                isTrusted: (d) => widget.settings.isDeviceTrusted(d),
                onDeviceSelected: (dev) {
                  setState(() {
                    _selectedDevice = dev;
                  });
                },
              ),
            ),
          ),

          // Quick device chips & status bar
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                if (devices.isNotEmpty)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        for (final dev in devices) ...[
                          ActionChip(
                            avatar: Icon(
                              dev.isUsb
                                  ? Icons.usb_rounded
                                  : (dev.kind == DeviceKind.pc
                                      ? Icons.laptop_windows_rounded
                                      : Icons.smartphone_rounded),
                              size: 16,
                              color: widget.settings.isDeviceTrusted(dev)
                                  ? scheme.primary
                                  : null,
                            ),
                            label: Text(
                              '${dev.name} • ${dev.protocol == TransferProtocol.quickShare ? strings.tr('protocol_quickshare') : (dev.isUsb ? strings.tr('usb_badge') : strings.tr('protocol_direct'))}',
                            ),
                            onPressed: () => setState(() => _selectedDevice = dev),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          devices.isEmpty
                              ? strings.tr('searching_devices')
                              : strings.tr('select_device_first'),
                          style: textTheme.bodyMedium?.copyWith(
                            color: devices.isEmpty
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        onPressed: () => widget.coordinator.refreshDiscovery(),
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        tooltip: strings.tr('refresh'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThrowStage(BuildContext context, AppStrings strings) {
    final device = _selectedDevice!;
    final status = widget.coordinator.outgoingState;
    final trusted = widget.settings.isDeviceTrusted(device);
    final isTransferBusy = status is OutgoingConnecting ||
        status is OutgoingPinReady ||
        status is OutgoingTransferring;

    return SingleChildScrollView(
      key: ValueKey('stage_throw_${device.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              // Top bar: back to radar + trust toggle
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      if (isTransferBusy) {
                        widget.coordinator.cancelOutgoing();
                      } else {
                        widget.coordinator.resetOutgoing();
                      }
                      setState(() => _selectedDevice = null);
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: Text(strings.tr('change_device')),
                  ),
                  FilterChip(
                    selected: trusted,
                    onSelected: (val) => widget.settings.setTrusted(
                      device.name,
                      val,
                      extraId: device.id,
                    ),
                    avatar: Icon(
                      trusted ? Icons.star_rounded : Icons.star_outline_rounded,
                      size: 16,
                    ),
                    label: Text(
                      trusted
                          ? strings.tr('trusted_badge')
                          : strings.tr('trust_device'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Active outgoing status card
              if (status is! OutgoingIdle) ...[
                _buildOutgoingStatusCard(context, strings, status),
                const SizedBox(height: 16),
              ],

              // Swipeable playing card when not mid-transfer / completed
              if (!isTransferBusy && status is! OutgoingCompleted)
                SwipeableFileCard(
                  files: _stagedFiles,
                  targetDevice: device,
                  strings: strings,
                  onThrowSuccess: () {
                    widget.coordinator.sendFiles(device, _stagedFiles);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOutgoingStatusCard(
    BuildContext context,
    AppStrings strings,
    OutgoingTransferState status,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    switch (status) {
      case OutgoingConnecting(:final deviceName):
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  strings.tr('connecting_to', {'device': deviceName}),
                  style: textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: widget.coordinator.cancelOutgoing,
                  child: Text(strings.tr('cancel')),
                ),
              ],
            ),
          ),
        );

      case OutgoingPinReady(:final deviceName, :final pin):
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  strings.tr('connecting_to', {'device': deviceName}),
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _PinBanner(pin: pin, strings: strings),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: widget.coordinator.cancelOutgoing,
                  child: Text(strings.tr('cancel')),
                ),
              ],
            ),
          ),
        );

      case OutgoingTransferring(
          :final deviceName,
          :final fileName,
          :final progress,
          :final bytesSent,
          :final totalBytes,
          :final speedBps,
          :final pin,
        ):
        final pct = (progress * 100).round().clamp(0, 100);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.tr('sending_to', {'device': deviceName}),
                            style: textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: textTheme.titleMedium?.tabular.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                if (pin != null) ...[
                  const SizedBox(height: 12),
                  _PinBanner(pin: pin, strings: strings),
                ],
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${formatFileSize(bytesSent)} / ${formatFileSize(totalBytes)} • ${formatSpeed(speedBps)}',
                      style: textTheme.bodySmall?.tabular,
                    ),
                    FilledButton.tonal(
                      onPressed: widget.coordinator.cancelOutgoing,
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.errorContainer,
                        foregroundColor: scheme.onErrorContainer,
                      ),
                      child: Text(strings.tr('cancel')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

      case OutgoingCompleted(:final deviceName):
        return Card(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: scheme.onTertiaryContainer,
                  size: 32,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    strings.tr('sent_success', {'device': deviceName}),
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case OutgoingError(:final message):
        return Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Icon(Icons.error_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case OutgoingCanceled():
        return Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.cancel_rounded, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(
                  strings.tr('transfer_canceled'),
                  style: textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );

      case OutgoingIdle():
        return const SizedBox.shrink();
    }
  }
}

class _PinBanner extends StatelessWidget {
  final String pin;
  final AppStrings strings;

  const _PinBanner({required this.pin, required this.strings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.pin_rounded, color: scheme.onPrimaryContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.tr('pin_code_label'),
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  strings.tr('pin_match_hint'),
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          Text(
            pin,
            style: textTheme.titleLarge?.tabular.copyWith(
              color: scheme.onPrimaryContainer,
              letterSpacing: 3,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

