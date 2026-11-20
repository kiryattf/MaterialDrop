import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

enum AppSound {
  on('sounds/on.mp3'),
  off('sounds/off.mp3'),
  receiving('sounds/receving.mp3'),
  sending('sounds/sending.mp3'),
  searching('sounds/searching.mp3'),
  successful('sounds/succsesful.mp3'),
  failed('sounds/failed.mp3');

  final String assetPath;
  const AppSound(this.assetPath);
}

enum HapticKind { light, medium, heavy, selection }

class SoundService {
  static final SoundService instance = SoundService._();
  SoundService._();

  AudioPlayer? _player;
  bool enabled = true;
  DateTime _lastSearchSound = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastErrorSound = DateTime.fromMillisecondsSinceEpoch(0);

  AudioPlayer? _ensurePlayer() {
    if (_player != null) return _player;
    try {
      _player = AudioPlayer();
    } catch (_) {}
    return _player;
  }

  Future<void> play(AppSound sound, {double? volume}) async {
    if (!enabled) return;
    final now = DateTime.now();
    if (sound == AppSound.searching) {
      if (now.difference(_lastSearchSound).inMilliseconds < 1800) return;
      _lastSearchSound = now;
    } else if (sound == AppSound.failed) {
      if (now.difference(_lastErrorSound).inMilliseconds < 1500) return;
      _lastErrorSound = now;
    }

    try {
      final player = _ensurePlayer();
      if (player == null) return;
      await player.setVolume(
        volume ?? (sound == AppSound.searching ? 0.08 : 0.75),
      );
      await player.play(AssetSource(sound.assetPath));
    } catch (_) {}
  }

  Future<void> haptic(HapticKind kind) async {
    if (!enabled) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      switch (kind) {
        case HapticKind.light:
          await HapticFeedback.lightImpact();
        case HapticKind.medium:
          await HapticFeedback.mediumImpact();
        case HapticKind.heavy:
          await HapticFeedback.heavyImpact();
        case HapticKind.selection:
          await HapticFeedback.selectionClick();
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}

