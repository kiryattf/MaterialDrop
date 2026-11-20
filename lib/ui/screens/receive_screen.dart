import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/platform_bridge.dart';
import '../../services/settings_controller.dart';
import '../../theme/app_theme.dart';
import '../motion/md3_springs.dart';
import '../widgets/scallop_shape.dart';

class ReceiveScreen extends StatefulWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;

  const ReceiveScreen({
    super.key,
    required this.settings,
    required this.coordinator,
  });

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  bool _alwaysTrust = false;
  String? _copiedTextId;

  @override
  Widget build(BuildContext context) {
    final strings = widget.settings.strings;
    final state = widget.coordinator.incomingState;

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ExpressiveStageSwitcher(
              child: switch (state) {
                IncomingIdle() => _buildStandby(context, strings),
                IncomingOfferPending(:final offer) =>
                  _buildOfferCard(context, strings, offer),
                IncomingReceiving() =>
                  _buildReceivingCard(context, strings, state),
                IncomingCompleted() =>
                  _buildCompletedCard(context, strings, state),
                IncomingError(:final message) =>
                  _buildErrorCard(context, strings, message),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStandby(BuildContext context, AppStrings strings) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final ips = widget.coordinator.localIps;
    final ipStr = ips.isNotEmpty ? ips.join(' • ') : '127.0.0.1';
    final qsPort = widget.coordinator.quickSharePort;

    return Column(
      key: const ValueKey('receive_idle'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          shape: const ScallopBorder(lobes: 12, depth: 0.14),
          color: scheme.tertiaryContainer,
          child: SizedBox(
            width: 112,
            height: 112,
            child: Center(
              child: Icon(
                Icons.download_rounded,
                size: 48,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: AppTheme.statusGreen,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              strings.tr('ready_to_receive'),
              style: textTheme.headlineSmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          strings.tr('receive_subtitle'),
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        Card(
          child: Column(
            children: [
              _InfoRow(
                label: strings.tr('device_name_label'),
                value: widget.settings.deviceName,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _InfoRow(
                label: strings.tr('ip_label'),
                value: ipStr,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _InfoRow(
                label: strings.tr('md_port_label'),
                value: '${widget.coordinator.directPort}',
              ),
              if (widget.settings.quickShareEnabled && qsPort > 0) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                _InfoRow(
                  label: strings.tr('qs_port_label'),
                  value: '$qsPort',
                ),
              ],
              if (widget.settings.internetP2pEnabled &&
                  widget.coordinator.isIrohReady) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Text(
                        strings.tr('p2p_link_label'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.coordinator.localIrohDeepLink,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        onPressed: () {
                          PlatformBridge.instance.copyTextToClipboard(
                            widget.coordinator.localIrohDeepLink,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(strings.tr('p2p_link_copied')),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOfferCard(
    BuildContext context,
    AppStrings strings,
    IncomingOffer offer,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('offer_${offer.id}'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.download_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.tr('incoming_transfer'),
                        style: textTheme.titleLarge,
                      ),
                      Text(
                        strings.tr('incoming_from', {'device': offer.senderName}),
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    switch (offer.protocol) {
                      TransferProtocol.quickShare =>
                        strings.tr('protocol_quickshare'),
                      TransferProtocol.tapProximity =>
                        strings.tr('protocol_tap'),
                      TransferProtocol.internetP2p =>
                        strings.tr('protocol_iroh'),
                      _ => strings.tr('protocol_direct'),
                    },
                  ),
                ),
              ],
            ),

            if (offer.pin != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      strings.tr('pin_code_label'),
                      style: textTheme.labelLarge?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      offer.pin!,
                      style: textTheme.headlineSmall?.tabular.copyWith(
                        color: scheme.onPrimaryContainer,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            for (final f in offer.files)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: Icon(
                    Icons.insert_drive_file_rounded,
                    color: scheme.primary,
                  ),
                  title: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    formatFileSize(f.size),
                    style: textTheme.bodySmall?.tabular,
                  ),
                ),
              ),
            for (final t in offer.texts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: Icon(Icons.text_snippet_rounded, color: scheme.primary),
                  title: Text(t.title.isNotEmpty ? t.title : t.typeName),
                  subtitle: Text(t.typeName),
                ),
              ),

            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _alwaysTrust,
              onChanged: (v) => setState(() => _alwaysTrust = v ?? false),
              title: Text(strings.tr('always_trust')),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() => _alwaysTrust = false);
                      widget.coordinator.declineIncoming();
                    },
                    child: Text(
                      strings.tr('decline'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      final trust = _alwaysTrust;
                      setState(() => _alwaysTrust = false);
                      widget.coordinator.acceptIncoming(trustSender: trust);
                    },
                    child: Text(strings.tr('accept')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceivingCard(
    BuildContext context,
    AppStrings strings,
    IncomingReceiving state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final pct = (state.progress * 100).round().clamp(0, 100);

    return Card(
      key: ValueKey('receiving_${state.offer.id}'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    strings.tr('receiving_from', {
                      'device': state.offer.senderName,
                    }),
                    style: textTheme.titleLarge,
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
            const SizedBox(height: 4),
            Text(
              state.currentFileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (state.offer.pin != null) ...[
              const SizedBox(height: 12),
              Chip(
                avatar: const Icon(Icons.pin_rounded, size: 16),
                label: Text('${strings.tr('pin_code_label')}: ${state.offer.pin}'),
              ),
            ],
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: state.progress > 0 ? state.progress : null,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${formatFileSize(state.bytesReceived)} / ${formatFileSize(state.totalBytes)} • ${formatSpeed(state.speedBps)}',
                  style: textTheme.bodySmall?.tabular,
                ),
                if (state.offer.protocol == TransferProtocol.quickShare)
                  TextButton(
                    onPressed: widget.coordinator.cancelIncoming,
                    child: Text(
                      strings.tr('cancel'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedCard(
    BuildContext context,
    AppStrings strings,
    IncomingCompleted state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('completed_${state.offer.id}'),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 52,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(height: 12),
            Text(
              state.savedItems.isNotEmpty
                  ? strings.tr('saved_to_downloads')
                  : strings.tr('text_received'),
              style: textTheme.titleLarge?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            for (final item in state.savedItems)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: scheme.surface.withValues(alpha: 0.72),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onTap: () => PlatformBridge.instance.openFile(
                    item.savedPathOrUri,
                    mimeType: item.mimeType,
                  ),
                  leading: Icon(
                    Icons.insert_drive_file_rounded,
                    color: scheme.primary,
                  ),
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(formatFileSize(item.size)),
                  trailing: IconButton(
                    tooltip: Platform.isWindows
                        ? strings.tr('show_in_folder')
                        : strings.tr('open_file'),
                    onPressed: Platform.isWindows
                        ? () => PlatformBridge.instance.showInFolder(
                              item.savedPathOrUri,
                              widget.settings.downloadDir,
                            )
                        : () => PlatformBridge.instance.openFile(
                              item.savedPathOrUri,
                              mimeType: item.mimeType,
                            ),
                    icon: Icon(
                      Platform.isWindows
                          ? Icons.folder_open_rounded
                          : Icons.open_in_new_rounded,
                    ),
                  ),
                ),
              ),
            for (final t in state.receivedTexts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(t.body, style: textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await PlatformBridge.instance
                              .copyTextToClipboard(t.body);
                          if (mounted) {
                            setState(() => _copiedTextId = t.body);
                          }
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: Text(
                          _copiedTextId == t.body
                              ? strings.tr('copied')
                              : strings.tr('copy_text'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: widget.coordinator.dismissIncoming,
              child: Text(strings.tr('done')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(
    BuildContext context,
    AppStrings strings,
    String message,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: const ValueKey('receive_error'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.error_rounded, size: 42, color: scheme.onErrorContainer),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: widget.coordinator.dismissIncoming,
              child: Text(strings.tr('close')),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(label, style: textTheme.bodyMedium),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium?.tabular.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
