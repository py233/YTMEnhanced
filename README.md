# YTMEnhanced

<p align="center">
<img src="https://user-images.githubusercontent.com/38832025/235781424-06d81647-b3db-4d9b-94dc-cd65cdf09145.png?raw=true" />
</p>

<p align="center">
A YouTube Music iOS tweak with bilingual lyrics, on-device translation, and real-time scrobbling.
</p>

## Features

- **Bilingual lyrics** — original and translation shown line by line, pulled from multiple lyrics sources automatically
- **Translation** — bring your own LLM key (Anthropic / Gemini / OpenAI-compatible) or use Google Translate
- **Scrobbling** — real-time Last.fm and ListenBrainz with an offline queue
- Plus the usual basics: ad removal, background playback, audio downloads, SponsorBlock, seek buttons, playback rate

## Screenshots

> _WIP._

## Build

Sideloaded IPA (needs [Theos](https://theos.dev/) + [`cyan`](https://github.com/asdfzxcvbn/pyzule-rw)):

```sh
scripts/build_sideload_ipa.sh <decrypted_ytm.ipa>
```

Or build a `.deb` with `make clean package` (`ROOTLESS=1` / `ROOTHIDE=1` as needed). You supply your own decrypted YouTube Music `.ipa`.

## Acknowledgements

- [YTMusicUltimate](https://github.com/ginsudev/YTMusicUltimate) — the base tweak this is built on (GPL-3.0)
- [SponsorBlock](https://sponsor.ajay.app/) — segment-skip data
- [LRCLIB](https://lrclib.net/), [NetEase Cloud Music](https://music.163.com/), Genius, Musixmatch — lyrics sources
- [Last.fm](https://last.fm/api/) · [ListenBrainz](https://listenbrainz.org/) — scrobbling
- [mobile-ffmpeg](https://github.com/tanersener/mobile-ffmpeg), [MBProgressHUD](https://github.com/jdg/MBProgressHUD) — bundled libraries

## License

GPL-3.0. See [LICENSE](LICENSE).

Not affiliated with YouTube or Google LLC. "YouTube" and "YouTube Music" are trademarks of Google LLC.
