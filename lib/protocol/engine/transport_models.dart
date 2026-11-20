import '../../models/models.dart';

enum TransportKind { direct, lan, quickShare, tapProximity, internetP2p }

/// Concrete reachable transport route for a discovered peer.
class TransportEndpoint {
  final String channelId;
  final TransportKind kind;
  final int priority;
  final TransferProtocol protocol;
  final String ip;
  final int port;
  final bool isUsb;
  final bool useHttps;
  final String? tlsFingerprint;
  final String? endpointId;
  final String? instanceId;

  const TransportEndpoint({
    required this.channelId,
    required this.kind,
    required this.priority,
    required this.protocol,
    required this.ip,
    required this.port,
    required this.isUsb,
    this.useHttps = false,
    this.tlsFingerprint,
    this.endpointId,
    this.instanceId,
  });

  NearbyDevice toNearbyDevice({
    required String peerKey,
    required String name,
    required DeviceKind deviceKind,
    required DateTime lastSeen,
  }) {
    return NearbyDevice(
      id: peerKey,
      name: name,
      ip: ip,
      port: port,
      kind: deviceKind,
      protocol: protocol,
      isUsb: isUsb,
      lastSeen: lastSeen,
      endpointId: endpointId,
      instanceId: instanceId,
      channelId: channelId,
      tlsFingerprint: tlsFingerprint,
      useHttps: useHttps,
    );
  }
}

/// Logical remote peer aggregating one or more available transport channels.
class DiscoveredPeer {
  final String peerKey;
  final String name;
  final DeviceKind deviceKind;
  final Map<String, TransportEndpoint> endpoints;
  final DateTime lastSeen;

  const DiscoveredPeer({
    required this.peerKey,
    required this.name,
    required this.deviceKind,
    required this.endpoints,
    required this.lastSeen,
  });

  List<TransportEndpoint> get orderedEndpoints {
    final list = endpoints.values.toList();
    list.sort((a, b) {
      if (a.isUsb != b.isUsb) return a.isUsb ? -1 : 1;
      return a.priority.compareTo(b.priority);
    });
    return list;
  }

  TransportEndpoint get primaryEndpoint => orderedEndpoints.first;

  NearbyDevice toNearbyDevice() {
    return primaryEndpoint.toNearbyDevice(
      peerKey: peerKey,
      name: name,
      deviceKind: deviceKind,
      lastSeen: lastSeen,
    );
  }
}

sealed class TransportEvent {
  final String channelId;
  const TransportEvent(this.channelId);
}

final class TransportIncomingOffer extends TransportEvent {
  final IncomingOffer offer;
  const TransportIncomingOffer(super.channelId, this.offer);
}

final class TransportIncomingProgress extends TransportEvent {
  final IncomingOffer offer;
  final String fileName;
  final int bytesReceived;
  final int totalBytes;
  final double speedBps;

  const TransportIncomingProgress(
    super.channelId,
    this.offer,
    this.fileName,
    this.bytesReceived,
    this.totalBytes,
    this.speedBps,
  );
}

final class TransportIncomingCompleted extends TransportEvent {
  final IncomingOffer offer;
  final List<IncomingTransferItem> savedItems;
  final List<IncomingTextItem> receivedTexts;

  const TransportIncomingCompleted(
    super.channelId,
    this.offer,
    this.savedItems,
    this.receivedTexts,
  );
}

final class TransportIncomingCanceled extends TransportEvent {
  const TransportIncomingCanceled(super.channelId);
}

final class TransportIncomingError extends TransportEvent {
  final String message;
  const TransportIncomingError(super.channelId, this.message);
}

final class TransportOutgoingConnecting extends TransportEvent {
  final String deviceName;
  final TransferProtocol protocol;

  const TransportOutgoingConnecting(
    super.channelId,
    this.deviceName,
    this.protocol,
  );
}

final class TransportOutgoingPinReady extends TransportEvent {
  final String deviceName;
  final String pin;

  const TransportOutgoingPinReady(super.channelId, this.deviceName, this.pin);
}

final class TransportOutgoingProgress extends TransportEvent {
  final String deviceName;
  final String fileName;
  final int bytesSent;
  final int totalBytes;
  final double speedBps;
  final TransferProtocol protocol;
  final String? pin;

  const TransportOutgoingProgress(
    super.channelId,
    this.deviceName,
    this.fileName,
    this.bytesSent,
    this.totalBytes,
    this.speedBps,
    this.protocol, {
    this.pin,
  });
}

final class TransportOutgoingCompleted extends TransportEvent {
  final String deviceName;
  final String displayTitle;
  final int filesCount;
  final TransferProtocol protocol;
  final List<StagedFile> files;

  const TransportOutgoingCompleted(
    super.channelId,
    this.deviceName,
    this.displayTitle,
    this.filesCount,
    this.protocol,
    this.files,
  );
}

final class TransportOutgoingCanceled extends TransportEvent {
  const TransportOutgoingCanceled(super.channelId);
}

final class TransportOutgoingError extends TransportEvent {
  final String message;
  const TransportOutgoingError(super.channelId, this.message);
}
