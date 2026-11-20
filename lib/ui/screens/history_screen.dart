import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import '../../services/settings_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scallop_shape.dart';

class HistoryScreen extends StatelessWidget {
  final SettingsController settings;

  const HistoryScreen({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final strings = settings.strings;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final entries = settings.history;

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.tr('history_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.headlineMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: () => PlatformBridge.instance.showInFolder(
                        '',
                        settings.downloadDir,
                      ),
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(strings.tr('open_downloads')),
                    ),
                    if (entries.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: strings.tr('clear_history'),
                        onPressed: settings.clearHistory,
                        icon: const Icon(Icons.delete_sweep_rounded),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Material(
                                shape: const ScallopBorder(
                                  lobes: 12,
                                  depth: 0.14,
                                ),
                                color: scheme.secondaryContainer,
                                child: SizedBox(
                                  width: 88,
                                  height: 88,
                                  child: Center(
                                    child: Icon(
                                      Icons.history_rounded,
                                      size: 40,
                                      color: scheme.onSecondaryContainer,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                strings.tr('history_empty_title'),
                                style: textTheme.titleLarge,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                strings.tr('history_empty_desc'),
                                style: textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, idx) {
                          final e = entries[idx];
                          return _HistoryTile(
                            entry: e,
                            settings: settings,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final HistoryEntry entry;
  final SettingsController settings;

  const _HistoryTile({
    required this.entry,
    required this.settings,
  });

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    AppStrings strings,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

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
        PopupMenuItem(
          value: 'open',
          child: Text(strings.tr('ctx_open')),
        ),
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
      position: position,
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
          settings.downloadDir,
        );
      case 'copy_path':
        await PlatformBridge.instance.copyTextToClipboard(entry.pathOrUri);
    }
  }

  bool _isLocalImage() {
    if (entry.isText || entry.pathOrUri.isEmpty) return false;
    if (entry.pathOrUri.startsWith('content://')) return false;
    final lower = entry.fileName.toLowerCase();
    final isImg = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
    return isImg && File(entry.pathOrUri).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final strings = settings.strings;
    final isIn = entry.direction == TransferDirection.incoming;
    final dt = entry.timestamp;
    final timeStr =
        '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    final VoidCallback? primaryAction = (entry.isText && entry.textBody != null)
        ? () => PlatformBridge.instance.copyTextToClipboard(entry.textBody!)
        : (entry.pathOrUri.isNotEmpty
            ? () => PlatformBridge.instance.openFile(
                  entry.pathOrUri,
                  mimeType: entry.mimeType,
                )
            : null);

    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition, strings),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: primaryAction,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              _isLocalImage()
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(entry.pathOrUri),
                        width: 46,
                        height: 46,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: isIn
                            ? scheme.tertiaryContainer
                            : scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        entry.isText
                            ? Icons.text_snippet_rounded
                            : (isIn
                                ? Icons.south_west_rounded
                                : Icons.north_east_rounded),
                        color: isIn
                            ? scheme.onTertiaryContainer
                            : scheme.onPrimaryContainer,
                      ),
                    ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${isIn ? strings.tr('direction_in') : strings.tr('direction_out')} • ${entry.peerName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            switch (entry.protocol) {
                              TransferProtocol.quickShare =>
                                strings.tr('protocol_quickshare'),
                              TransferProtocol.tapProximity =>
                                strings.tr('protocol_tap'),
                              TransferProtocol.internetP2p =>
                                strings.tr('protocol_iroh'),
                              _ => strings.tr('protocol_direct'),
                            },
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          '${formatFileSize(entry.size)} • $timeStr',
                          style: textTheme.labelSmall?.tabular.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (primaryAction != null) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: entry.isText
                      ? strings.tr('copy_text')
                      : strings.tr('open_file'),
                  onPressed: primaryAction,
                  icon: Icon(
                    entry.isText
                        ? Icons.copy_rounded
                        : Icons.open_in_new_rounded,
                    size: 20,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}

