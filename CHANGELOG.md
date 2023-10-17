## 1.0.0

- Make private methods private, as they should've been
- Set position and index on load (and reset bufferedPosition)
- Fix disposePlayer() failing by making it so that if the player was already disposed, it won't throw, since `just_audio` can send out two identical dispose requests.
- More settings
- Update `media_kit` to `^1.1.9`

## 0.0.1

- Initial release
- Linux and Windows support