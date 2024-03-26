import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayer extends AudioPlayerPlatform {
  late final Player _player;
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  List<Media>? _playlist;
  List<int>? _shuffleOrder;
  bool _shuffling = false;
  int _currentIndex = 0;
  int _shuffledIndex = 0;

  MediaKitPlayer(super.id) {
    _player = Player(
      configuration: PlayerConfiguration(
        protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
        title: JustAudioMediaKit.title,
        bufferSize: JustAudioMediaKit.bufferSize,
        logLevel: JustAudioMediaKit.mpvLogLevel,
        ready: () => _readyCompleter.complete(),
      ),
    );

    _streamSubscriptions = [
      _player.stream.duration.listen(
        (duration) {
          _processingState = ProcessingStateMessage.ready;
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
      _player.stream.log.listen(
        (event) {
          // ignore: avoid_print
          print('MPV: [${event.level}] ${event.prefix}: ${event.text}');
        },
      ),
    ];
  }

  PlaylistMode loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage playlistModeToLoopMode(PlaylistMode playlistMode) {
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
        currentIndex: _shuffledIndex,
        androidAudioSessionId: null,
      ),
    );
  }

  Future<void> next() async {
    if (_playlist == null) return;

    // Check if current track is last, if it is - repeat it.
    if (_currentIndex == _playlist!.length - 1) {
      switch (_player.state.playlistMode) {
        case PlaylistMode.loop:
          _currentIndex = 1;
          _shuffledIndex =
              _shuffling ? _shuffleOrder![_currentIndex] : _currentIndex;

          return await _player.open(
            _playlist![_shuffledIndex],
            play: true,
          );
        case PlaylistMode.single:
          await _player.seek(Duration.zero);

          break;
        case PlaylistMode.none:
          await _player.stop();

          break;
        default:
      }
    }

    _currentIndex += 1;
    _shuffledIndex = _shuffling ? _shuffleOrder![_currentIndex] : _currentIndex;

    return await _player.open(
      _playlist![_shuffledIndex],
      play: true,
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');

    _currentIndex = _shuffling
        ? _shuffleOrder!.indexOf(request.initialIndex!)
        : request.initialIndex!;
    _shuffledIndex = request.initialIndex!;
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

    await _player.open(_playlist![_currentIndex]);

    if (request.initialPosition != null) {
      _position = request.initialPosition!;

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
    await _player.setPlaylistMode(loopModeToPlaylistMode(request.loopMode));

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
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');

    if (request.index != null) {
      _currentIndex =
          _shuffling ? _shuffleOrder!.indexOf(request.index!) : request.index!;
      _shuffledIndex = request.index!;

      await _player.open(
        _playlist![_shuffledIndex],
        play: true,
      );
    }

    if (request.position != null) {
      _position = request.position!;

      await _player.seek(request.position!);
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
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async {
    for (var i = request.startIndex; i <= request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) {
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

  Future<void> release() async {
    _logger.info('releasing player resources');

    await _player.dispose();
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    if (audioSource is UriAudioSourceMessage) {
      return Media(audioSource.uri, httpHeaders: audioSource.headers);
    } else {
      throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported');
    }
  }
}
