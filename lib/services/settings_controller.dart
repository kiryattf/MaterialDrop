import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import 'platform_bridge.dart';

class SettingsController extends ChangeNotifier {
  static const _kDeviceName = 'md_device_name';
  static const _kThemeStyle = 'md_theme_style';
  static const _kDynamicColor = 'md_dynamic_color';
  static const _kLanguage = 'md_language';
  static const _kAutoAcceptTrusted = 'md_auto_accept_trusted';
  static const _kAutoAcceptAll = 'md_auto_accept_all';
  static const _kQuickShareEnabled = 'md_quickshare_enabled';
  static const _kSoundsEnabled = 'md_sounds_enabled';
  static const _kClipboardSync = 'md_clipboard_sync';
  static const _kDownloadDir = 'md_download_dir';
  static const _kTrustedDevices = 'md_trusted_devices';
  static const _kHistory = 'md_history';

  SharedPreferences? _prefs;

  String _deviceName = 'MaterialDrop Device';
  String _manufacturer = '';
  AppThemeStyle _themeStyle = AppThemeStyle.system;
  bool _useDynamicColor = true;
  String _languageCode = 'ru';
  bool _autoAcceptTrusted = true;
  bool _autoAcceptAll = false;
  bool _quickShareEnabled = true;
  bool _soundsEnabled = true;
  bool _clipboardSync = true;
  String _downloadDir = '';
  Set<String> _trustedDevices = {};
  List<HistoryEntry> _history = [];

  String get deviceName => _deviceName;
  String get manufacturer => _manufacturer;
  AppThemeStyle get themeStyle => _themeStyle;
  bool get useDynamicColor => _useDynamicColor;
  String get languageCode => _languageCode;
  AppStrings get strings => AppStrings(_languageCode);
  bool get autoAcceptTrusted => _autoAcceptTrusted;
  bool get autoAcceptAll => _autoAcceptAll;
  bool get quickShareEnabled => _quickShareEnabled;
  bool get soundsEnabled => _soundsEnabled;
  bool get clipboardSync => _clipboardSync;
  String get downloadDir => _downloadDir;
  Set<String> get trustedDevices => Set.unmodifiable(_trustedDevices);
  List<HistoryEntry> get history => List.unmodifiable(_history);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final hw = await PlatformBridge.instance.getDeviceInfo();
    _manufacturer = hw.manufacturer;

    _deviceName = _prefs?.getString(_kDeviceName) ?? hw.model;
    final themeStr = _prefs?.getString(_kThemeStyle);
    _themeStyle = AppThemeStyle.values.firstWhere(
      (e) => e.name == themeStr,
      orElse: () => AppThemeStyle.system,
    );
    _useDynamicColor = _prefs?.getBool(_kDynamicColor) ?? true;

    final systemLocale = PlatformDispatcher.instance.locale.languageCode;
    final defaultLang = AppStrings.supportedLanguages.containsKey(systemLocale)
        ? systemLocale
        : 'ru';
    _languageCode = _prefs?.getString(_kLanguage) ?? defaultLang;

    _autoAcceptTrusted = _prefs?.getBool(_kAutoAcceptTrusted) ?? true;
    _autoAcceptAll = _prefs?.getBool(_kAutoAcceptAll) ?? false;
    _quickShareEnabled = _prefs?.getBool(_kQuickShareEnabled) ?? true;
    _soundsEnabled = _prefs?.getBool(_kSoundsEnabled) ?? true;
    _clipboardSync = _prefs?.getBool(_kClipboardSync) ?? true;

    _downloadDir = _prefs?.getString(_kDownloadDir) ?? '';
    if (_downloadDir.isEmpty) {
      _downloadDir = await PlatformBridge.instance.getDefaultDownloadDir();
      await _prefs?.setString(_kDownloadDir, _downloadDir);
    }

    final trustedList = _prefs?.getStringList(_kTrustedDevices) ?? const [];
    _trustedDevices = trustedList.toSet();

    final histRaw = _prefs?.getString(_kHistory);
    if (histRaw != null && histRaw.isNotEmpty) {
      _history = HistoryEntry.decodeList(histRaw);
    }

    notifyListeners();
  }

  bool isTrusted(String idOrName, [String? altId]) {
    if (_trustedDevices.contains(idOrName)) return true;
    if (altId != null && _trustedDevices.contains(altId)) return true;
    return false;
  }

  bool isDeviceTrusted(NearbyDevice device) {
    return _trustedDevices.contains(device.name) ||
        _trustedDevices.contains(device.id) ||
        _trustedDevices.contains(device.ip);
  }

  Future<void> setTrusted(String identifier, bool trusted,
      {String? extraId}) async {
    final next = Set<String>.from(_trustedDevices);
    if (trusted) {
      if (identifier.isNotEmpty) next.add(identifier);
      if (extraId != null && extraId.isNotEmpty) next.add(extraId);
    } else {
      next.remove(identifier);
      if (extraId != null) next.remove(extraId);
    }
    _trustedDevices = next;
    await _prefs?.setStringList(_kTrustedDevices, next.toList());
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _deviceName = trimmed;
    await _prefs?.setString(_kDeviceName, trimmed);
    notifyListeners();
  }

  Future<void> setThemeStyle(AppThemeStyle style) async {
    _themeStyle = style;
    await _prefs?.setString(_kThemeStyle, style.name);
    notifyListeners();
  }

  Future<void> setUseDynamicColor(bool val) async {
    _useDynamicColor = val;
    await _prefs?.setBool(_kDynamicColor, val);
    notifyListeners();
  }

  Future<void> setLanguageCode(String code) async {
    if (!AppStrings.supportedLanguages.containsKey(code)) return;
    _languageCode = code;
    await _prefs?.setString(_kLanguage, code);
    notifyListeners();
  }

  Future<void> setAutoAcceptTrusted(bool val) async {
    _autoAcceptTrusted = val;
    await _prefs?.setBool(_kAutoAcceptTrusted, val);
    notifyListeners();
  }

  Future<void> setAutoAcceptAll(bool val) async {
    _autoAcceptAll = val;
    await _prefs?.setBool(_kAutoAcceptAll, val);
    notifyListeners();
  }

  Future<void> setQuickShareEnabled(bool val) async {
    _quickShareEnabled = val;
    await _prefs?.setBool(_kQuickShareEnabled, val);
    notifyListeners();
  }

  Future<void> setSoundsEnabled(bool val) async {
    _soundsEnabled = val;
    await _prefs?.setBool(_kSoundsEnabled, val);
    notifyListeners();
  }

  Future<void> setClipboardSync(bool val) async {
    _clipboardSync = val;
    await _prefs?.setBool(_kClipboardSync, val);
    notifyListeners();
  }

  Future<void> setDownloadDir(String dir) async {
    _downloadDir = dir;
    await _prefs?.setString(_kDownloadDir, dir);
    notifyListeners();
  }

  Future<void> addHistoryEntry(HistoryEntry entry) async {
    final next = [entry, ..._history];
    if (next.length > 100) {
      next.removeRange(100, next.length);
    }
    _history = next;
    await _prefs?.setString(_kHistory, HistoryEntry.encodeList(next));
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history = [];
    await _prefs?.remove(_kHistory);
    notifyListeners();
  }
}

