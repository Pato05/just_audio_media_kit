library just_audio_media_kit;

import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player].
class MediaKitPlayer extends AudioPlayerPlatform {
  static final _logger = Logger('MediaKitPlayer');

  /// `package:media_kit`'s [Player].
  late final Player _player;

  /// The list of [StreamSubscription]'s that must be disposed on [release] call.
  late final List<StreamSubscription> _streamSubscriptions;

  /// A [Completer] that completes when the player is ready to play.
  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready to play.
  Future<void> ready() => _readyCompleter.future;

  /// The [StreamController] for [PlaybackEventMessage].
  final _eventController = StreamController<PlaybackEventMessage>.broadcast();

  /// The [StreamController] for [PlayerDataMessage].
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  /// The current processing state of the player.
  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;

  /// The current buffered position of the player.
  Duration _bufferedPosition = Duration.zero;

  /// The current position of the player.
  Duration _position = Duration.zero;

  /// The current duration of the player.
  Duration _duration = Duration.zero;

  /// List of [Player]'s [Media] objects, that are fed one by one to the [_player].
  List<Media>? _playlist;

  /// The shuffled order of the [_playlist].
  List<int> _shuffleOrder = [];

  /// Whether the player is currently shuffling.
  bool _isShuffling = false;

  /// "Actual" index of the current entry in the [_playlist], which ignores the shuffle order. This value increments by one when [_next] is called.
  ///
  /// To get the "shuffled" index (e.g., the one that is supposed to be played), use [_shuffledIndex].
  /// To calculate both [_currentIndex] and [_shuffledIndex] at the same time, use [_fixIndecies] method, it is not recommended to set [_currentIndex] directly.
  int _currentIndex = 0;

  /// Returns the possibly "shuffled" index of the current entry in the [_playlist]. Returns the current index if shuffling is disabled ([_isShuffling]), otherwise returns the shuffled index.
  ///
  /// To get the "real" index (e.g., the one that ignores the shuffle order), use [_currentIndex].
  /// To calculate both [_currentIndex] and [_shuffledIndex] at the same time, use [_fixIndecies] method, it is not recommended to set [_shuffledIndex] directly.
  ///
  /// @Zensonaton: Unfortunately, I couldn't find a way to keep the _entryIndex as getter,
  /// because in some methods ([seek], [load], etc.), we had to calculate [_currentIndex] from [_shuffledIndex],
  /// and this was not possible with a `_entryIndex` getter.
  int _shuffledIndex = 0;

  /// Contains the position that the player should [seek] to after the player is ready.
  Duration? _setPosition;

  MediaKitPlayer(super.id) {
    _player = Player(
      configuration: PlayerConfiguration(
        pitch: JustAudioMediaKit.pitch,
        protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
        title: JustAudioMediaKit.title,
        bufferSize: JustAudioMediaKit.bufferSize,
        logLevel: JustAudioMediaKit.mpvLogLevel,
        ready: () => _readyCompleter.complete(),
      ),
    );

    // Enable prefetching.
    if (JustAudioMediaKit.prefetchPlaylist &&
        _player.platform is NativePlayer) {
      (_player.platform as NativePlayer)
          .setProperty('prefetch-playlist', 'yes');
    }

    _streamSubscriptions = [
      _player.stream.duration.listen(
        (duration) {
          _processingState = ProcessingStateMessage.ready;
          _duration = duration;

          // If player is ready, and we have a seek request, then seek to that position.
          if (_setPosition != null && duration.inSeconds > 0) {
            unawaited(
              _player.seek(_setPosition!),
            );

            _setPosition = null;
          }

          _updatePlaybackEvent();
        },
      ),
      _player.stream.position.listen(
        (position) {
          _position = position;

          _updatePlaybackEvent();
        },
      ),
      _player.stream.buffering.listen(
        (isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;

          _updatePlaybackEvent();
        },
      ),
      _player.stream.buffer.listen(
        (buffer) {
          _bufferedPosition = buffer;

          _updatePlaybackEvent();
        },
      ),
      _player.stream.playing.listen(
        (playing) {
          _dataController.add(
            PlayerDataMessage(playing: playing),
          );
        },
      ),
      _player.stream.volume.listen(
        (volume) {
          _dataController.add(
            PlayerDataMessage(volume: volume / 100.0),
          );
        },
      ),
      _player.stream.completed.listen((completed) async {
        if (!completed) return;

        final bool isPlaylistEnd = _currentIndex == _playlist!.length - 1;
        final bool isLooping = _player.state.playlistMode != PlaylistMode.none;

        if (isPlaylistEnd && !isLooping) {
          _processingState = ProcessingStateMessage.completed;
        } else {
          _processingState = ProcessingStateMessage.ready;
        }

        // Start playing next media after current media got completed.
        if (_player.state.playlistMode == PlaylistMode.single) {
          await _player.seek(Duration.zero);
        } else {
          await _next();
        }

        _updatePlaybackEvent();
      }),
      _player.stream.playlist.listen(
        (playlist) {
          _updatePlaybackEvent();
        },
      ),
      _player.stream.playlistMode.listen(
        (playlistMode) {
          _dataController.add(
            PlayerDataMessage(
              loopMode: playlistModeToLoopMode(playlistMode),
            ),
          );
        },
      ),
      _player.stream.pitch.listen(
        (pitch) {
          _dataController.add(
            PlayerDataMessage(pitch: pitch),
          );
        },
      ),
      _player.stream.rate.listen(
        (rate) {
          _dataController.add(
            PlayerDataMessage(speed: rate),
          );
        },
      ),
      _player.stream.error.listen(
        (error) {
          _logger.severe('ERROR OCCURRED: $error');

          _processingState = ProcessingStateMessage.idle;
          // TODO: Pass that error to just_audio.

          _updatePlaybackEvent();
        },
      ),
      _player.stream.log.listen(
        (event) {
          // ignore: avoid_print
          print('MPV: [${event.level}] ${event.prefix}: ${event.text}');

          // TODO: Pass log message to just_audio.
        },
      ),
    ];
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback.
  static Media audioSourceToMedia(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      case final SilenceAudioSourceMessage silenceSource:
        // Source: https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
        return Media(
          'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
        );
    }

    // Unknown audio source type.
    throw UnsupportedError(
      '${audioSource.runtimeType} is currently not supported',
    );
  }

  /// Converts [LoopModeMessage] (just_audio) into [PlaylistMode] (media_kit).
  ///
  /// Opposite of [playlistModeToLoopMode].
  static PlaylistMode loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  /// Converts [PlaylistMode] (media_kit) into [LoopModeMessage] (just_audio).
  ///
  /// Opposite of [loopModeToPlaylistMode].
  static LoopModeMessage playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  /// Updates the playback event with the current state of the player.
  void _updatePlaybackEvent() {
    _eventController.add(
      PlaybackEventMessage(
        processingState: _processingState,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        duration: _duration,
        icyMetadata: null,
        currentIndex: _shuffledIndex,
        androidAudioSessionId: null,
      ),
    );
  }

  /// Sets both [_currentIndex] and [_shuffledIndex] from provided [current] (current index) or [shuffled] (shuffled index).
  ///
  /// For example, [_next] calls this method with [current] + 1, while methods like [seek] or [load] call this method with [shuffled] index specified.
  ///
  /// If [current] is specified, then [_shuffledIndex] is calculated from [_currentIndex] and [_shuffleOrder].
  /// If [shuffled] is specified, then [_currentIndex] is calculated from [_shuffledIndex] and [_shuffleOrder].
  void _fixIndecies({
    int? current,
    int? shuffled,
  }) {
    assert(
      current != null || shuffled != null,
      'At least one of currentIndex or shuffledIndex must be provided.',
    );
    assert(
      current == null || shuffled == null,
      'Only one of currentIndex or shuffledIndex must be provided.',
    );

    if (current != null) {
      _currentIndex = current;
      _shuffledIndex =
          _isShuffling ? _shuffleOrder[_currentIndex] : _currentIndex;
    } else {
      _shuffledIndex = shuffled!;
      _currentIndex =
          _isShuffling ? _shuffleOrder.indexOf(_shuffledIndex) : _shuffledIndex;
    }
  }

  /// Plays the next track in the playlist.
  ///
  /// Don't get confused with [seek], because this method is called only when the current track is completed.
  Future<void> _next() async {
    if (_playlist == null) return;

    // Seek to the beginning of the current track, if loop mode is set to single.
    if (_player.state.playlistMode == PlaylistMode.single) {
      await _player.seek(Duration.zero);

      return;
    }

    // Check if we have reached the end of the playlist.
    if (_currentIndex >= _playlist!.length - 1) {
      if (_player.state.playlistMode == PlaylistMode.loop) {
        _fixIndecies(current: 0);

        await _player.open(_playlist![_shuffledIndex]);
      } else {
        await _player.stop();
      }

      return;
    }

    // We haven't reached the end of the playlist yet, so play the next track.
    _fixIndecies(current: _currentIndex + 1);

    return await _player.open(_playlist![_shuffledIndex]);
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');

    _processingState = ProcessingStateMessage.buffering;
    _currentIndex = request.initialIndex ?? 0;
    _position = _bufferedPosition = Duration.zero;

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final src = request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = src.shuffleOrder;
      _playlist = src.children.map(audioSourceToMedia).toList();

      _fixIndecies(shuffled: _currentIndex);
    } else {
      final playable = audioSourceToMedia(request.audioSourceMessage);

      _logger.finest('playable is ${playable.toString()}');
      _playlist = [playable];
    }

    // [_shuffledIndex] contains the index of a track that is supposed to be played.
    await _player.open(_playlist![_shuffledIndex]);

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;

      // TODO: Fix this seek request here (it doesn't do anything).
      await _player.seek(_setPosition!);
    }

    _updatePlaybackEvent();
    return LoadResponse(
      duration: _player.state.duration,
    );
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    await _player.play();

    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    await _player.pause();

    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    await _player.setVolume(request.volume * 100.0);

    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    await _player.setRate(request.speed);

    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    await _player.setPitch(request.pitch);

    return SetPitchResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(loopModeToPlaylistMode(request.loopMode));

    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(request) async {
    _isShuffling = request.shuffleMode != ShuffleModeMessage.none;

    _dataController.add(
      PlayerDataMessage(
        shuffleMode:
            _isShuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none,
      ),
    );

    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(request) async {
    // Not tested.

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final src = request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = src.shuffleOrder;
    }

    return SetShuffleOrderResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');

    if (request.index != null) {
      // If index is the same, then simply seek at the beginning.
      if (request.index == _shuffledIndex) {
        await _player.seek(Duration.zero);

        return SeekResponse();
      }

      _fixIndecies(shuffled: request.index!);

      await _player.open(_playlist![_shuffledIndex]);
    }

    _position = request.position ?? Duration.zero;
    if (request.position != null) {
      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(request.position!);
      } else {
        _setPosition = request.position!;
      }
    }

    // Reset position after seeking.
    _updatePlaybackEvent();

    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(request) async {
    _logger.fine('concatenatingInsertAll(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    for (final source in request.children) {
      final mkSource = audioSourceToMedia(source);

      if (request.index > _playlist!.length) {
        _playlist!.add(mkSource);
      } else {
        _playlist!.insert(request.index, mkSource);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    // Not tested.

    _logger.fine('concatenatingRemoveRange(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    _playlist!.removeRange(request.startIndex, request.endIndex);

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(request) async {
    _logger.fine('concatenatingMove(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    await _player.move(
      request.currentIndex,

      // Not sure why, but apparently there's an underlying difference between
      // just_audio's move implementation and media_kit, so let's fix it.
      request.currentIndex > request.newIndex
          ? request.newIndex
          : request.newIndex + 1,
    );

    return ConcatenatingMoveResponse();
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.finest('Releasing player resources');

    await _player.dispose();
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }
}
