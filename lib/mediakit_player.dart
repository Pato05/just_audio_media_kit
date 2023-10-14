import 'dart:async';

import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayer extends AudioPlayerPlatform {
  late final Player _player;
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();
  Future<void> get isReady => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;

  MediaKitPlayer(super.id) {
    _player = Player(
        configuration: PlayerConfiguration(
      title: 'JustAudioMediaKit',
      logLevel: MPVLogLevel.debug,
      ready: () => _readyCompleter.complete(),
    ));
    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        _processingState = ProcessingStateMessage.ready;
        updatePlaybackEvent(duration: duration);
      }),
      _player.stream.position.listen((position) {
        _position = position;
        updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        _logger.fine('isBuffering: $isBuffering');
        _processingState = isBuffering
            ? ProcessingStateMessage.buffering
            : ProcessingStateMessage.ready;
        updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        updatePlaybackEvent();
      }),
      _player.stream.playing.listen((playing) {
        _processingState = ProcessingStateMessage.ready;
        _dataController.add(PlayerDataMessage(playing: playing));
        updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume));
      }),
      _player.stream.completed.listen((completed) {
        _processingState = completed
            ? ProcessingStateMessage.completed
            : ProcessingStateMessage.ready;
        updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        _processingState = ProcessingStateMessage.idle;
        updatePlaybackEvent();
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        updatePlaybackEvent(currentIndex: playlist.index);
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        _logger.fine("[${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  void updatePlaybackEvent(
      {Duration? duration,
      IcyMetadataMessage? icyMetadata,
      int? currentIndex}) {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: duration,
      icyMetadata: icyMetadata,
      currentIndex: currentIndex,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    print('hello');
    await _player.setAudioDevice(AudioDevice.auto());

    _logger.fine('loading tracks... ${request.toMap()}');
    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final as = request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final playable = Playlist(
          as.children.map(_convertAudioSourceIntoMediaKit).toList(),
          index: request.initialIndex ?? 0);
      _logger.fine('tracks converted: ${playable.toString()}');

      await _player.open(playable, play: false);
    } else {
      final playable =
          _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
      _logger.fine('playable is ${playable.toString()}');
      await _player.open(playable, play: false);
    }

    if (request.initialPosition != null) {
      await _player.seek(request.initialPosition!);
    }

    return LoadResponse(duration: _player.state.duration);
  }

  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    if (audioSource is UriAudioSourceMessage) {
      return Media(audioSource.uri, httpHeaders: audioSource.headers);
    } else {
      throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported');
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    _logger.fine('play() called');
    return _player.play().then((_) => PlayResponse());
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) {
    _logger.fine('pause() called');
    return _player.pause().then((_) => PauseResponse());
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    _logger.fine('setVolume(${request.toMap()})');
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  // @override
  // Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
  //     _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) => _player
      .setPlaylistMode(const {
        LoopModeMessage.off: PlaylistMode.none,
        LoopModeMessage.one: PlaylistMode.single,
        LoopModeMessage.all: PlaylistMode.loop,
      }[request.loopMode]!)
      .then((_) => SetLoopModeResponse());

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) =>
      _player
          .setShuffle(request.shuffleMode == ShuffleModeMessage.all)
          .then((_) => SetShuffleModeResponse());

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) {
      await _player.jump(request.index!);
    }
    if (request.position != null) {
      await _player.seek(request.position!);
    }

    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length - 1, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = 0; i < request.endIndex - request.startIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) =>
      _player
          .move(request.currentIndex, request.newIndex)
          .then((_) => ConcatenatingMoveResponse());

  Future<void> release() async {
    _logger.info('releasing player resources');
    await _player.dispose();

    // cancel all stream subscriptions
    for (final subscription in _streamSubscriptions) {
      await subscription.cancel();
    }
  }
}
