import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/engine/transport_models.dart';
import 'package:material_drop/protocol/engine/transport_router.dart';
import 'package:material_drop/protocol/ffi/native_bridge.dart';
import 'package:material_drop/protocol/iroh/internet_p2p_transport.dart';
import 'package:material_drop/protocol/iroh/iroh_link.dart';
import 'package:material_drop/services/launch_config.dart';

void main() {
  group('Stage 4 Iroh DeepLink & P2P Routing Tests', () {
    test('IrohDeepLink encodes and parses materialdrop://iroh links and raw tickets', () {
      const sampleTicket =
          'endpointaaabbbcccdddeeefffggg111222333444555666777888';
      const linkObj = IrohDeepLink(
        ticket: sampleTicket,
        deviceName: 'Kirya Desktop',
        nodeId: 'node_0123456789abcdef',
      );
      final uri = linkObj.toUriString();
      expect(uri, startsWith('materialdrop://iroh/'));
      expect(uri, contains('Kirya%20Desktop'));

      final parsed = IrohDeepLink.parse(uri);
      expect(parsed, isNotNull);
      expect(parsed!.ticket, sampleTicket);
      expect(parsed.deviceName, 'Kirya Desktop');
      expect(parsed.nodeId, 'node_0123456789abcdef');

      final rawParsed = IrohDeepLink.parse(sampleTicket);
      expect(rawParsed, isNotNull);
      expect(rawParsed!.ticket, sampleTicket);

      expect(IrohDeepLink.parse('https://example.com'), isNull);
      expect(IrohDeepLink.parse('short'), isNull);
    });

    test('LaunchConfig parses materialdrop://iroh deep link alongside flags', () {
      const url = 'materialdrop://iroh/endpointaaaaaaaaaaaaaaaaaaaaaaaa?name=Remote';
      final cfg = LaunchConfig.fromArgs([url, '--tray']);
      expect(cfg.initialDeepLink, url);
      expect(cfg.startInTray, isTrue);
      expect(cfg.isMultiInstance, isFalse);
    });

    test('InternetP2PTransport registers ticket peers cleanly in headless mode', () async {
      final t = InternetP2PTransport(
        deviceNameFn: () => 'TestHost',
        downloadDirFn: () => '.',
        isTrustedFn: (_, _) => false,
        autoAcceptAllFn: () => false,
        autoAcceptTrustedFn: () => false,
      );
      expect(t.id, 'internet_p2p');
      expect(t.kind, TransportKind.internetP2p);
      expect(t.priority, 50);

      final futurePeers = t.devicesStream.first;
      final peer = t.addPeerFromLinkOrTicket(
        'materialdrop://iroh/endpointzzzzzzzzzzzzzzzzzzzzzzzz?name=Friend%20Phone&node=nodeabc12345',
      );
      expect(peer, isNotNull);
      expect(peer!.protocol, TransferProtocol.internetP2p);
      expect(peer.name, 'Friend Phone');
      expect(peer.irohTicket, 'endpointzzzzzzzzzzzzzzzzzzzzzzzz');

      final emitted = await futurePeers;
      expect(emitted.length, 1);
      expect(emitted.first.id, 'iroh:nodeabc12345');

      // NativeBridge fails cleanly if shared library isn't compiled locally.
      NativeBridge.instance.init(
        stateDir: '.',
        deviceName: 'TestHost',
        downloadDir: '.',
      );
      await t.dispose();
    });

    test('TransportRouter routes InternetP2P peers alongside LAN/Proximity peers', () async {
      final iroh = InternetP2PTransport(
        deviceNameFn: () => 'Local',
        downloadDirFn: () => '.',
        isTrustedFn: (_, _) => false,
        autoAcceptAllFn: () => false,
        autoAcceptTrustedFn: () => false,
      );
      final router = TransportRouter(
        channels: [iroh],
        isSelfFn: (_) => false,
        isTrustedFn: (_) => false,
      );

      final firstPeer = router.peersStream.firstWhere((p) => p.isNotEmpty);
      iroh.addPeerFromLinkOrTicket(
        'materialdrop://iroh/endpointxxxxxxxxxxxxxxxxxxxxxxxx?name=RemoteBox&node=noderemote1',
      );
      final peers = await firstPeer;
      expect(peers.length, 1);
      expect(peers.first.primaryEndpoint.kind, TransportKind.internetP2p);
      expect(peers.first.primaryEndpoint.irohTicket,
          'endpointxxxxxxxxxxxxxxxxxxxxxxxx');

      await router.dispose();
    });
  });
}
