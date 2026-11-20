/// Parser and builder for `materialdrop://iroh/<ticket>` deep links and raw Iroh endpoint tickets.
class IrohDeepLink {
  final String ticket;
  final String? deviceName;
  final String? nodeId;

  const IrohDeepLink({
    required this.ticket,
    this.deviceName,
    this.nodeId,
  });

  String get shortNodeId {
    if (nodeId != null && nodeId!.length >= 10) {
      return '${nodeId!.substring(0, 6)}...${nodeId!.substring(nodeId!.length - 4)}';
    }
    if (ticket.length >= 16) {
      return '${ticket.substring(0, 12)}...';
    }
    return ticket;
  }

  String toUriString() {
    final encodedTicket = Uri.encodeComponent(ticket);
    final query = <String, String>{};
    if (deviceName != null && deviceName!.trim().isNotEmpty) {
      query['name'] = deviceName!.trim();
    }
    if (nodeId != null && nodeId!.trim().isNotEmpty) {
      query['node'] = nodeId!.trim();
    }
    final qStr = query.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return qStr.isEmpty
        ? 'materialdrop://iroh/$encodedTicket'
        : 'materialdrop://iroh/$encodedTicket?$qStr';
  }

  /// Parses `materialdrop://iroh/<ticket>?name=...&node=...` or a bare `endpoint...` ticket string.
  static IrohDeepLink? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('materialdrop://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null) return null;
      String ticket = '';
      if (uri.host.toLowerCase() == 'iroh') {
        final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (seg.isNotEmpty) {
          ticket = Uri.decodeComponent(seg.first).trim();
        }
      } else if (uri.pathSegments.length >= 2 &&
          uri.pathSegments.first.toLowerCase() == 'iroh') {
        ticket = Uri.decodeComponent(uri.pathSegments[1]).trim();
      } else if (uri.host.toLowerCase().startsWith('endpoint')) {
        ticket = uri.host.trim();
      }
      if (!isLikelyTicket(ticket)) return null;
      final name = uri.queryParameters['name']?.trim();
      final node = uri.queryParameters['node']?.trim();
      return IrohDeepLink(
        ticket: ticket,
        deviceName: (name != null && name.isNotEmpty) ? name : null,
        nodeId: (node != null && node.isNotEmpty) ? node : null,
      );
    }

    if (isLikelyTicket(trimmed)) {
      return IrohDeepLink(ticket: trimmed);
    }
    return null;
  }

  static bool isLikelyTicket(String candidate) {
    final lower = candidate.trim().toLowerCase();
    return (lower.startsWith('endpoint') || lower.startsWith('node')) &&
        lower.length >= 24 &&
        !lower.contains(RegExp(r'\s'));
  }
}
