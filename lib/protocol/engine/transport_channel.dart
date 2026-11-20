import '../../models/models.dart';
import 'transport_models.dart';

/// Unified interface for any peer discovery + file transport backend.
abstract interface class TransportChannel {
  String get id;
  TransportKind get kind;
  int get priority;
  bool get isAvailable;
  int get boundPort;

  Stream<List<NearbyDevice>> get devicesStream;
  Stream<TransportEvent> get eventsStream;

  Future<void> start({int? explicitPort, String? bindAddress});
  Future<void> stop();
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<void> refreshDiscovery();

  Future<void> sendOffer(
    NearbyDevice device,
    List<StagedFile> files, {
    required String localDeviceName,
  });

  Future<void> acceptOffer(String offerId);
  Future<void> declineOffer(String offerId);
  Future<void> cancelTransfer({String? offerId});

  Future<void> updateConfig({String? deviceName, String? downloadDir});
  Future<void> dispose();
}
