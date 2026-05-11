# AGENTS.md

## Project Shape

- This is a Theos Objective-C/Logos iOS tweak for YouTube Music, not an Xcode or Node project.
- The tweak target is `YTMusicUltimate`; `YTMusicUltimate.plist` injects only into `com.google.ios.youtubemusic`.
- `Makefile` compiles every `Source/**/*.x`, `Source/**/*.xm`, and `Source/**/*.m` except `Source/Sideloading.x`; `Source/Sideloading.x` is added only when `SIDELOADING=1`.
- Resource/localization files are packaged from `layout/Library/Application Support/YTMusicUltimate.bundle`; user-facing strings should use `LOC(@"KEY")` (or one of the per-module `*Localized(@"KEY", @"fallback")` wrappers in the lyrics code) and have a matching `Localizable.strings` entry in every `.lproj`. The wrappers carry an inline English fallback — when adding a key, update both the fallback and the `.strings` files. After editing, all 14 locales should have identical key sets; sanity-check with `plutil -lint layout/Library/Application\ Support/YTMusicUltimate.bundle/*.lproj/Localizable.strings`.

## Build Commands

- Rootful deb: `make clean package`
- Rootless deb: `make clean package ROOTLESS=1`
- Roothide deb: `make clean package ROOTHIDE=1`
- Sideloading deb: `make clean package SIDELOADING=1 FINALPACKAGE=1`
- Local IPA injection: `THEOS=/path/to/theos scripts/build_sideload_ipa.sh <decrypted.ipa> [output.ipa] [display-name] [bundle-id]`
- `scripts/build_sideload_ipa.sh` requires `cyan`; install with `brew install pipx` then `pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip`.
- The local IPA script defaults `THEOS` to `/Users/py_23/theos`; pass `THEOS=/path/to/theos` unless that path exists.

## Toolchain Notes

- The Theos target is `iphone:clang:16.5:13.0`, `ARCHS = arm64`, and `INSTALL_TARGET_PROCESSES = YouTubeMusic`.
- CI installs GNU make, `ldid`, `pipx`, checks out Theos at commit `344ee5925df036dbd1312b783ad5a00d153c2445`, and uses `iPhoneOS16.5.sdk`.
- There is no repo-local test, lint, formatter, or typecheck config; verification is a successful Theos build for the packaging mode affected.
- Generated/build artifacts are intentionally ignored: `.theos/`, `packages/`, `build/`, and `*.ipa`.

## Runtime Architecture

- Feature hooks live as top-level Logos files in `Source/`; preferences UI lives in `Source/Prefs/`.
- Bilingual lyrics flow is centered on `Source/Lyrics/YTMULyricsManager.m`; providers live in `Source/Lyrics/Providers/`.
- Translation flow is centered on `Source/Translation/YTMUTranslator.m`; providers are Google Translate, Anthropic, Gemini, and OpenAI-compatible.
- Settings are stored in the `NSUserDefaults` dictionary key `YTMUltimate`; translation/lyrics settings changes post `YTMULyricsSettingsDidChangeNotification`.
- Translation cache keys include `YTMUTranslationStrategyVersion` from `Source/Translation/YTMUTranslationTypes.m`; bump it when changing cache-incompatible translation behavior. The lyrics layer has a parallel `YTMUInnerTubeSchemaVersion` (in `Source/Lyrics/YTMUInnerTubeDescriptionFetcher.m`) for the on-disk InnerTube description / blacklist cache — bump it when changing that plist's shape.
- New lyrics providers should plug into the `YTMULyricsProvider` protocol and cap every individual HTTP request at ~8 s via `request.timeoutInterval`; the manager fans out providers in parallel and relies on each one self-bounding so a slow CDN can't stall the chain.

## Directory Map

- `Source/*.x` and `Source/*.xm` are injected app hooks; each file generally owns one tweak feature such as ads, playback, tabs, or settings entry.
- `Source/Headers/` contains private YouTube Music interface declarations used by hooks; update these when hook signatures drift with app versions.
- `Source/Prefs/` builds the in-app YTMusicUltimate settings screens; it writes into the shared `YTMUltimate` defaults dictionary.
- `Source/Lyrics/` owns synced/bilingual lyrics state, caches, parsing, text processing, and provider orchestration.
- `Source/Translation/` owns translation requests, prompt construction, provider adapters, and translation cache behavior.
- `Source/Utils/lib/` and `Source/Utils/MobileFFmpeg/` are vendored binary/header dependencies used by downloader/FFmpeg code; avoid treating them as normal app source.
- `layout/Library/Application Support/YTMusicUltimate.bundle/` is the packaged tweak bundle for icons and `.lproj/Localizable.strings` files.
- `Resources/` is repository/release artwork and depiction metadata, not the runtime localization bundle.
- `scripts/` contains local operational helpers only: sideload IPA build/injection and device log streaming.

## Debugging

- Translation and lyrics logs use `[YTMUTranslation]` and `[YTMULyrics]`; `translationDebugLogs` defaults to enabled.
- Stream device logs with `scripts/watch_translation_logs.sh [filter]`; it requires `libimobiledevice` (`brew install libimobiledevice`) and a trusted USB-connected iPhone.
- For sideloaded builds, login-related bundle ID/keychain workarounds are in `Source/Sideloading.x`; do not expect them in normal jailbreak deb builds.
