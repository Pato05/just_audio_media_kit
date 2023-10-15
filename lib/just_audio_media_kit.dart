library just_audio_media_kit;

import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

class JustAudioMediaKit extends JustAudioPlatform {
  static MPVLogLevel mpvLogLevel = MPVLogLevel.error;
  static final _logger = Logger('MediaKitPlayer');
  final Map<String, MediaKitPlayer> players = {};

  static void registerWith() {
    JustAudioPlatform.instance = JustAudioMediaKit();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    MediaKit.ensureInitialized();

    if (players.containsKey(request.id)) {
      throw PlatformException(
          code: 'error', message: 'Player ${request.id} already exists!');
    }

    _logger.fine('instantiating new player ${request.id}');
    final player = MediaKitPlayer(request.id);
    await player.isReady;
    return players[request.id] = player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) {
    _logger.fine('disposing player ${request.id}');
    return players
        .remove(request.id)!
        .release()
        .then((_) => DisposePlayerResponse());
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    _logger.fine('disposing of all players...');
    await Future.wait(players.values.map((e) => e.release()));
    players.clear();
    return DisposeAllPlayersResponse();
  }
}
