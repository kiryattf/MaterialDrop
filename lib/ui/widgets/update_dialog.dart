import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/update_service.dart';

/// Material Design 3 dialog presenting changelog, SHA-256 verification status,
/// download progress and one-tap platform installation.
class UpdateSheetDialog extends StatelessWidget {
  final UpdateService updateService;
  final AppStrings strings;

  const UpdateSheetDialog({
    super.key,
    required this.updateService,
    required this.strings,
  });

  static Future<void> show(
    BuildContext context, {
    required UpdateService updateService,
    required AppStrings strings,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: !updateService.isBusy,
      builder: (_) => UpdateSheetDialog(
        updateService: updateService,
        strings: strings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updateService,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final release = updateService.latestRelease;
        final phase = updateService.phase;
        final hasUpdate = updateService.hasUpdate;

        return AlertDialog(
          icon: Icon(
            switch (phase) {
              UpdatePhase.readyToInstall => Icons.verified_rounded,
              UpdatePhase.error => Icons.error_outline_rounded,
              UpdatePhase.upToDate => Icons.check_circle_outline_rounded,
              _ => Icons.system_update_rounded,
            },
            color: phase == UpdatePhase.error ? scheme.error : scheme.primary,
            size: 28,
          ),
          title: Text(
            hasUpdate && release != null
                ? strings.tr(
                    'update_available_title',
                    {'version': release.tagName},
                  )
                : strings.tr('update_title'),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _VersionPill(
                        label: 'v${updateService.currentVersion}',
                        color: scheme.surfaceContainerHighest,
                        textColor: scheme.onSurfaceVariant,
                      ),
                      if (hasUpdate && release != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: scheme.primary,
                          ),
                        ),
                        _VersionPill(
                          label: release.tagName,
                          color: scheme.primaryContainer,
                          textColor: scheme.onPrimaryContainer,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (release != null && release.body.isNotEmpty) ...[
                    Text(
                      strings.tr('update_changelog'),
                      style: textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      ),
                      child: _MarkdownChangelogView(markdown: release.body),
                    ),
                    const SizedBox(height: 12),
                  ] else if (phase == UpdatePhase.upToDate) ...[
                    Text(
                      strings.tr('update_up_to_date'),
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (phase == UpdatePhase.downloading ||
                      phase == UpdatePhase.verifying ||
                      phase == UpdatePhase.installing) ...[
                    LinearProgressIndicator(
                      value: phase == UpdatePhase.downloading &&
                              updateService.totalBytes > 0
                          ? updateService.downloadProgress
                          : null,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      phase == UpdatePhase.verifying
                          ? strings.tr('update_verifying')
                          : phase == UpdatePhase.installing
                              ? strings.tr('update_installing')
                              : updateService.totalBytes > 0
                                  ? '${formatFileSize(updateService.downloadedBytes)} / ${formatFileSize(updateService.totalBytes)}'
                                  : strings.tr('update_downloading'),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (phase == UpdatePhase.readyToInstall &&
                      updateService.verifiedSha256 != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.verified_user_rounded,
                            size: 18,
                            color: scheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'SHA-256: ${updateService.verifiedSha256!.substring(0, 16)}…',
                              style: textTheme.labelMedium?.copyWith(
                                color: scheme.onSecondaryContainer,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (phase == UpdatePhase.error &&
                      updateService.errorCode != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _formatError(strings, updateService),
                      style: textTheme.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  updateService.isBusy ? null : () => Navigator.of(context).pop(),
              child: Text(strings.tr('cancel')),
            ),
            if (!hasUpdate)
              FilledButton.tonal(
                onPressed: updateService.isBusy
                    ? null
                    : () => unawaited(updateService.checkForUpdates(force: true)),
                child: Text(strings.tr('update_check_btn')),
              )
            else if (phase == UpdatePhase.readyToInstall)
              FilledButton.icon(
                onPressed: () => _handleInstall(context),
                icon: const Icon(Icons.install_desktop_rounded, size: 18),
                label: Text(strings.tr('update_install_btn')),
              )
            else
              FilledButton.icon(
                onPressed: updateService.isBusy
                    ? null
                    : () async {
                        final ok = await updateService.downloadAndVerify();
                        if (ok && context.mounted) {
                          await _handleInstall(context);
                        }
                      },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(strings.tr('update_download_btn')),
              ),
          ],
        );
      },
    );
  }

  Future<void> _handleInstall(BuildContext context) async {
    final result = await updateService.installDownloadedUpdate();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case UpdateInstallResult.needsPermission:
        messenger.showSnackBar(
          SnackBar(content: Text(strings.tr('update_grant_install_perm'))),
        );
      case UpdateInstallResult.savedToDownloads:
        messenger.showSnackBar(
          SnackBar(content: Text(strings.tr('update_saved_downloads'))),
        );
      case UpdateInstallResult.launched:
      case UpdateInstallResult.restarting:
      case UpdateInstallResult.failed:
        break;
    }
  }

  static String _formatError(AppStrings strings, UpdateService svc) {
    final base = strings.tr(svc.errorCode!);
    final detail = svc.errorDetail;
    if (detail == null || detail.isEmpty) return base;
    return '$base ($detail)';
  }
}

class _VersionPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _VersionPill({
    required this.label,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _MarkdownChangelogView extends StatelessWidget {
  final String markdown;
  const _MarkdownChangelogView({required this.markdown});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final lines = markdown.split('\n');
    final children = <Widget>[];

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      if (line.startsWith('### ')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              line.substring(4).trim(),
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        );
      } else if (line.startsWith('## ') || line.startsWith('# ')) {
        final offset = line.startsWith('## ') ? 3 : 2;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 3),
            child: Text(
              line.substring(offset).trim(),
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ),
        );
      } else if (line.trimLeft().startsWith('- ') ||
          line.trimLeft().startsWith('* ')) {
        final text = line.trimLeft().substring(2).trim();
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: textTheme.bodyMedium),
                Expanded(child: _renderInlineSpans(context, text)),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _renderInlineSpans(context, line.trim()),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _renderInlineSpans(BuildContext context, String text) {
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          height: 1.4,
        );
    final codeBg = Theme.of(context).colorScheme.surfaceContainerHighest;
    final spans = <InlineSpan>[];
    final tokenRe = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');
    var cursor = 0;

    for (final match in tokenRe.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: codeBg,
            ),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}
