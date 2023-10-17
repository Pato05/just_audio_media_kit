# just_audio_media_kit

`media_kit` bindings for `just_audio`

## Installation

Just include this package into your flutter/dart app, and use `just_audio` as normal.

```bash
flutter pub add just_audio_media_kit
```

or you can use the git version

```yaml
just_audio_media_kit:
    git:
        url: https://github.com/Pato05/just_audio_media_kit.git
```

## Plugin-specific configuration (settings for `media_kit`'s `Player()` instance)

**NOTE**: these must be set <u>before</u> the player initializes or they won't work!


Set MPV's log level. Default: `MPVLogLevel.error`

```dart
JustAudioMediaKit.mpvLogLevel = MPVLogLevel.debug;
```

Sets the demuxer's cache size (in bytes). Default: `32 * 1024 * 1204` (32 MB)

```dart
JustAudioMediaKit.bufferSize = 8 * 1024 * 1024; // 8 MB
```

Sets the name of the underlying window and process for native backend. This is visible, for example, inside the Windows' volume mixer or also in `pavucontrol` on Linux. Default: `'JustAudioMediaKit'`

```dart
JustAudioMediaKit.title = 'My Audio Player App';
```

Sets the list of allowed protocols for native backend. Default: `['udp', 'rtp', 'tcp', 'tls', 'data', 'file', 'http', 'https', 'crypto']`

**IF YOU EDIT THIS OPTION**: Remember that `file` is needed for playing local files, `https` and `http` are needed to play from URLs and `http` to play from a `StreamAudioSource` (and sources that implement it, like `LockCachingAudioSource`).

```dart
JustAudioMediaKit.protocolWhitelist = const ['http', 'https'];
```

## Features

| Feature                        |  Linux, Windows |
| ------------------------------ |  :--: |
| read from URL                  |   ✅   |
| read from file                 |   ✅   |
| read from asset                |   ✅   |
| read from byte stream          |   ✅*  |
| request headers                |   ✅ (untested)   |
| DASH                           |   ✅ (untested)  |
| HLS                            |   ✅ (untested)  |
| ICY metadata                   |        |
| buffer status/position         |   ✅   |
| play/pause/seek                |   ✅   |
| set volume/speed               |   ✅   |
| clip audio                     |      |
| playlists                      |   ✅   |
| looping/shuffling              |   ✅   |
| compose audio                  |        |
| gapless playback               |   ✅   |
| report player errors           |   ✅   |
| handle phonecall interruptions |        |
| buffering/loading options      |        |
| set pitch                      |   ✅   |
| skip silence                   |        |
| equalizer                      |        |
| volume boost                   |        |

\* reads from byte stream via a local HTTP server provided by `just_audio`