/// `package:media_kit` bindings for `just_audio` to support Linux and Windows.
library;

import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/src/mediakit_player.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:universal_platform/universal_platform.dart';

class JustAudioMediaKit extends JustAudioPlatform {
  JustAudioMediaKit._();

  /// The internal MPV player's logLevel
  static MPVLogLevel mpvLogLevel = MPVLogLevel.error;

  /// Sets the demuxer's cache size (in bytes)
  static int bufferSize = 32 * 1024 * 1024;

  /// Sets the name of the underlying window & process for native backend. This is visible inside the Windows' volume mixer.
  static String title = 'JustAudioMediaKit';

  /// Sets the list of allowed protocols for native backend.
  static List<String> protocolWhitelist = const [
    'udp',
    'rtp',
    'tcp',
    'tls',
    'data',
    'file',
    'http',
    'https',
    'crypto',
  ];

  /// Enables or disables pitch shift control for native backend (with this set to false, [setPitch] won't work).
  ///
  /// This uses `scaletempo` under the hood & disables `audio-pitch-correction`.
  static bool pitch = true;

  /// Enables gapless playback via the [`--prefetch-playlist`](https://mpv.io/manual/stable/#options-prefetch-playlist) in libmpv
  ///
  /// This is highly experimental. Use at your own risk.
  ///
  /// Check [mpv's docs](https://mpv.io/manual/stable/#options-prefetch-playlist) and
  /// [the related issue](https://github.com/Pato05/just_audio_media_kit/issues/11) for more information
  static bool prefetchPlaylist = false;

  /// Maximum mpv `volume` value, expressed as a multiplier (1.0 = 100% =
  /// mpv default; 1.3 = 130% = mpv's own default cap; 2.0 = 200% =
  /// typical "boost" target). Set BEFORE [ensureInitialized]. Applied to
  /// every player created after the assignment via the [Player]
  /// constructor's `setProperty('volume-max', ...)` call.
  ///
  /// Default 1.3 matches mpv's documented default so unmodified
  /// consumers see no behavior change.
  static double volumeMax = 1.3;

  /// Optional mpv `audio-filters` chain applied to every player at
  /// construction time. Format: see mpv's audio-filters docs (lavfi
  /// passthrough is common, e.g. `'lavfi=[acompressor=...]'`).
  ///
  /// Set BEFORE [ensureInitialized] to apply at startup, OR call
  /// [setMpvProperty]`('audio-filters', filters)` at runtime to swap
  /// on an existing player. Null leaves the default chain (no filters).
  static String? audioFilters;

  static final _logger = Logger('JustAudioMediaKit');
  final _players = HashMap<String, MediaKitPlayer>();

  /// Players that are disposing (player id -> future that completes when the player is disposed)
  final _disposingPlayers = HashMap<String, Future<void>>();

  /// Initializes the plugin if the platform we're running on is marked
  /// as true, otherwise it will leave everything unchanged.
  ///
  /// Can also be safely called from Web, even though it'll have no effect
  static void ensureInitialized({
    bool linux = true,
    bool windows = true,
    bool android = false,
    bool iOS = false,
    bool macOS = false,

    /// The path to the libmpv dynamic library.
    /// The name of the library is generally `libmpv.so` on GNU/Linux and `libmpv-2.dll` on Windows.
    String? libmpv,
  }) {
    if ((UniversalPlatform.isLinux && linux) ||
        (UniversalPlatform.isWindows && windows) ||
        (UniversalPlatform.isAndroid && android) ||
        (UniversalPlatform.isIOS && iOS) ||
        (UniversalPlatform.isMacOS && macOS)) {
      registerWith();
      MediaKit.ensureInitialized(libmpv: libmpv);
    }
  }

  /// Registers the plugin with [JustAudioPlatform]
  static void registerWith() {
    JustAudioPlatform.instance = JustAudioMediaKit._();
  }

  /// Set an mpv property on every active [MediaKitPlayer]. Useful for
  /// runtime swaps of properties like `audio-filters` that are not in the
  /// static config block (or that need to change after init).
  ///
  /// Iterates the internal player map and calls each player's
  /// [MediaKitPlayer.setMpvProperty]. No-op if no players are active or if
  /// [JustAudioPlatform.instance] has not been registered as
  /// [JustAudioMediaKit] (e.g., in a unit test environment without a
  /// platform init).
  ///
  /// `just_audio.AudioPlayer._id` is private with no public getter,
  /// which is why this is an iteration over all players rather than a
  /// per-player lookup by ID. For single-player consumers (the typical
  /// case), this is correct. For multi-player consumers, it applies the
  /// same property to every player — which is the right semantic for
  /// `audio-filters` (the chain applies to whatever player is rendering)
  /// and for `volume-max` (a per-player ceiling that should usually be
  /// uniform across an app).
  static Future<void> setMpvProperty(String key, dynamic value) async {
    final instance = JustAudioPlatform.instance;
    if (instance is! JustAudioMediaKit) return;
    for (final player in instance._players.values) {
      await player.setMpvProperty(key, value);
    }
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (_players.containsKey(request.id)) {
      throw PlatformException(
          code: 'error', message: 'Player ${request.id} already exists!');
    }

    _logger.fine('instantiating new player ${request.id}');
    final player = MediaKitPlayer(request.id);
    _players[request.id] = player;
    await player.ready();
    _logger.fine('player ready! (players: $_players)');
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    _logger.fine('disposing player ${request.id}');

    // temporary workaround because disposePlayer is called more than once
    if (_disposingPlayers.containsKey(request.id)) {
      _logger.fine('disposePlayer() called more than once!');
      await _disposingPlayers[request.id]!;
      return DisposePlayerResponse();
    }

    if (!_players.containsKey(request.id)) {
      throw PlatformException(
          code: 'error', message: 'Player ${request.id} doesn\'t exist.');
    }

    final future = _players[request.id]!.release();
    _players.remove(request.id);
    _disposingPlayers[request.id] = future;
    await future;
    _disposingPlayers.remove(request.id);

    _logger.fine('player ${request.id} disposed!');
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    _logger.fine('disposing of all players...');
    if (_players.isNotEmpty) {
      await Future.wait(_players.values.map((e) => e.release()));
      _players.clear();
    }
    return DisposeAllPlayersResponse();
  }
}
