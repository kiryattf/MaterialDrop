import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _FnVoid = Void Function();
typedef _DartVoid = void Function();

typedef _FnInit = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartInit = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FnSetWake = Void Function(Pointer<NativeFunction<_FnVoid>>);
typedef _DartSetWake = void Function(Pointer<NativeFunction<_FnVoid>>);

typedef _FnUpdateCfg = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DartUpdateCfg = int Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _FnPoll = Pointer<Utf8> Function();
typedef _DartPoll = Pointer<Utf8> Function();

typedef _FnFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

typedef _FnNoArgI32 = Int32 Function();
typedef _DartNoArgI32 = int Function();

typedef _FnI32Arg = Int32 Function(Int32);
typedef _DartI32Arg = int Function(int);

typedef _FnGetStr = Pointer<Utf8> Function();
typedef _DartGetStr = Pointer<Utf8> Function();

typedef _FnIrohSend = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartIrohSend = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FnRespond = Int32 Function(Pointer<Utf8>, Int32);
typedef _DartRespond = int Function(Pointer<Utf8>, int);

typedef _FnCancel = Int32 Function(Pointer<Utf8>);
typedef _DartCancel = int Function(Pointer<Utf8>);

typedef _FnRqsSend = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint16,
  Pointer<Utf8>,
);
typedef _DartRqsSend = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
);

/// Pure `dart:ffi` bridge to `materialdrop_rust` (`iroh` QUIC P2P + `rquickshare_core`).
class NativeBridge {
  NativeBridge._();
  static final NativeBridge instance = NativeBridge._();

  DynamicLibrary? _lib;
  bool _loaded = false;
  bool _initialized = false;

  _DartInit? _fnInit;
  _DartSetWake? _fnSetWake;
  _DartUpdateCfg? _fnUpdateCfg;
  _DartPoll? _fnPoll;
  _DartFree? _fnFree;
  _DartVoid? _fnShutdown;

  _DartNoArgI32? _fnIrohStart;
  _DartNoArgI32? _fnIrohStop;
  _DartGetStr? _fnIrohGetTicket;
  _DartGetStr? _fnIrohGetNodeId;
  _DartIrohSend? _fnIrohSend;
  _DartRespond? _fnIrohRespond;
  _DartCancel? _fnIrohCancel;

  _DartI32Arg? _fnRqsStart;
  _DartNoArgI32? _fnRqsStop;
  _DartRqsSend? _fnRqsSend;
  _DartRespond? _fnRqsRespond;
  _DartCancel? _fnRqsCancel;

  NativeCallable<_FnVoid>? _wakeCallable;
  final StreamController<Map<String, dynamic>> _eventsCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  Timer? _fallbackPollTimer;

  Stream<Map<String, dynamic>> get eventsStream => _eventsCtrl.stream;

  bool get isAvailable {
    _ensureLoaded();
    return _lib != null && _fnInit != null;
  }

  bool get isDesktopQuickShareAvailable =>
      (Platform.isWindows || Platform.isLinux) &&
      isAvailable &&
      _fnRqsStart != null;

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final lib = _tryOpenLibrary();
    if (lib == null) return;
    _lib = lib;

    try {
      _fnInit = lib.lookupFunction<_FnInit, _DartInit>('md_rust_init');
      _fnSetWake =
          lib.lookupFunction<_FnSetWake, _DartSetWake>('md_rust_set_wake_callback');
      _fnUpdateCfg =
          lib.lookupFunction<_FnUpdateCfg, _DartUpdateCfg>('md_rust_update_config');
      _fnPoll = lib.lookupFunction<_FnPoll, _DartPoll>('md_rust_poll_event');
      _fnFree = lib.lookupFunction<_FnFree, _DartFree>('md_rust_free_string');
      _fnShutdown =
          lib.lookupFunction<_FnVoid, _DartVoid>('md_rust_shutdown');

      _fnIrohStart =
          lib.lookupFunction<_FnNoArgI32, _DartNoArgI32>('md_iroh_start');
      _fnIrohStop =
          lib.lookupFunction<_FnNoArgI32, _DartNoArgI32>('md_iroh_stop');
      _fnIrohGetTicket =
          lib.lookupFunction<_FnGetStr, _DartGetStr>('md_iroh_get_ticket');
      _fnIrohGetNodeId =
          lib.lookupFunction<_FnGetStr, _DartGetStr>('md_iroh_get_node_id');
      _fnIrohSend =
          lib.lookupFunction<_FnIrohSend, _DartIrohSend>('md_iroh_send_files');
      _fnIrohRespond =
          lib.lookupFunction<_FnRespond, _DartRespond>('md_iroh_respond_offer');
      _fnIrohCancel =
          lib.lookupFunction<_FnCancel, _DartCancel>('md_iroh_cancel_transfer');

      _fnRqsStart =
          lib.lookupFunction<_FnI32Arg, _DartI32Arg>('md_rqs_start');
      _fnRqsStop =
          lib.lookupFunction<_FnNoArgI32, _DartNoArgI32>('md_rqs_stop');
      _fnRqsSend =
          lib.lookupFunction<_FnRqsSend, _DartRqsSend>('md_rqs_send_files');
      _fnRqsRespond =
          lib.lookupFunction<_FnRespond, _DartRespond>('md_rqs_respond_offer');
      _fnRqsCancel =
          lib.lookupFunction<_FnCancel, _DartCancel>('md_rqs_cancel_transfer');
    } catch (_) {
      _lib = null;
      _fnInit = null;
    }
  }

  DynamicLibrary? _tryOpenLibrary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (Platform.isWindows) ...[
        'materialdrop_rust.dll',
        p.join(exeDir, 'materialdrop_rust.dll'),
      ] else if (Platform.isLinux) ...[
        'libmaterialdrop_rust.so',
        p.join(exeDir, 'lib', 'libmaterialdrop_rust.so'),
        p.join(exeDir, 'libmaterialdrop_rust.so'),
      ] else if (Platform.isAndroid) ...[
        'libmaterialdrop_rust.so',
      ],
    ];
    for (final c in candidates) {
      try {
        return DynamicLibrary.open(c);
      } catch (_) {}
    }
    return null;
  }

  bool init({
    required String stateDir,
    required String deviceName,
    required String downloadDir,
  }) {
    if (!isAvailable) return false;
    final sPtr = stateDir.toNativeUtf8();
    final nPtr = deviceName.toNativeUtf8();
    final dPtr = downloadDir.toNativeUtf8();
    try {
      final rc = _fnInit!(sPtr, nPtr, dPtr);
      if (rc == 0) {
        if (!_initialized) {
          _initialized = true;
          _wakeCallable ??=
              NativeCallable<_FnVoid>.listener(_drainQueuedEvents);
          _fnSetWake?.call(_wakeCallable!.nativeFunction);
          _fallbackPollTimer ??= Timer.periodic(
            const Duration(milliseconds: 250),
            (_) => _drainQueuedEvents(),
          );
        }
        _drainQueuedEvents();
        return true;
      }
      return false;
    } finally {
      calloc.free(sPtr);
      calloc.free(nPtr);
      calloc.free(dPtr);
    }
  }

  void updateConfig({
    required String deviceName,
    required String downloadDir,
  }) {
    if (!_initialized || _fnUpdateCfg == null) return;
    final nPtr = deviceName.toNativeUtf8();
    final dPtr = downloadDir.toNativeUtf8();
    try {
      _fnUpdateCfg!(nPtr, dPtr);
    } finally {
      calloc.free(nPtr);
      calloc.free(dPtr);
    }
  }

  void _drainQueuedEvents() {
    if (_fnPoll == null || _fnFree == null) return;
    for (var i = 0; i < 64; i++) {
      final ptr = _fnPoll!();
      if (ptr == nullptr) break;
      try {
        final raw = ptr.toDartString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic> && !_eventsCtrl.isClosed) {
            _eventsCtrl.add(decoded);
          }
        }
      } catch (_) {
      } finally {
        _fnFree!(ptr);
      }
    }
  }

  bool startIroh() {
    if (!_initialized || _fnIrohStart == null) return false;
    final ok = _fnIrohStart!() == 0;
    _drainQueuedEvents();
    return ok;
  }

  void stopIroh() {
    if (!_initialized || _fnIrohStop == null) return;
    _fnIrohStop!();
  }

  String getIrohTicket() {
    if (!_initialized || _fnIrohGetTicket == null || _fnFree == null) {
      return '';
    }
    final ptr = _fnIrohGetTicket!();
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } finally {
      _fnFree!(ptr);
    }
  }

  String getIrohNodeId() {
    if (!_initialized || _fnIrohGetNodeId == null || _fnFree == null) {
      return '';
    }
    final ptr = _fnIrohGetNodeId!();
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } finally {
      _fnFree!(ptr);
    }
  }

  bool sendIrohFiles({
    required String transferId,
    required String ticketOrLink,
    required List<Map<String, dynamic>> files,
  }) {
    if (!_initialized || _fnIrohSend == null) return false;
    final tidPtr = transferId.toNativeUtf8();
    final tPtr = ticketOrLink.toNativeUtf8();
    final fPtr = jsonEncode(files).toNativeUtf8();
    try {
      return _fnIrohSend!(tidPtr, tPtr, fPtr) == 0;
    } finally {
      calloc.free(tidPtr);
      calloc.free(tPtr);
      calloc.free(fPtr);
    }
  }

  bool respondIrohOffer(String offerId, bool accept) {
    if (!_initialized || _fnIrohRespond == null) return false;
    final oidPtr = offerId.toNativeUtf8();
    try {
      return _fnIrohRespond!(oidPtr, accept ? 1 : 0) == 0;
    } finally {
      calloc.free(oidPtr);
    }
  }

  bool cancelIrohTransfer(String transferId) {
    if (!_initialized || _fnIrohCancel == null) return false;
    final tidPtr = transferId.toNativeUtf8();
    try {
      return _fnIrohCancel!(tidPtr) == 0;
    } finally {
      calloc.free(tidPtr);
    }
  }

  /// Starts desktop `rquickshare_core` engine; returns bound TCP port or `-1`.
  int startDesktopQuickShare({required bool visible}) {
    if (!_initialized || _fnRqsStart == null) return -1;
    final port = _fnRqsStart!(visible ? 1 : 0);
    _drainQueuedEvents();
    return port;
  }

  void stopDesktopQuickShare() {
    if (!_initialized || _fnRqsStop == null) return;
    _fnRqsStop!();
  }

  bool sendDesktopQuickShareFiles({
    required String transferId,
    required String ip,
    required int port,
    required List<Map<String, dynamic>> files,
  }) {
    if (!_initialized || _fnRqsSend == null) return false;
    final tidPtr = transferId.toNativeUtf8();
    final ipPtr = ip.toNativeUtf8();
    final fPtr = jsonEncode(files).toNativeUtf8();
    try {
      return _fnRqsSend!(tidPtr, ipPtr, port, fPtr) == 0;
    } finally {
      calloc.free(tidPtr);
      calloc.free(ipPtr);
      calloc.free(fPtr);
    }
  }

  bool respondDesktopQuickShareOffer(String offerId, bool accept) {
    if (!_initialized || _fnRqsRespond == null) return false;
    final oidPtr = offerId.toNativeUtf8();
    try {
      return _fnRqsRespond!(oidPtr, accept ? 1 : 0) == 0;
    } finally {
      calloc.free(oidPtr);
    }
  }

  bool cancelDesktopQuickShareTransfer(String transferId) {
    if (!_initialized || _fnRqsCancel == null) return false;
    final tidPtr = transferId.toNativeUtf8();
    try {
      return _fnRqsCancel!(tidPtr) == 0;
    } finally {
      calloc.free(tidPtr);
    }
  }

  void shutdown() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
    if (_initialized) {
      _fnShutdown?.call();
      _initialized = false;
    }
    _wakeCallable?.close();
    _wakeCallable = null;
  }
}
