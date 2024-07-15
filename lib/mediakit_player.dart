library just_audio_media_kit;

import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  List<Media>? _playlist;
  List<int> _shuffleOrder = [];
  bool _shuffling = false;
  int _currentIndex = 0;

  // This takes into account the fact we may be currently shuffling.
  /// Returns the current entry's actual index (even if shuffling)
  int get _entryIndex =>
      _shuffling ? _shuffleOrder[_currentIndex] : _currentIndex;

  /// [LoadRequest.initialPosition] or [seek] request before [Player.play] was called and/or finished loading.
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
    ));

    if (JustAudioMediaKit.prefetchPlaylist &&
        _player.platform is NativePlayer) {
      (_player.platform as NativePlayer)
          .setProperty('prefetch-playlist', 'yes');
    }

    _streamSubscriptions = [
      _player.stream.duration.listen(
        (duration) {
          _processingState = ProcessingStateMessage.ready;

          if (_setPosition != null && duration.inSeconds > 0) {
            unawaited(_player.seek(_setPosition!));

            _setPosition = null;
          }

          _updatePlaybackEvent(duration: duration);
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
          _dataController.add(PlayerDataMessage(playing: playing));
        },
      ),
      _player.stream.volume.listen(
        (volume) {
          _dataController.add(PlayerDataMessage(volume: volume / 100.0));
        },
      ),
      _player.stream.completed.listen((completed) async {
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        } else {
          _processingState = ProcessingStateMessage.ready;
        }

        // Start playing next media after current media got completed.
        if (completed) {
          if (_player.state.playlistMode == PlaylistMode.single) {
            await _player.seek(Duration.zero);
          } else {
            await next();
          }
        }

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen(
        (error) {
          _logger.severe('ERROR OCCURRED: $error');

          _processingState = ProcessingStateMessage.idle;

          _updatePlaybackEvent();
        },
      ),
      _player.stream.playlist.listen(
        (playlist) {
          _updatePlaybackEvent();
        },
      ),
      _player.stream.playlistMode.listen(
        (playlistMode) {
          _dataController.add(
            PlayerDataMessage(
              loopMode: _playlistModeToLoopMode(playlistMode),
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
      _player.stream.log.listen(
        (event) {
          // ignore: avoid_print
          print('MPV: [${event.level}] ${event.prefix}: ${event.text}');
        },
      ),
    ];
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  void _updatePlaybackEvent({
    Duration? duration,
    IcyMetadataMessage? icyMetadata,
  }) {
    _eventController.add(
      PlaybackEventMessage(
        processingState: _processingState,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        duration: duration,
        icyMetadata: icyMetadata,
        currentIndex: _currentIndex,
        androidAudioSessionId: null,
      ),
    );
  }

  /// Plays the next media, while respecting [_playlist] and [_currentIndex].
  Future<void> next() async {
    if (_playlist == null) return;

    // Check if current track is last, then take the specified approach based on the [playlistMode].
    if (_currentIndex == _playlist!.length - 1) {
      switch (_player.state.playlistMode) {
        case PlaylistMode.loop:
          _currentIndex = 1;

          await _player.open(
            _playlist![_entryIndex],
            play: true,
          );
          break;
        case PlaylistMode.single:
          await _player.seek(Duration.zero);

          break;
        case PlaylistMode.none:
          await _player.stop();

          break;
      }

      return;
    }

    _currentIndex += 1;
    return await _player.open(
      _playlist![_entryIndex],
      play: true,
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');

    _currentIndex = request.initialIndex!;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;

    _processingState = ProcessingStateMessage.buffering;

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _playlist =
          audioSource.children.map(_convertAudioSourceIntoMediaKit).toList();
      _shuffleOrder = audioSource.shuffleOrder;
    } else {
      final playable =
          _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
      _logger.finest('playable is ${playable.toString()}');
      _playlist = [playable];
    }

    await _player.open(_playlist![_entryIndex]);

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;

      // TODO: fix this seek request here (it doesn't do anything)
      await _player.seek(request.initialPosition!);
    }

    _updatePlaybackEvent();
    return LoadResponse(duration: _player.state.duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    return _player.play().then((_) => PlayResponse());
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) {
    return _player.pause().then((_) => PauseResponse());
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));

    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async {
    _shuffling = request.shuffleMode != ShuffleModeMessage.none;

    _dataController.add(
      PlayerDataMessage(
        shuffleMode:
            _shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none,
      ),
    );

    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async {
    // Not tested.

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = audioSource.shuffleOrder;
    }

    return SetShuffleOrderResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');

    if (request.index != null) {
      _currentIndex = request.index!;

      await _player.open(
        _playlist![_entryIndex],
        play: true,
      );
    }

    if (request.position != null) {
      _position = request.position!;

      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(request.position!);
      } else {
        _setPosition = request.position!;
      }
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();

    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');

    for (final source in request.children) {
      if (request.index > _playlist!.length) {
        _playlist!.add(_convertAudioSourceIntoMediaKit(source));
      } else {
        _playlist!
            .insert(request.index, _convertAudioSourceIntoMediaKit(source));
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    _shuffleOrder = request.shuffleOrder;

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) {
    _shuffleOrder = request.shuffleOrder;
    return _player
        .move(
            request.currentIndex,
            // not sure why, but apparently there's an underlying difference between just_audio's move implementation
            // and media_kit, so let's fix it
            request.currentIndex > request.newIndex
                ? request.newIndex
                : request.newIndex + 1)
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');

    await _player.dispose();
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      case final SilenceAudioSourceMessage silenceSource:
        // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
        return Media(
            'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms');

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}
