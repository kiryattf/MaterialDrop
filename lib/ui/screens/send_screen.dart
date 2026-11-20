import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/direct/md_constants.dart';
import '../../protocol/iroh/iroh_link.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/desktop_bridge.dart';
import '../../services/platform_bridge.dart';
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
  final VoidCallback? onOpenReceiveTab;
  final VoidCallback? onOpenHistoryTab;

  const SendScreen({
    super.key,
    required this.settings,
    required this.coordinator,
    this.initialFiles = const [],
    this.isShareSheet = false,
    this.onCloseShareSheet,
    this.onOpenReceiveTab,
    this.onOpenHistoryTab,
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
    for (final rawPath in paths) {
      final type = FileSystemEntity.typeSync(rawPath, followLinks: true);
      if (type == FileSystemEntityType.file) {
        final f = File(rawPath);
        final name = p.basename(rawPath);
        picked.add(
          StagedFile(
            name: name,
            size: f.lengthSync(),
            mimeType: lookupMimeType(name) ?? 'application/octet-stream',
            path: rawPath,
          ),
        );
      } else if (type == FileSystemEntityType.directory) {
        final rootDir = Directory(rawPath);
        final rootName = p.basename(p.normalize(rawPath));
        try {
          for (final entity
              in rootDir.listSync(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final relUnderRoot = p.relative(entity.path, from: rawPath);
            final parts = p.split(relUnderRoot);
            if (parts.any((seg) => seg.startsWith('.'))) continue;
            final normalizedRel = MdConstants.sanitizeRelativePath(
              p.posix.join(rootName, p.posix.joinAll(parts)),
            );
            final name = p.basename(entity.path);
            picked.add(
              StagedFile(
                name: name,
                size: entity.lengthSync(),
                mimeType: lookupMimeType(name) ?? 'application/octet-stream',
                path: entity.path,
                relativePath: normalizedRel,
              ),
            );
          }
        } catch (_) {}
      }
    }
    if (picked.isNotEmpty && mounted) {
      setState(() {
        _stagedFiles = picked;
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final strings = widget.settings.strings;
    final stagingDir = await PlatformBridge.instance.getTempStagingDir();
    final payload = await DesktopBridge.instance.readClipboardPayload(
      stagingDir.path,
    );
    if (!mounted) return;

    switch (payload.type) {
      case ClipboardContentType.files:
        _handleDroppedFiles(payload.paths);
        if (mounted && _stagedFiles.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                strings.tr('clipboard_pasted', {'count': '${_stagedFiles.length}'}),
              ),
            ),
          );
        }
      case ClipboardContentType.imageFile:
        final path = payload.paths.isNotEmpty ? payload.paths.first : '';
        final file = File(path);
        if (file.existsSync()) {
          final name = p.basename(path);
          setState(() {
            _stagedFiles = [
              StagedFile(
                name: name,
                size: file.lengthSync(),
                mimeType: lookupMimeType(name) ?? 'image/png',
                path: path,
              ),
            ];
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(strings.tr('clipboard_pasted', {'count': '1'})),
            ),
          );
        }
      case ClipboardContentType.text:
        final text = payload.text ?? '';
        if (text.isNotEmpty) {
          final file = File(
            p.join(
              stagingDir.path,
              'clipboard_${DateTime.now().millisecondsSinceEpoch}.txt',
            ),
          );
          await file.writeAsString(text, flush: true);
          final len = await file.length();
          if (!mounted) return;
          setState(() {
            _stagedFiles = [
              StagedFile(
                name: 'clipboard_text.txt',
                size: len,
                mimeType: 'text/plain',
                path: file.path,
              ),
            ];
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(strings.tr('clipboard_pasted', {'count': '1'})),
            ),
          );
        }
      case ClipboardContentType.empty:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.tr('clipboard_empty'))),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.settings.strings;
    final stage = _selectedDevice != null && _stagedFiles.isNotEmpty
        ? 2
        : (_stagedFiles.isNotEmpty ? 1 : 0);

    final content = DropTarget(
      onDragEntered: (_) => setState(() => _draggingOver = true),
      onDragExited: (_) => setState(() => _draggingOver = false),
      onDragDone: (details) {
        setState(() => _draggingOver = false);
        _handleDroppedFiles(details.files.map((x) => x.path).toList());
      },
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final useSupportingPane = !widget.isShareSheet &&
                MediaQuery.sizeOf(context).width >= 840 &&
                constraints.maxWidth >= 720;
            if (useSupportingPane) {
              return _buildDesktopSupportingLayout(context, strings);
            }
            return Column(
              children: [
                if (widget.isShareSheet)
                  _buildShareSheetHeader(context, strings),
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
            );
          },
        ),
      ),
    );

    if (!DesktopBridge.instance.isDesktop) {
      return content;
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _pasteFromClipboard,
      },
      child: Focus(
        autofocus: true,
        child: content,
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
                      : strings.tr('drop_folder_hint'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: Text(strings.tr('choose_files')),
                    ),
                    if (DesktopBridge.instance.isDesktop)
                      OutlinedButton.icon(
                        onPressed: _pasteFromClipboard,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: Text(strings.tr('paste_clipboard')),
                      ),
                    if (widget.settings.internetP2pEnabled)
                      OutlinedButton.icon(
                        onPressed: () => _openConnectP2pDialog(context, strings),
                        icon: const Icon(Icons.public_rounded),
                        label: Text(strings.tr('connect_p2p_link')),
                      ),
                  ],
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
    final showAndroidQuickShare = Platform.isAndroid;
    final showP2pButton = widget.settings.internetP2pEnabled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
            if (showAndroidQuickShare || showP2pButton) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (showAndroidQuickShare)
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          PlatformBridge.instance.shareViaSystemQuickShare(
                        _stagedFiles,
                      ),
                      icon: const Icon(Icons.bolt_rounded, size: 18),
                      label: Text(strings.tr('send_via_system_qs')),
                    ),
                  if (showP2pButton)
                    OutlinedButton.icon(
                      onPressed: () => _openConnectP2pDialog(context, strings),
                      icon: const Icon(Icons.public_rounded, size: 18),
                      label: Text(strings.tr('connect_p2p_link')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openConnectP2pDialog(
    BuildContext context,
    AppStrings strings,
  ) async {
    final controller = TextEditingController();
    String? errorText;
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          icon: const Icon(Icons.public_rounded),
          title: Text(strings.tr('connect_p2p_title')),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: strings.tr('connect_p2p_hint'),
              errorText: errorText,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(strings.tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                final parsed = IrohDeepLink.parse(controller.text);
                if (parsed == null) {
                  setDialogState(() {
                    errorText = strings.tr('connect_p2p_invalid');
                  });
                  return;
                }
                Navigator.of(ctx).pop(controller.text.trim());
              },
              child: Text(strings.tr('connect_btn')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (res == null || res.isEmpty) return;

    final dev = widget.coordinator.connectIrohLink(res);
    if (dev != null && mounted) {
      if (_stagedFiles.isEmpty) {
        await _pickFiles();
      }
      if (mounted && _stagedFiles.isNotEmpty) {
        setState(() => _selectedDevice = dev);
      }
    }
  }

  Widget _buildDesktopSupportingLayout(
    BuildContext context,
    AppStrings strings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final devices = widget.coordinator.devices;
    final totalBytes = _stagedFiles.fold<int>(0, (s, f) => s + f.size);
    final isThrowing = _selectedDevice != null && _stagedFiles.isNotEmpty;

    return Padding(
      key: const ValueKey('stage_desktop_supporting'),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left Main Pane: Drag-and-Drop DropZone + Radar / Throw stage
          Expanded(
            flex: 6,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _draggingOver
                    ? scheme.primaryContainer.withValues(alpha: 0.28)
                    : scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: _draggingOver
                      ? scheme.primary
                      : scheme.outlineVariant.withValues(alpha: 0.45),
                  width: _draggingOver ? 2.2 : 1,
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_stagedFiles.isNotEmpty)
                    _buildStagedFilesCard(context, strings, totalBytes)
                  else
                    _buildDesktopDropBanner(context, strings),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ExpressiveStageSwitcher(
                      child: isThrowing
                          ? _buildThrowStage(context, strings)
                          : Column(
                              key: const ValueKey('desktop_radar_pane'),
                              children: [
                                Expanded(
                                  child: Center(
                                    child: SonarRadar(
                                      devices: devices,
                                      thisDeviceLabel:
                                          strings.tr('this_device'),
                                      isTrusted: (d) =>
                                          widget.settings.isDeviceTrusted(d),
                                      onDeviceSelected: (dev) =>
                                          _selectOrPickForDevice(dev),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
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
                                      ),
                                    ),
                                    const SizedBox(width: 8),
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
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 16),

          // Right Supporting Pane: Queue, Devices, Recent History, Quick Settings
          SizedBox(
            width: 368,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSupportingQueueCard(context, strings, totalBytes),
                  const SizedBox(height: 12),
                  _buildSupportingDevicesCard(context, strings, devices),
                  const SizedBox(height: 12),
                  _buildSupportingHistoryCard(context, strings),
                  const SizedBox(height: 12),
                  _buildSupportingQuickSettingsCard(context, strings),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _protocolLabel(NearbyDevice dev, AppStrings strings) {
    if (dev.protocol == TransferProtocol.quickShare) {
      return strings.tr('protocol_quickshare');
    }
    if (dev.protocol == TransferProtocol.internetP2p) {
      return strings.tr('protocol_iroh');
    }
    if (dev.protocol == TransferProtocol.tapProximity) {
      final zoneKey = switch (dev.proximityZone) {
        'immediate' => 'proximity_immediate',
        'near' => 'proximity_near',
        _ => 'proximity_far',
      };
      return '${strings.tr('protocol_tap')} (${strings.tr(zoneKey)})';
    }
    return dev.isUsb ? strings.tr('usb_badge') : strings.tr('protocol_direct');
  }

  Future<void> _selectOrPickForDevice(NearbyDevice dev) async {
    if (_stagedFiles.isEmpty) {
      await _pickFiles();
    }
    if (_stagedFiles.isNotEmpty && mounted) {
      setState(() => _selectedDevice = dev);
    }
  }

  Widget _buildDesktopDropBanner(BuildContext context, AppStrings strings) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerHigh,
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
                Icons.upload_file_rounded,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _draggingOver
                        ? strings.tr('drop_files_here')
                        : strings.tr('select_file'),
                    style: textTheme.titleSmall,
                  ),
                  Text(
                    strings.tr('drop_folder_hint'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (DesktopBridge.instance.isDesktop) ...[
              IconButton.outlined(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                tooltip: strings.tr('paste_clipboard'),
              ),
              const SizedBox(width: 6),
            ],
            FilledButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(strings.tr('choose_files')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportingQueueCard(
    BuildContext context,
    AppStrings strings,
    int totalBytes,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final outgoing = widget.coordinator.outgoingState;
    final incoming = widget.coordinator.incomingState;

    if (outgoing is! OutgoingIdle) {
      return _buildOutgoingStatusCard(context, strings, outgoing);
    }

    if (incoming is! IncomingIdle) {
      return Card(
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.download_rounded,
                    color: scheme.onSecondaryContainer,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      strings.tr('tab_receive'),
                      style: textTheme.titleSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenReceiveTab,
                    child: Text(strings.tr('ctx_open')),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (incoming is IncomingOfferPending) ...[
                Text(
                  '${incoming.offer.senderName} • ${incoming.offer.files.length + incoming.offer.texts.length} (${formatFileSize(incoming.offer.totalSize)})',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(
                      onPressed: () => widget.coordinator.acceptIncoming(),
                      child: Text(strings.tr('accept')),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.coordinator.cancelIncoming(),
                      child: Text(strings.tr('decline')),
                    ),
                  ],
                ),
              ] else if (incoming is IncomingReceiving) ...[
                Text(
                  incoming.currentFileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: incoming.progress > 0 ? incoming.progress : null,
                ),
              ] else if (incoming is IncomingCompleted) ...[
                Text(
                  strings.tr('tray_received_body', {
                    'device': incoming.offer.senderName,
                    'count':
                        '${incoming.savedItems.length + incoming.receivedTexts.length}',
                  }),
                  style: textTheme.bodySmall,
                ),
              ] else if (incoming is IncomingError) ...[
                Text(incoming.message, style: textTheme.bodySmall),
              ],
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.layers_rounded, color: scheme.primary, size: 18),
                const SizedBox(width: 8),
                Text(strings.tr('queue_title'), style: textTheme.titleSmall),
                const Spacer(),
                if (_stagedFiles.isNotEmpty)
                  Text(
                    formatFileSize(totalBytes),
                    style: textTheme.labelMedium?.tabular.copyWith(
                      color: scheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_stagedFiles.isEmpty)
              Text(
                strings.tr('drop_folder_hint'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              for (final f in _stagedFiles.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.insert_drive_file_outlined,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          f.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        formatFileSize(f.size),
                        style: textTheme.labelSmall?.tabular.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_stagedFiles.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '+${_stagedFiles.length - 3} more',
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSupportingDevicesCard(
    BuildContext context,
    AppStrings strings,
    List<NearbyDevice> devices,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.devices_rounded, color: scheme.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    devices.isEmpty
                        ? strings.tr('nearby_devices_title')
                        : '${strings.tr('nearby_devices_title')} (${devices.length})',
                    style: textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  onPressed: () => widget.coordinator.refreshDiscovery(),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: strings.tr('refresh'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (devices.isEmpty)
              Text(
                strings.tr('searching_devices'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final dev in devices) ...[
                GestureDetector(
                  onSecondaryTapDown: (details) => _showDeviceContextMenu(
                    context,
                    details.globalPosition,
                    dev,
                    strings,
                  ),
                  child: Card(
                    elevation: 0,
                    color: _selectedDevice?.id == dev.id
                        ? scheme.primaryContainer.withValues(alpha: 0.45)
                        : scheme.surfaceContainerLow,
                    margin: const EdgeInsets.only(bottom: 6),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      hoverColor: scheme.primary.withValues(alpha: 0.08),
                      onTap: () => _selectOrPickForDevice(dev),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              dev.isUsb
                                  ? Icons.usb_rounded
                                  : (dev.kind == DeviceKind.pc
                                      ? Icons.laptop_windows_rounded
                                      : Icons.smartphone_rounded),
                              size: 18,
                              color: widget.settings.isDeviceTrusted(dev)
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    dev.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    dev.protocol == TransferProtocol.tapProximity
                                        ? '${_protocolLabel(dev, strings)}${dev.rssi != null ? ' • ${dev.rssi} dBm' : ''}'
                                        : (dev.protocol ==
                                                TransferProtocol.internetP2p
                                            ? '${_protocolLabel(dev, strings)} • ${dev.ip}'
                                            : '${_protocolLabel(dev, strings)} • ${dev.ip}:${dev.port}'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (widget.settings.isDeviceTrusted(dev))
                              Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: scheme.primary,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildSupportingHistoryCard(
    BuildContext context,
    AppStrings strings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final recent = widget.settings.history.take(4).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, color: scheme.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.tr('recent_history_title'),
                    style: textTheme.titleSmall,
                  ),
                ),
                if (widget.onOpenHistoryTab != null)
                  TextButton(
                    onPressed: widget.onOpenHistoryTab,
                    child: Text(strings.tr('tab_history')),
                  ),
              ],
            ),
            if (recent.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  strings.tr('history_empty_title'),
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final entry in recent)
                GestureDetector(
                  onSecondaryTapDown: (details) => _showHistoryContextMenu(
                    context,
                    details.globalPosition,
                    entry,
                    strings,
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    hoverColor: scheme.primary.withValues(alpha: 0.08),
                    onTap: (entry.isText && entry.textBody != null)
                        ? () => PlatformBridge.instance
                            .copyTextToClipboard(entry.textBody!)
                        : (entry.pathOrUri.isNotEmpty
                            ? () => PlatformBridge.instance.openFile(
                                  entry.pathOrUri,
                                  mimeType: entry.mimeType,
                                )
                            : null),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            entry.direction == TransferDirection.incoming
                                ? Icons.south_west_rounded
                                : Icons.north_east_rounded,
                            size: 16,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            formatFileSize(entry.size),
                            style: textTheme.labelSmall?.tabular.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportingQuickSettingsCard(
    BuildContext context,
    AppStrings strings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final port = widget.settings.launchConfig.port ?? 45873;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune_rounded, color: scheme.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      strings.tr('quick_settings_title'),
                      style: textTheme.titleSmall,
                    ),
                  ],
                ),
                ActionChip(
                  label: Text(
                    '${widget.settings.deviceName} • :$port',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _editDeviceNameDialog(context, strings),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.folder_outlined, color: scheme.primary),
              title: Text(strings.tr('settings_save_folder')),
              subtitle: Text(
                widget.settings.downloadDir,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                onPressed: () => PlatformBridge.instance.showInFolder(
                  '',
                  widget.settings.downloadDir,
                ),
              ),
              onTap: () async {
                final picked = await FilePicker.platform.getDirectoryPath();
                if (picked != null && picked.isNotEmpty) {
                  await widget.settings.setDownloadDir(picked);
                  await widget.coordinator.onSettingsUpdated();
                }
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(strings.tr('settings_auto_all')),
              value: widget.settings.autoAcceptAll,
              onChanged: (v) async {
                await widget.settings.setAutoAcceptAll(v);
                await widget.coordinator.onSettingsUpdated();
              },
            ),
            if (DesktopBridge.instance.isDesktop)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(strings.tr('settings_minimize_tray')),
                value: widget.settings.minimizeToTray,
                onChanged: (v) => widget.settings.setMinimizeToTray(v),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDeviceNameDialog(
    BuildContext context,
    AppStrings strings,
  ) async {
    final controller = TextEditingController(text: widget.settings.deviceName);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.tr('device_name_label')),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(strings.tr('save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (updated != null && updated.trim().isNotEmpty) {
      await widget.settings.setDeviceName(updated.trim());
      await widget.coordinator.onSettingsUpdated();
    }
  }

  Future<void> _showDeviceContextMenu(
    BuildContext context,
    Offset globalPosition,
    NearbyDevice device,
    AppStrings strings,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final trusted = widget.settings.isDeviceTrusted(device);
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'send', child: Text(strings.tr('ctx_send'))),
        PopupMenuItem(
          value: 'trust',
          child: Text(
            trusted ? strings.tr('ctx_untrust') : strings.tr('ctx_trust'),
          ),
        ),
        if (device.ip.isNotEmpty)
          PopupMenuItem(
            value: 'copy_ip',
            child: Text(strings.tr('ctx_copy_ip')),
          ),
      ],
    );
    switch (chosen) {
      case 'send':
        await _selectOrPickForDevice(device);
      case 'trust':
        await widget.settings.setTrusted(
          device.name,
          !trusted,
          extraId: device.id,
        );
      case 'copy_ip':
        await PlatformBridge.instance.copyTextToClipboard(
          '${device.ip}:${device.port}',
        );
    }
  }

  Future<void> _showHistoryContextMenu(
    BuildContext context,
    Offset globalPosition,
    HistoryEntry entry,
    AppStrings strings,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final items = <PopupMenuEntry<String>>[];
    if (entry.isText && entry.textBody != null) {
      items.add(
        PopupMenuItem(
          value: 'copy_text',
          child: Text(strings.tr('ctx_copy_text')),
        ),
      );
    } else if (entry.pathOrUri.isNotEmpty) {
      items.addAll([
        PopupMenuItem(value: 'open', child: Text(strings.tr('ctx_open'))),
        PopupMenuItem(
          value: 'folder',
          child: Text(strings.tr('ctx_show_folder')),
        ),
        PopupMenuItem(
          value: 'copy_path',
          child: Text(strings.tr('ctx_copy_path')),
        ),
      ]);
    }
    if (items.isEmpty) return;

    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    switch (chosen) {
      case 'copy_text':
        if (entry.textBody != null) {
          await PlatformBridge.instance.copyTextToClipboard(entry.textBody!);
        }
      case 'open':
        await PlatformBridge.instance.openFile(
          entry.pathOrUri,
          mimeType: entry.mimeType,
        );
      case 'folder':
        await PlatformBridge.instance.showInFolder(
          entry.pathOrUri,
          widget.settings.downloadDir,
        );
      case 'copy_path':
        await PlatformBridge.instance.copyTextToClipboard(entry.pathOrUri);
    }
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
                                      final protoLabel =
                                          _protocolLabel(dev, strings);
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
                              '${dev.name} • ${_protocolLabel(dev, strings)}',
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
                      if (widget.settings.internetP2pEnabled) ...[
                        IconButton.outlined(
                          onPressed: () => _openConnectP2pDialog(context, strings),
                          icon: const Icon(Icons.add_link_rounded, size: 20),
                          tooltip: strings.tr('connect_p2p_link'),
                        ),
                        const SizedBox(width: 6),
                      ],
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

