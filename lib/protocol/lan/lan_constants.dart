import 'dart:io';

class LanConstants {
  static const String multicastGroup = '224.0.0.167';
  static const int defaultPort = 53317;
  static const String protocolVersion = '2.1';
  static const Duration peerTtl = Duration(seconds: 22);

  static const String pathRegister = '/api/localsend/v2/register';
  static const String pathInfo = '/api/localsend/v2/info';
  static const String pathPrepareUpload = '/api/localsend/v2/prepare-upload';
  static const String pathUpload = '/api/localsend/v2/upload';
  static const String pathCancel = '/api/localsend/v2/cancel';

  static String get localDeviceType =>
      Platform.isAndroid ? 'mobile' : 'desktop';

  static String get localDeviceModel {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    return 'Windows';
  }
}
