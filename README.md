# just_audio_media_kit

`media_kit` bindings for `just_audio`

## Installation

Just include this package into your flutter/dart app, and use `just_audio` as normal.

```bash
flutter pub add just_audio_media_kit
```

or you can use the git version

`pubspec.yaml`:
```yaml
dependencies:
    ...
    just_audio_media_kit:
        git:
            url: https://github.com/Pato05/just_audio_media_kit.git
```

## Plugin-specific configuration

Set MPV's log level (by default it's set to `MPVLogLevel.error`):

```dart
JustAudioMediaKit.mpvLogLevel = MPVLogLevel.debug;
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