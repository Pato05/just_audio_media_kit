# just_audio_media_kit

`media_kit` bindings for `just_audio`

## Breaking changes in 2.x

The installation process has changed, please re-read the install instructions.

## Installation

### In your `pubspec.yaml`:

```yaml
dependencies:
  just_audio_media_kit: ^2.0.0

  # Select the native media_kit libs based on your usage:
  # NOTE: if including video libs already, these audio libs aren't necessary.
  media_kit_libs_linux: any
  media_kit_libs_windows_audio: any
```

**Note**: you can also use `just_audio_media_kit` for Android, iOS and macOS by including the libs and including them in the `init()` function. But only do this if you know what you're doing, as they're natively supported by `just_audio`

### Before using the `AudioPlayer`, call

```dart
JustAudioMediaKit.ensureInitialized();

// or, if you want to manually configure platforms instead:

JustAudioMediaKit.ensureInitialized(
    linux: true,            // default: true  - dependency: media_kit_libs_linux
    windows: true,          // default: true - dependency: media_kit_libs_windows_audio
    android: true,          // default: false - dependency: media_kit_libs_android_audio
    iOS: true,              // default: false - dependency: media_kit_libs_ios_audio
    macOS: true,            // default: false - dependency: media_kit_libs_macos_audio
);
```

Now you can use just_audio's `AudioPlayer` as normal!

## Plugin-specific configuration (settings for `media_kit`'s `Player()` instance)

**NOTE**: these must be set <u>before</u> the player initializes or they won't work (you can set these right after calling `ensureInitialized`)!

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

| Feature                        | Linux, Windows |
| ------------------------------ | :------------: |
| read from URL                  |       ✅       |
| read from file                 |       ✅       |
| read from asset                |       ✅       |
| read from byte stream          |      ✅\*      |
| request headers                | ✅ (untested)  |
| DASH                           | ✅ (untested)  |
| HLS                            | ✅ (untested)  |
| ICY metadata                   |                |
| buffer status/position         |       ✅       |
| play/pause/seek                |       ✅       |
| set volume/speed               |       ✅       |
| clip audio                     |                |
| playlists                      |       ✅       |
| looping/shuffling              |       ✅       |
| compose audio                  |                |
| gapless playback               |       ✅       |
| report player errors           |       ✅       |
| handle phonecall interruptions |                |
| buffering/loading options      |                |
| set pitch                      |       ✅       |
| skip silence                   |                |
| equalizer                      |                |
| volume boost                   |                |

\* reads from byte stream via a local HTTP server provided by `just_audio`

## Caveats

- `just_audio`'s shuffleOrder is currently ignored, because there doesn't seem to be a straightforward way to implement it
- `ClippingAudioSource` is currently not supported (waiting for [media-kit/media-kit#581](https://github.com/media-kit/media-kit/pull/581) to be released)
- The plugin hasn't been tested with multiple player instances, though it might work.

## Licensing

This package is licensed under the `Unlicense` license, though
please note that `package:media_kit` (which is a direct dependency of this package) is licensed under the `MIT` license.
So please refer to [`package:media_kit`](https://github.com/media-kit/media-kit) for potential licensing issues.
