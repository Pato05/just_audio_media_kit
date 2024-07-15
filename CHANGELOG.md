## 2.0.5

- Override duration for [SilenceAudioSource]
- Fix desync issue when entry is removed from [ConcatenatingAudioSource] (Fixes [#12](https://github.com/Pato05/just_audio_media_kit/issues/12))

## 2.0.4

- Support `--prefetch-playlist` for gapless playback (fixes [#11](https://github.com/Pato05/just_audio_media_kit/issues/11))
- Reset `Duration` on track change (fixes [#10](https://github.com/Pato05/just_audio_media_kit/issues/10))
- Set `pitch` to `true` by default (fix `setPitch` not working)

## 2.0.3

- Add `libmpv` parameter to `ensureInitialized` ([#9](https://github.com/Pato05/just_audio_media_kit/issues/9))

## 2.0.2

- Fix: defer setting initial position to when the track starts loading (fixes seeking before loading the track, which seems not to be currently supported by `media_kit`): see [related issue](https://github.com/Pato05/just_audio_media_kit/issues/6) and [`media_kit` related issue](https://github.com/media-kit/media-kit/issues/228)
- Add `SilenceAudioSource` support via anullsrc ([taken from just_audio_mpv](https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137))

## 2.0.1

- Fix issues regarding disposal of current players

## 2.0.0

- **BREAKING: Removed hard dependencies** (Read the installation steps in README to comply!)
- Fix queue insert with index
- Fix moving items in ConcatenatingAudioSource

## 1.0.0

- Make private methods private, as they should've been
- Set position and index on load (and reset bufferedPosition)
- Fix disposePlayer() failing by making it so that if the player was already disposed, it won't throw, since `just_audio` can send out two identical dispose requests.
- More settings
- Update `media_kit` to `^1.1.9`

## 0.0.1

- Initial release
- Linux and Windows support
