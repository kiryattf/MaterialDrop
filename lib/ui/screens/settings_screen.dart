import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/platform_bridge.dart';
import '../../services/settings_controller.dart';

class SettingsScreen extends StatelessWidget {
  final SettingsController settings;
  final TransferCoordinator coordinator;

  const SettingsScreen({
    super.key,
    required this.settings,
    required this.coordinator,
  });

  @override
  Widget build(BuildContext context) {
    final strings = settings.strings;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final trusted = settings.trustedDevices.toList();

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(
                  strings.tr('settings_title'),
                  style: textTheme.headlineMedium,
                ),
              ),

              // Device section
              _SectionHeader(strings.tr('settings_device_title')),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.badge_rounded, color: scheme.primary),
                      title: Text(strings.tr('device_name_label')),
                      subtitle: Text(settings.deviceName),
                      trailing: const Icon(Icons.edit_rounded, size: 18),
                      onTap: () => _showRenameDialog(context, strings),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading:
                          Icon(Icons.memory_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_manufacturer')),
                      trailing: Text(
                        _formatPlatformLabel(settings.manufacturer),
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Appearance section
              _SectionHeader(strings.tr('settings_appearance_title')),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        strings.tr('settings_theme_label'),
                        style: textTheme.titleSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<AppThemeStyle>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: AppThemeStyle.system,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  strings.tr('theme_system'),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: AppThemeStyle.light,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  strings.tr('theme_light'),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: AppThemeStyle.dark,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  strings.tr('theme_dark'),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: AppThemeStyle.oled,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  strings.tr('theme_oled'),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ],
                          selected: {settings.themeStyle},
                          onSelectionChanged: (sel) =>
                              settings.setThemeStyle(sel.first),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      secondary: Icon(
                        Icons.palette_rounded,
                        color: scheme.primary,
                      ),
                      title: Text(strings.tr('settings_dynamic_color')),
                      subtitle: Text(
                        Platform.isAndroid
                            ? strings.tr('settings_dynamic_color_desc_android')
                            : strings.tr('settings_dynamic_color_desc_windows'),
                      ),
                      value: settings.useDynamicColor,
                      onChanged: settings.setUseDynamicColor,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading:
                          Icon(Icons.translate_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_language')),
                      trailing: DropdownButton<String>(
                        value: settings.languageCode,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final entry
                              in AppStrings.supportedLanguages.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: (val) {
                          if (val != null) settings.setLanguageCode(val);
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Trusted devices
              _SectionHeader(strings.tr('settings_trusted_title')),
              Card(
                child: trusted.isEmpty
                    ? ListTile(
                        leading: Icon(
                          Icons.devices_other_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          strings.tr('settings_no_trusted'),
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < trusted.length; i++) ...[
                            if (i > 0)
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                            ListTile(
                              leading: Icon(
                                Icons.verified_user_rounded,
                                color: scheme.primary,
                              ),
                              title: Text(trusted[i]),
                              trailing: IconButton(
                                tooltip: strings.tr('settings_remove_trusted'),
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: scheme.error,
                                ),
                                onPressed: () =>
                                    settings.setTrusted(trusted[i], false),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),

              // Transfer & protocols
              _SectionHeader(strings.tr('settings_transfer_title')),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: Icon(
                        Icons.verified_rounded,
                        color: scheme.primary,
                      ),
                      title: Text(strings.tr('settings_auto_accept')),
                      subtitle: Text(strings.tr('settings_auto_accept_desc')),
                      value: settings.autoAcceptTrusted,
                      onChanged: settings.setAutoAcceptTrusted,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary:
                          Icon(Icons.bolt_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_auto_accept_all')),
                      subtitle:
                          Text(strings.tr('settings_auto_accept_all_desc')),
                      value: settings.autoAcceptAll,
                      onChanged: settings.setAutoAcceptAll,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary:
                          Icon(Icons.share_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_quickshare')),
                      subtitle: Text(strings.tr('settings_quickshare_desc')),
                      value: settings.quickShareEnabled,
                      onChanged: (v) async {
                        await settings.setQuickShareEnabled(v);
                        await coordinator.onSettingsUpdated();
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary:
                          Icon(Icons.content_paste_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_clipboard')),
                      subtitle: Text(
                        Platform.isAndroid
                            ? strings.tr('settings_clipboard_desc_android')
                            : strings.tr('settings_clipboard_desc'),
                      ),
                      value: settings.clipboardSync,
                      onChanged: settings.setClipboardSync,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary:
                          Icon(Icons.volume_up_rounded, color: scheme.primary),
                      title: Text(strings.tr('settings_sounds')),
                      subtitle: Text(strings.tr('settings_sounds_desc')),
                      value: settings.soundsEnabled,
                      onChanged: (v) async {
                        await settings.setSoundsEnabled(v);
                        await coordinator.onSettingsUpdated();
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(
                        Icons.folder_open_rounded,
                        color: scheme.primary,
                      ),
                      title: Text(strings.tr('settings_save_folder')),
                      subtitle: Text(
                        Platform.isAndroid
                            ? strings.tr('settings_save_folder_android')
                            : settings.downloadDir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        Platform.isWindows
                            ? Icons.chevron_right_rounded
                            : Icons.open_in_new_rounded,
                        size: 18,
                      ),
                      onTap: Platform.isWindows
                          ? () async {
                              final picked =
                                  await FilePicker.platform.getDirectoryPath();
                              if (picked != null && picked.isNotEmpty) {
                                await settings.setDownloadDir(picked);
                                await coordinator.onSettingsUpdated();
                              }
                            }
                          : () => PlatformBridge.instance.showInFolder(
                                '',
                                settings.downloadDir,
                              ),
                    ),
                  ],
                ),
              ),

              // Network note (IP/ports live on the Receive tab)
              _SectionHeader(strings.tr('settings_network_title')),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          strings.tr('settings_guest_warning'),
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // About
              _SectionHeader(strings.tr('settings_about_title')),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.near_me_rounded,
                    color: scheme.primary,
                  ),
                  title: const Text('MaterialDrop'),
                  subtitle: Text(strings.tr('settings_about_desc')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatPlatformLabel(String rawManufacturer) {
    final trimmed = rawManufacturer.trim();
    final capitalized = trimmed.isEmpty
        ? (Platform.isAndroid ? 'Android' : 'Windows')
        : '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
    if (Platform.isAndroid && capitalized.toLowerCase() != 'android') {
      return '$capitalized • Android';
    }
    return capitalized;
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    AppStrings strings,
  ) async {
    final ctrl = TextEditingController(text: settings.deviceName);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.tr('settings_rename_device')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: strings.tr('device_name_label'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(strings.tr('save')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (updated != null && updated.trim().isNotEmpty) {
      await settings.setDeviceName(updated);
      await coordinator.onSettingsUpdated();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

