# KNOCK

**Your money. One conversation.**

KNOCK is a conversational fintech app for Nigeria. You see familiar actions (buy and sell crypto, buy and sell gift cards, pay bills) and finish them through a conversation with the KNOCK assistant. The assistant fills in details and fetches a quote. Pricing, verification, authorisation and settlement happen on KNOCK's servers, and nothing moves until you confirm on your device.

This repository is the **interactive prototype**, built with Flutter so one codebase ships to **Android and iOS**. Every service is a mock and every number is sample data, labelled "MOCK" in the UI.

## Get the Android APK

Every push to a `claude/**` branch or `main` runs [`.github/workflows/android-apk.yml`](.github/workflows/android-apk.yml), which analyses, tests and builds two APKs:

| File | Use |
| --- | --- |
| `knock-prototype.apk` | Release-mode build signed with the debug key. Smooth, use this for demos. |
| `knock-prototype-debug.apk` | Debug build. Slower; for development. |

Download them from the repository's **Releases** page (pre-release named `prototype-<branch>`) or from the workflow run's **Artifacts**. On the phone, allow "Install unknown apps" for your browser or file manager.

**Prototype PIN:** any 4 digits except `0000`.

## Run locally

```bash
flutter pub get
flutter run            # Android device/emulator or iOS simulator
flutter test
flutter analyze
```

Requires Flutter 3.50 (stable). iOS needs Xcode on a Mac: `flutter build ios --no-codesign` compiles it; the workflow has a manual `ios-compile-check` job.

## What's in the prototype

- **Lock screen**: biometrics (Face ID / fingerprint via `local_auth`) with PIN fallback; auto-lock after 2 minutes in the background.
- **Home**: greeting, search, notifications, portfolio total with NGN/USD switch, hide-balances toggle, performance chart (1D/1W/1M/1Y), quick actions (Deposit, Withdraw, Bills, Ask KNOCK), four trade cards, separate Crypto / Naira / Dollar card balances, asset list.
- **KNOCK assistant**: understands requests like "buy ₦100,000 worth of USDT" or "sell my Apple gift card", asks only for what's missing (with tap-to-answer chips), shows a server quote card with expiry countdown, confirms through a native authorisation sheet, posts a receipt. After a crypto purchase it offers airtime, data or a bill payment, and does nothing unless you say yes. Gift card sales ask for a photo, show the recognised card, then quote.
- **Bills** (airtime, data, electricity, cable) run through the assistant.
- **Gift cards**: dedicated Buy and Sell screens (brand, region/type, photo, value, quote, confirm).
- **Wallet**: Naira wallet, crypto and dollar card as three separate ledgers; asset detail with chart and buy/sell.
- **Activity**: filters, grouped by day, detail sheet with an append-only audit trail.
- **Dollar card**: visible but locked. Card preview is blurred with no card details, "Coming soon", planned features, early-access opt-in.
- **Profile**: verification tier and limits, security settings, preferences, prototype controls (simulate network errors, reset sample data).

## Project layout

```
lib/
  app/            App root, dependency container (AppServices) and AppScope
  core/           Money (integer minor units), formatting, amount parsing
  design/         Tokens (colours, type, spacing), theme, reusable widgets
  models/         Assets, ledgers, quotes, chat, catalogues
  services/
    contracts.dart      Provider-agnostic interfaces the UI depends on
    intent_parser.dart  Rule-based stand-in for the AI intent service
    mock/               Mock backend and mock service implementations
    security/           Keychain/Keystore wrapper, biometric authoriser, API client rules
  state/          Session, wallet, shell and assistant controllers
  features/       One folder per screen area
assets/brand/     Logo mark (supplied) and recoloured variants
docs/             Architecture and security notes
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how this connects to a real backend.

## Design

Dark-first, style direction taken from the supplied Dribbble reference ("Crypto Wallet & Portfolio Mobile App UI Design"). KNOCK green `#00B03C` replaces the reference's lime highlights; orange `#FF5001` is a sparing accent. The hero keeps a muted violet gradient that warms into orange.

Open questions, marked `[Guess]` in code:

- Hero gradient: violet-to-orange (current) or a green-led gradient.
- Wordmark: the supplied wordmark reads "Knocking"; the app shows "KNOCK".
- All rates, fees (1% buy, 0.5% sell), limits (₦5M daily on tier 1) and gift card rates are placeholders.
