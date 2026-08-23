# AGENTS.md

## Project Shape

- This is a Theos Objective-C/Logos iOS tweak for YouTube Music, not an Xcode or Node project.
- The tweak target is `YTMusicUltimate`; `YTMusicUltimate.plist` injects only into `com.google.ios.youtubemusic`.
- `Makefile` compiles every `Source/**/*.x`, `Source/**/*.xm`, and `Source/**/*.m` except `Source/Sideloading.x`; `Source/Sideloading.x` is added only when `SIDELOADING=1`.
- Resource/localization files are packaged from `layout/Library/Application Support/YTMusicUltimate.bundle`; user-facing strings should use `LOC(@"KEY")` (or one of the per-module `*Localized(@"KEY", @"fallback")` wrappers in the lyrics code) and have a matching `Localizable.strings` entry in every `.lproj`. The wrappers carry an inline English fallback — when adding a key, update both the fallback and the `.strings` files. After editing, all 14 locales should have identical key sets; sanity-check with `plutil -lint layout/Library/Application\ Support/YTMusicUltimate.bundle/*.lproj/Localizable.strings`.

## Localization (i18n)

- A new user-facing key must ship with a real translation in every `.lproj`. Do **not** paste the English string into non-English `.strings` files as a placeholder: it is indistinguishable from a finished translation in diffs, `grep`, and `plutil -lint`, so the gap silently survives review (this is exactly how `TRANSLATION_FOLLOW_APP_LANG` landed in 11 locales as "Follow app language"). If a translation isn't ready, the key isn't ready — either translate it now, or leave the key out of that locale entirely so the fallback paths below take over.
- Fallback is per-call-site, not magic. iOS does **not** fall back from a non-English `.lproj` to `en.lproj` on a per-key miss; it only falls back at the whole-`.lproj` level when the user's locale has no folder at all. So a key missing from a present `.lproj` behaves like this:
  - `LOC(@"KEY")` — `value:nil`, returns the **literal key** in the UI. Loud, easy to spot during QA.
  - `YTMULocalized(@"KEY", @"English fallback")` and per-module wrappers — return the **inline fallback**. Silent, so keep that fallback string in sync with `en.lproj`.
- Pasting the English string into, say, `de.lproj` defeats both signals: `LOC()` no longer surfaces the literal key, and reviewers/grep can't distinguish a real "Folgen" from a placeholder. Reserve English values for `en.lproj` only.
- After editing localization files, verify parity, not just lint validity: `plutil -lint …/*.lproj/Localizable.strings` must pass, and the key set must match across all 14 files. Quick check — `for f in layout/Library/Application\ Support/YTMusicUltimate.bundle/*.lproj/Localizable.strings; do awk -F'"' '/^"[A-Z]/{print $2}' "$f" | sort -u | wc -l; done | sort -u` should print a single number.

## Build Commands

- Rootful deb: `make clean package`
- Rootless deb: `make clean package ROOTLESS=1`
- Roothide deb: `make clean package ROOTHIDE=1`
- Sideloading deb: `make clean package SIDELOADING=1 FINALPACKAGE=1`
- Local IPA injection: `THEOS=/path/to/theos scripts/build_sideload_ipa.sh <decrypted.ipa> [output.ipa] [display-name] [bundle-id]`
- `scripts/build_sideload_ipa.sh` requires `cyan`; install with `brew install pipx` then `pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip`.
- The local IPA script defaults `THEOS` to `$HOME/theos`; pass `THEOS=/path/to/theos` unless that path exists.

## Toolchain Notes

- The Theos target is `iphone:clang:16.5:13.0`, `ARCHS = arm64`, and `INSTALL_TARGET_PROCESSES = YouTubeMusic`.
- CI installs GNU make, `ldid`, `pipx`, checks out Theos at commit `344ee5925df036dbd1312b783ad5a00d153c2445`, and uses `iPhoneOS16.5.sdk`.
- There is no lint, formatter, or typecheck config; the two verification gates are a successful Theos build for the packaging mode affected and the host test suite below.
- `Tests/Host/run.sh` compiles `Source/{Lyrics,Translation,Scrobbling,Utils}` plus `Tests/Host/*.m` into one Mac Catalyst binary (same `-Wall -Werror` as Theos) and runs it inside a real `UIApplication`, so provider parsers, caches, the scrobble queue and UIKit lifecycles are exercised for real on the Mac. It needs `/Applications/Xcode.app` (set `XCODE=` to point elsewhere) and reaches it through `DEVELOPER_DIR` for that one invocation — the system `xcode-select` is left alone. Caches are redirected to a temp dir via `YTMU_CACHES_ROOT` (see `Source/Utils/YTMUPaths.m`) and the test binary's defaults domain is wiped, so runs never touch `~/Library/Caches` or real preferences. Add a test with `YTMU_TEST(name) { … }` in a new `Tests/Host/Test_*.m`; `Tests/Host/YTMUTestHTTPServer` gives you a real local HTTP endpoint and `YTMUTestFakeLLM` a canned LLM. Run it before every commit that touches those directories.
- Generated/build artifacts are intentionally ignored: `.theos/`, `packages/`, `build/`, and `*.ipa`.

## Runtime Architecture

- Feature hooks live as top-level Logos files in `Source/`; preferences UI lives in `Source/Prefs/`.
- Bilingual lyrics flow is centered on `Source/Lyrics/YTMULyricsManager.m`; providers live in `Source/Lyrics/Providers/`; per-line romanization (Google transliteration, batch scheduling, memory cache) is `Source/Lyrics/YTMURomanizationService.m` — its `endpointBaseURL` is how the host tests stand in for Google.
- Translation flow is centered on `Source/Translation/YTMUTranslator.m`; providers are Google Translate, Anthropic, Gemini, and OpenAI-compatible.
- Settings are stored in the `NSUserDefaults` dictionary key `YTMUltimate`; translation/lyrics settings changes post `YTMULyricsSettingsDidChangeNotification`.
- Translation cache keys include `YTMUTranslationStrategyVersion` from `Source/Translation/YTMUTranslationTypes.m`; bump it when changing cache-incompatible translation behavior. The lyrics layer has a parallel `YTMUInnerTubeSchemaVersion` (in `Source/Lyrics/YTMUInnerTubeDescriptionFetcher.m`) for the on-disk InnerTube description / blacklist cache — bump it when changing that plist's shape.
- New lyrics providers should plug into the `YTMULyricsProvider` protocol and cap every individual HTTP request at ~8 s via `request.timeoutInterval`; the manager fans out providers in parallel and relies on each one self-bounding so a slow CDN can't stall the chain.

## Directory Map

- `Source/*.x` and `Source/*.xm` are injected app hooks; each file generally owns one tweak feature such as ads, playback, tabs, or settings entry.
- `Source/Headers/` contains private YouTube Music interface declarations used by hooks; update these when hook signatures drift with app versions.
- `Source/Prefs/` builds the in-app YTMusicUltimate settings screens; it writes into the shared `YTMUltimate` defaults dictionary.
- `Source/Lyrics/` owns synced/bilingual lyrics state, caches, parsing, text processing, and provider orchestration — plus the in-app lyrics panel UI (`YTMULyricsTabOverlayView`, `YTMULyricsPanelViewController`, with shared helpers in `YTMULyricsPanelSupport`); `Source/SelectableLyrics.x` contains only the hooks that mount it.
- `Source/Translation/` owns translation requests, prompt construction, provider adapters, and translation cache behavior.
- `Source/Utils/` holds small shared helpers: `YTMUPaths` (one cache root for every on-disk cache), `YTMUDigest` (SHA-1), `YTMUPlistStore` (versioned per-key plist cache), `YTMUInflightCoalescer` (collapse concurrent requests per key), `YTMUConcurrencyLimiter` (bounded async fan-out without blocking a thread), `YTMUWeakProxy` (timer / display-link targets). Reach for these before writing another copy.
- `Source/Utils/lib/` and `Source/Utils/MobileFFmpeg/` are vendored binary/header dependencies used by downloader/FFmpeg code; avoid treating them as normal app source.
- `layout/Library/Application Support/YTMusicUltimate.bundle/` is the packaged tweak bundle for icons and `.lproj/Localizable.strings` files.
- `Resources/` is repository/release artwork and depiction metadata, not the runtime localization bundle.
- `scripts/` contains local operational helpers only: sideload IPA build/injection and device log streaming.

## Debugging

- Translation and lyrics logs use `[YTMUTranslation]` and `[YTMULyrics]`; `translationDebugLogs` defaults to enabled.
- Stream device logs with `scripts/watch_translation_logs.sh [filter]`; it requires `libimobiledevice` (`brew install libimobiledevice`) and a trusted USB-connected iPhone.
- For sideloaded builds, login-related bundle ID/keychain workarounds are in `Source/Sideloading.x`; do not expect them in normal jailbreak deb builds.
