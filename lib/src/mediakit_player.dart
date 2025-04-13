import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player].
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;
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
  Duration? _duration;

  bool _playing = false;
  bool _mediaOpened = false;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;

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

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

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

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration.inSeconds > 0) {
          unawaited(_player.seek(_setPosition!));
          _setPosition = null;
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _bufferedPosition = _position = Duration.zero;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;
        // Start playing next media after current media got completed.
        if (_player.state.playlistMode == PlaylistMode.single) {
          unawaited(_player.seek(Duration.zero));
        } else {
          unawaited(_next());
        }

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null || errorUri == _currentMedia?.uri) {
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          _updatePlaybackEvent();
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
            PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // ignore: avoid_print
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");

        // TODO: Pass log message to just_audio.
      }),
    ];
  }

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  /// Converts [LoopModeMessage] (just_audio) into [PlaylistMode] (media_kit).
  ///
  /// Opposite of [_playlistModeToLoopMode].
  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  /// Converts [PlaylistMode] (media_kit) into [LoopModeMessage] (just_audio).
  ///
  /// Opposite of [_loopModeToPlaylistMode].
  static LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
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

        await _sendAudios();
      } else {
        await _player.stop();
      }

      return;
    }

    // We haven't reached the end of the playlist yet, so play the next track.
    _fixIndecies(current: _currentIndex + 1);

    return await _sendAudios();
  }

  /// Sends the next [JustAudioMediaKit.prefetchPlaylistSize] tracks to the player, and plays them.
  Future<void> _sendAudios() async {
    if (_playlist == null) return;

    // Take [prefetchPlaylistSize] tracks from the playlist and send them to the player.
    final int maxSize =
        (_currentIndex + JustAudioMediaKit.prefetchPlaylistSize).clamp(
      0,
      _playlist!.length,
    );

    await _player.open(
      Playlist(
        _isShuffling
            ? _shuffleOrder
                .sublist(_currentIndex, maxSize)
                .map(
                  (index) => _playlist![index],
                )
                .toList()
            : _playlist!.sublist(
                _currentIndex,
                maxSize,
              ),
      ),
      play: _playing,
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event with the current state of the player.
  void _updatePlaybackEvent() {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _shuffledIndex,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    _mediaOpened = false;
    _loadCompleter = Completer();
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = audioSource.shuffleOrder;
      _playlist =
          audioSource.children.map(_convertAudioSourceToMediaKit).toList();

      _fixIndecies(shuffled: _currentIndex);
    } else {
      final playable =
          _convertAudioSourceToMediaKit(request.audioSourceMessage);

      _logger.finest('playable is ${playable.toString()}');
      _playlist = [playable];
    }
    _mediaOpened = true;

    // [_shuffledIndex] contains the index of a track that is supposed to be played.
    await _sendAudios();

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;
    }

    _updatePlaybackEvent();
    final duration = await _loadCompleter?.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    if (_mediaOpened) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
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
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));

    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(request) async {
    _isShuffling = request.shuffleMode != ShuffleModeMessage.none;

    _dataController.add(PlayerDataMessage(
        shuffleMode:
            _isShuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));

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
      _fixIndecies(shuffled: request.index!);

      await _sendAudios();
      if (!_playing) await _player.pause();
    }

    final position = request.position;
    _position = position ?? Duration.zero;
    if (position != null) {
      final start = _currentMedia?.start;
      var nativePosition = position;
      if (start != null) nativePosition += start;
      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(nativePosition);
      } else {
        _setPosition = nativePosition;
      }
    }

    // Reset position after seeking.
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    for (final source in request.children) {
      final mkSource = _convertAudioSourceToMediaKit(source);

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
    // TODO: Not tested.

    _logger.fine('concatenatingRemoveRange(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    _playlist!.removeRange(request.startIndex, request.endIndex);

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(request) async {
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
    _logger.info('releasing player resources');
    _mediaOpened = false;
    await _player.dispose();
    // cancel all stream subscriptions
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceToMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(clippingSource.child.uri,
            start: clippingSource.start, end: clippingSource.end);

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}
