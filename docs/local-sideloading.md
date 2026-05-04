# Local Sideloading Build

This repo can build a jailed/sideloaded IPA locally, without GitHub Actions.

## Build

```sh
scripts/build_sideload_ipa.sh "_YouTube Music_v9.17-AppAssassin.ipa" \
  "build/ipa/YTMusicUltimate-Bilingual.ipa" \
  "YTMusic Bilingual" \
  "com.py233.ytmusicultimate.bilingual"
```

The script runs `make clean package SIDELOADING=1 FINALPACKAGE=1`, then injects the
resulting deb into the decrypted IPA with `cyan`.

## Logs

Translation diagnostics use this prefix:

```text
[YTMUTranslation]
```

Filter for that prefix in the macOS Console app, or from a terminal with an
attached device:

```sh
scripts/watch_translation_logs.sh
```

The logs intentionally avoid API keys and full lyrics. They include provider,
model, target language, video id, line counts, cache hit/miss, and stale-result
drops.

If the helper reports that no device is found, plug the iPhone into the Mac,
unlock it, tap Trust on both sides if prompted, then check that the device is
visible:

```sh
idevice_id -l
```
