/// Parsed desktop/CLI launch configuration for multi-instance testing and tray startup.
class LaunchConfig {
  final int? port;
  final String? bindAddress;
  final String? deviceName;
  final bool startInTray;

  const LaunchConfig({
    this.port,
    this.bindAddress,
    this.deviceName,
    this.startInTray = false,
  });

  bool get isMultiInstance =>
      port != null ||
      (bindAddress != null && bindAddress!.isNotEmpty) ||
      (deviceName != null && deviceName!.isNotEmpty);

  /// Stable key prefix isolating preferences/history when running multiple
  /// local instances side-by-side (`--name PC-2 --bind 127.0.0.2 --port 45875`).
  String get profilePrefix {
    if (!isMultiInstance) return '';
    final raw = '${deviceName ?? ''}_${bindAddress ?? ''}_${port ?? ''}';
    final clean = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    return 'inst_${clean}_';
  }

  factory LaunchConfig.fromArgs(List<String> args) {
    int? port;
    String? bindAddress;
    String? deviceName;
    var startInTray = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--tray' || arg == '--background' || arg == '--minimized') {
        startInTray = true;
      } else if (arg.startsWith('--port=')) {
        final v = int.tryParse(arg.substring('--port='.length).trim());
        if (v != null && v > 0 && v <= 65535) port = v;
      } else if (arg == '--port' && i + 1 < args.length) {
        final v = int.tryParse(args[++i].trim());
        if (v != null && v > 0 && v <= 65535) port = v;
      } else if (arg.startsWith('--bind=')) {
        final v = arg.substring('--bind='.length).trim();
        if (v.isNotEmpty) bindAddress = v;
      } else if (arg == '--bind' && i + 1 < args.length) {
        final v = args[++i].trim();
        if (v.isNotEmpty) bindAddress = v;
      } else if (arg.startsWith('--name=')) {
        final v = arg.substring('--name='.length).trim();
        if (v.isNotEmpty) deviceName = v;
      } else if (arg == '--name' && i + 1 < args.length) {
        final v = args[++i].trim();
        if (v.isNotEmpty) deviceName = v;
      }
    }

    return LaunchConfig(
      port: port,
      bindAddress: bindAddress,
      deviceName: deviceName,
      startInTray: startInTray,
    );
  }
}
