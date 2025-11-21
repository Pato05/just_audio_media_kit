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
  static final _mpvLogger = Logger('MPV');

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

  /// List of [Player]'s [Media] objects, that are fed one by one to the [_player].
  List<Media>? _playlist;

  /// Whether the player is currently shuffling.
  bool _isShuffling = false;

  /// The shuffled order of the [_playlist].
  List<int> _shuffleOrder = [];

  /// Contains the position that the player should [seek] to after the player is ready.
  Duration? _setPosition;

  /// Whether the player should be playing.  Set by [play] and [pause].
  bool _setPlaying = false;

  /// The oofset of the first native queue track in the virtual queue, used to calculate [_virtualIndex]
  int? _nativeQueueVirtualOffset = 0;

  /// The [_playlist] indexes of the tracks currently submitted to [_player].
  List<int> _nativeQueueOrder = [];

  /// Prevents two copies of [_setNativeQueue] from running at once to prevent conflicting edits to [_nativeQueueOrder]
  /// Lifecycle should be identical to [_playlistIndexOverride]
  Completer<void>? _nativeQueueLock;

  /// Supplies the playlist index during the period in which the [_player] index and [_nativeQueueOrder] may be desynced
  /// Lifecycle should be identical to [_nativeQueueLock]
  int? _playlistIndexOverride;

  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;

  /// Our position in the queue as presented to users.  Always advances by one on non-final track completion.
  int get _virtualIndex {
    if (_nativeQueueVirtualOffset == null) return 0;
    return _nativeQueueVirtualOffset! + _player.state.playlist.index;
  }

  /// The position in the virtual queue of the currently playing track.  This should be identical to [_virtualIndex]
  /// unless [_playlist] has just been modified.  In that situation, it can be fed to [_setNativeQueue] to avoid
  /// changing the currently playing track.
  int get _playingVirtualIndex {
    if (_nativeQueueOrder.isEmpty) return 0;
    int playlistIndex = _playlistIndexOverride ?? _nativeQueueOrder[_player.state.playlist.index];
    return _isShuffling ? _shuffleOrder.indexOf(playlistIndex) : playlistIndex;
  }

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

  Duration get _position {
    var position = _player.state.position;
    final start = _currentMedia?.start;
    if (start != null) position -= start;
    if (position < Duration.zero) position = Duration.zero;
    return position;
  }

  Duration get _duration {
    final media = _currentMedia;
    if (media?.extras?['overrideDuration'] != null) return media?.extras?['overrideDuration'];
    Duration duration = media?.end ?? _player.state.duration;
    final start = media?.start;
    if (start != null) duration -= start;
    return duration;
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
        if (_setPosition != null && duration.inSeconds > 0) {
          unawaited(_player.seek(_setPosition!));
          _setPosition = null;
        }
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        _updateBufferingState();
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _updateBufferingState();
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _errorCode = null;
        _errorMessage = null;
        if (completed) {
          // If not looping and at end of virtual Queue, set state to completed.
          if (_virtualIndex + 1 == (_playlist?.length ?? 0) && _player.state.playlistMode == PlaylistMode.none) {
            _processingState = ProcessingStateMessage.completed;
          }
          // Start playing next media after current media got completed.
          if (_player.state.playlistMode != PlaylistMode.single) {
            unawaited(_advanceNativeQueue());
          }
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
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        final mpvLevel =
            MPVLogLevel.values.firstWhere((x) => x.name == event.level, orElse: () => JustAudioMediaKit.mpvLogLevel);
        final logLevel = switch (mpvLevel) {
          MPVLogLevel.error => Level.SEVERE,
          MPVLogLevel.warn => Level.WARNING,
          MPVLogLevel.info => Level.INFO,
          MPVLogLevel.v => Level.FINE,
          MPVLogLevel.debug => Level.FINER,
          MPVLogLevel.trace => Level.FINEST,
        };
        _mpvLogger.log(logLevel, "${event.prefix}: ${event.text}");
        // TODO: Pass log message to just_audio.
      }),
    ];
  }

  /// Update _processingState based on _player's buffering status.
  void _updateBufferingState() {
    if (_processingState == ProcessingStateMessage.loading) {
      if (!_player.state.buffering) {
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (start == null || _player.state.buffer > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
      }
    } else {
      if (_player.state.buffering) {
        _processingState = ProcessingStateMessage.buffering;
      }
    }
  }

  /// Advance the native queue to the next track
  /// This is expected to be called as soon as the native track 0 completes, before the transition to
  /// track 1 occurs.  It updates the native queue so that the next track is in position 0.
  Future<void> _advanceNativeQueue() async {
    if (_playlist == null || _nativeQueueVirtualOffset == null) return;

    int nativeIndex = _player.state.playlist.index;
    if (nativeIndex == 0) {
      // We should be in the transition between tracks 0 and 1.  This is the expected timing.
      assert(_position + const Duration(seconds: 1) > _duration);
      return await _setNativeQueue(_nativeQueueVirtualOffset! + 1, forcePrefetch: true);
    } else if (nativeIndex == 1 && _position < const Duration(seconds: 1)) {
      _logger.warning("_advanceNativeQueue called after playback of next track has already started");
      // We have been called slightly late.  There may be a hitch in playback as we update the queue and reset the current track.
      return await _setNativeQueue(_nativeQueueVirtualOffset! + 1, forcePrefetch: true);
    } else {
      _logger.severe("_advanceNativeQueue called with unexpected native index $nativeIndex at position $_position");
      // We have been called at an unexpected time.  Do not forcePretetch to avoid resetting song position.
      return await _setNativeQueue(_virtualIndex, forcePrefetch: false);
    }
  }

  /// Sends the next [JustAudioMediaKit.prefetchPlaylistSize] tracks to the player, and plays them.
  /// The first track in the native queue will be at newVirtualIndex, and will become the currently
  /// playing track.  newVirtualIndex should generally be set to either _virtualIndex or _playingVirtualIndex,
  /// depending on if playlist changes have occurred.  If the newVirtualIndex track matches the currently playing
  /// track and forcePrefetch is not true, the native queue will be modified with the new values.  This avoids interrupting
  /// playback but does not trigger prefetching.  Otherwise, the whole queue will be replaced, which triggers prefetching
  /// of the new values but still uses the old queue's prefetched tracks, if applicable.
  Future<void> _setNativeQueue(int newVirtualIndex, {bool forcePrefetch = false}) async {
    if (_playlist == null) return;

    newVirtualIndex = newVirtualIndex.clamp(0, _playlist!.length);

    // Select the next [prefetchPlaylistSize] that will play, looping back to 0 if in loop mode.
    List<int> virtualQueue = List.generate(JustAudioMediaKit.prefetchPlaylistSize, (x) => x + newVirtualIndex);
    if (_player.state.playlistMode == PlaylistMode.loop) {
      virtualQueue = virtualQueue.map((x) => x % _playlist!.length).toList();
    } else {
      virtualQueue = virtualQueue.where((x) => x < _playlist!.length).toList();
    }

    _nativeQueueVirtualOffset = newVirtualIndex;
    List<int> newNativeQueue;

    if (_isShuffling) {
      newNativeQueue = virtualQueue.map((x) => _shuffleOrder[x]).toList();
      ;
    } else {
      newNativeQueue = virtualQueue;
    }

    _logger.fine("Setting native queue to $newNativeQueue");

    while (_nativeQueueLock != null) {
      await _nativeQueueLock!.future;
    }
    try {
      _nativeQueueLock = Completer();
      _playlistIndexOverride = newNativeQueue.isEmpty ? 0 : newNativeQueue[0];
      // If the new current song matches the existing current song and !forcePrefetch, use the queue update algorithm
      // instead of replacing the whole queue.  This avoids interrupting playback of the current track and resetting its
      // play position, but does not result in the new upcoming track being prefetched.
      int currentIndex = _player.state.playlist.index;
      if (!forcePrefetch && _nativeQueueOrder.isNotEmpty && newNativeQueue.isNotEmpty && _nativeQueueOrder[currentIndex] == newNativeQueue[0]) {
        int validUpcomingIndex = 0;
        // Find out how many upcoming tracks match the new queue
        // We can skip 0 as its already been checked
        for (int i = 1; i < newNativeQueue.length && currentIndex + i < _nativeQueueOrder.length; i++) {
          if (_nativeQueueOrder[currentIndex + i] == newNativeQueue[i]) {
            validUpcomingIndex = currentIndex + i;
          } else {
            break;
          }
        }

        // Remove upcoming tracks that don't match
        int originalQueueLength = _nativeQueueOrder.length;
        for (int i = validUpcomingIndex + 1; i < originalQueueLength; i++) {
          _nativeQueueOrder.removeAt(validUpcomingIndex + 1);
          await _player.remove(validUpcomingIndex + 1);
        }
        // Add new tracks that weren't matched
        for (int i = validUpcomingIndex + 1; i < newNativeQueue.length; i++) {
          _nativeQueueOrder.add(newNativeQueue[i]);
          await _player.add(_playlist![newNativeQueue[i]]);
        }
        // Remove all previous tracks
        for (int i = 0; i < currentIndex; i++) {
          _nativeQueueOrder.removeAt(0);
          await _player.remove(0);
        }
      } else {
        _nativeQueueOrder = newNativeQueue;
        await _player.open(
          Playlist(newNativeQueue
              .map(
                (index) => _playlist![index],
              )
              .toList()),
          play: _setPlaying,
        );
      }
      // Assert _nativeQueueOrder matches newNativeQueue
      assert(_nativeQueueOrder.length == newNativeQueue.length);
      for (int i = 0; i < newNativeQueue.length; i++) {
        assert(newNativeQueue[i] == _nativeQueueOrder[i]);
        // _player queue state does not seem to immediately update, so we can't verify it
        //assert(_playlist![_nativeQueueOrder[i]].uri == _player.state.playlist.medias[i].uri);
      }
    } finally {
      _nativeQueueLock?.complete();
      _nativeQueueLock = null;
      _playlistIndexOverride = null;
    }
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _dataController.stream;

  /// Updates the playback event with the current state of the player.
  void _updatePlaybackEvent() {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _player.state.buffer,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _playlist == null
          ? 0
          : (_playlistIndexOverride ??
                  (_nativeQueueOrder.isEmpty ? 0 : _nativeQueueOrder[_player.state.playlist.index]))
              .clamp(0, _playlist!.length),
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    _playlist = null;
    _loadCompleter = Completer();
    _setPosition = request.initialPosition;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource = request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = audioSource.shuffleOrder;
      _playlist = audioSource.children.map(_convertAudioSourceToMediaKit).toList();
    } else {
      final playable = _convertAudioSourceToMediaKit(request.audioSourceMessage);

      _logger.finest('playable is ${playable.toString()}');
      _playlist = [playable];
    }

    final requestIndex = request.initialIndex ?? 0;
    await _setNativeQueue(_isShuffling ? _shuffleOrder.indexOf(requestIndex) : requestIndex);

    _updatePlaybackEvent();
    final duration = await _loadCompleter?.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _setPlaying = true;
    if (_playlist != null) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _setPlaying = false;
    if (_playlist != null) {
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

    await _setNativeQueue(_playingVirtualIndex);

    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(request) async {
    _logger.finest('setShuffleMode(${request.toMap()})');

    final oldIsShuffling = _isShuffling;

    _isShuffling = request.shuffleMode != ShuffleModeMessage.none;

    _dataController
        .add(PlayerDataMessage(shuffleMode: _isShuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));

    if (_isShuffling != oldIsShuffling) {
      await _setNativeQueue(_playingVirtualIndex);
    }

    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(request) async {
    _logger.finest('setShuffleOrder(${request.toMap()})');

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final src = request.audioSourceMessage as ConcatenatingAudioSourceMessage;

      _shuffleOrder = src.shuffleOrder;
    }

    await _setNativeQueue(_playingVirtualIndex);

    return SetShuffleOrderResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');

    final requestVirtualIndex =
        request.index != null && _isShuffling ? _shuffleOrder.indexOf(request.index!) : request.index;
    if (requestVirtualIndex != null && requestVirtualIndex != _virtualIndex) {
      await _setNativeQueue(requestVirtualIndex);
    }

    final position = request.position;
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
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    _logger.fine('concatenatingInsertAll(${request.toMap()})');

    _shuffleOrder = request.shuffleOrder;

    _playlist!.insertAll(request.index, request.children.map((x) => _convertAudioSourceToMediaKit(x)));

    int calculateOffset(int x) {
      if (x >= request.index) {
        x += request.children.length;
      }
      return x;
    }

    _nativeQueueOrder = _nativeQueueOrder.map(calculateOffset).toList();

    _setNativeQueue(_playingVirtualIndex);

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    _logger.fine('concatenatingRemoveRange(${request.toMap()})');
    assert(_playlist != null);

    _shuffleOrder = request.shuffleOrder;

    _playlist!.removeRange(request.startIndex, request.endIndex);

    int calculateOffset(int x) {
      if (x >= request.endIndex) {
        x -= request.endIndex - request.startIndex;
      } else if (x >= request.startIndex) {
        x = -1;
      }
      return x;
    }

    _nativeQueueOrder = _nativeQueueOrder.map(calculateOffset).toList();

    _setNativeQueue(_playingVirtualIndex);

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(request) async {
    _logger.fine('concatenatingMove(${request.toMap()})');
    assert(_playlist != null);

    _shuffleOrder = request.shuffleOrder;
    final moved = _playlist!.removeAt(request.currentIndex);
    _playlist!.insert(request.newIndex, moved);

    int calculateOffset(int x) {
      if (x == request.currentIndex) {
        x = -1;
      } else {
        if (x > request.currentIndex) {
          x--;
        }
        if (x >= request.newIndex) {
          x++;
        }
      }
      return x;
    }

    _nativeQueueOrder = _nativeQueueOrder.map(calculateOffset).toList();

    _setNativeQueue(_playingVirtualIndex);

    return ConcatenatingMoveResponse();
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');
    _playlist = null;
    _processingState = ProcessingStateMessage.idle;
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
        return Media(clippingSource.child.uri, start: clippingSource.start, end: clippingSource.end);

      default:
        throw UnsupportedError('${audioSource.runtimeType} is currently not supported');
    }
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
}
