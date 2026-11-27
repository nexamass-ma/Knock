# Knock v2: implementation report

Prototype status as of 27 November 2026. Branch `claude/project-thread-l4evqa`. Nothing is live: the app runs against an in-process **sandbox backend** and no real money, cards, banks or messages are involved.

## 1. Completed features

**Positioning and brand.** "Your money moves when you do." International English throughout. "Hey Chief!" is used for rate updates and can be turned off in Settings → Notifications.

**Auth and onboarding**
- Welcome ("Money moves. Make yours count.") with Create Account and Log In.
- Sign up with a password strength meter and links to the terms.
- Email verification with resend countdown and change email.
- Phone verification.
- Personalise (country, currency, marketing consent).
- Forgot password, two-step login, and a lock screen (PIN, or biometrics where supported).
- Skippable welcome guide and dashboard tour. Guide toggle and "replay guide" in Settings.

**Home: one account.** Following Chanor's 27 November feedback there is a single balance on Home and no separate Wallet tab.
- Balance with hide/show, deposit and withdraw.
- Incoming, bonus and crypto value shown as tags under the balance.
- Buy and sell shortcuts, Current Rates, verification nudge, quick actions.
- Welcome bonus card, Fire Load promotions, invite card, services grid, live feed, recent transactions.
- No line graph and no crypto rates.
- The bell's unread dot appears only when there are real unread notifications.

**Navigation**
- Bottom tabs: Home, Trade, Gifts, History.
- Drawer with the 20 spec items, plus Payment Links.
- One-tap paths: Transaction → Report a problem; Home → Invite → Share.

**Trading**
- Sell gift cards: brand, currency, type, amount, live estimate, upload or e-code, review.
- Live rate-change notice during review:
  - Up: "Hey Chief! Good news. Your rate just went up!"
  - Down: "Hey Chief! Your rate just changed."
  - Shows old and new rate, old and new payout, and the difference, with Continue with New Rate or Cancel Trade.
  - Locked and indicative rates are enforced by the backend.
- Rate explorer, Rate Watchlist with targets, and drafts that are saved and restored.
- Trade Tracker with 9 statuses. "Action required" has a direct action button.
- Crypto buy and sell with 30-second quotes, plus a receive address.

**Gift Send**
- Send to a username, phone, email or claim link.
- Recipient gets "🎁 You've received a gift!" with Open My Gift and an animated opening.
- The code is revealed only after PIN confirmation.
- Recipients can redeem, trade on Knock, or forward (only for brands that allow it).
- Senders see a status timeline. Unclaimed links are refunded after 30 days.
- My Gifts has filters, search and claim by link.

**Services**
- Airtime, data, electricity (token delivered) and cable.
- Betting, which needs Tier 2 and an 18+ confirmation.
- E-pins, revealed with PIN.
- eSIM: countries, packages, install steps and order history.

**History**
- Filters: All, Successful, Pending, Failed and Reversed, plus type and search.
- Full transaction details.
- PDF receipt you can download or share.
- Dispute Centre with tracked cases.

**Rewards and growth**
- Welcome bonus of ₦100:
  - Paid after the first settled trade.
  - Fraud-checked and reversed if the trade is reversed.
  - Paid to the bonus balance, which cannot be withdrawn.
- Referrals of ₦5,000 once a friend passes $500 of settled volume:
  - Stats dashboard and a detail page with a masked email.
  - Referral terms page.
  - Self-referral is blocked.
- Leaderboard:
  - Boards: traders, referrers and volume.
  - Periods: weekly, monthly and all time.
  - Your own rank always shows.
- Knockout challenges and badges.
- Fire Load: real countdowns, eligibility, progress, claim button and history.
- VIP levels: Silver, Gold and Black.

**Notifications.** Notification centre with category filters, mark read, mark all read and deep links. Preferences let you control each category. Transaction and security notices are always on.

**Support**
- Call and WhatsApp on +44 7575 895007.
- Tickets with replies and status tracking.
- FAQ: a searchable accordion covering all 14 spec categories.
- Licensed support photo, used only in support areas and credited in Settings → Credits.

**Settings**
- Profile, photo, username, email change (with a 24-hour withdrawal hold) and phone change.
- Password, PIN, two-step verification and biometrics.
- Devices and sessions.
- Notifications, privacy, language and currency.
- Guide toggle, terms, privacy policy, credits and logout.
- **Delete account** (under Settings → Account):
  - Red button.
  - Shows consequences, blockers and the records we must keep.
  - Needs your password, the word DELETE typed in, and an acknowledgement.
  - The request is tracked with a 14-day cooling-off period and can be cancelled.

**Coming Soon.** USA Account and Knock AI pages, each with Notify Me and recorded consent. Knock AI shows suggested prompts and cannot move money.

**Payment Links and Smart Split.** Merged from the Payment Links branch and reachable from the drawer.

**Security in the sandbox backend**
- Role-based access: separate customer and ops roles.
- Rate limiting and fraud checks.
- Idempotency keys and replay protection (nonce and timestamp).
- Signed webhooks.
- Double-entry ledger in kobo, with a reconciliation endpoint.
- Audit log, session management, and sealed gift codes and e-pins.
- BVN and NIN are never stored raw; only a keyed fingerprint and the last 4 digits are kept.
- Verification tiers only change after a successful check.

**Tests (51 passing)**
- Backend acceptance tests.
- Payment Links tests.
- Widget tests for:
  - Sign up.
  - Onboarding skip.
  - Rate change accept and cancel.
  - Settings saves.
  - Account deletion.

## 2. Features needing credentials

| Area | Needs |
|---|---|
| Naira accounts, deposits, withdrawals | **9PSB** API credentials and a webhook secret (Chanor confirmed 9PSB as the partner) |
| Gift card liquidity and verification | Trading partner API (Breet or similar) |
| Crypto custody, quotes, addresses | Custody/liquidity partner API |
| Gift Send codes | Gift card supplier API |
| Airtime, data, bills, betting, e-pins, eSIM | Bills aggregator and eSIM provider APIs |
| BVN, NIN, bank account name lookup | Licensed KYC provider (e.g. via 9PSB or a KYC vendor) |
| Email and SMS codes | Email service and SMS gateway keys |
| Push notifications | Firebase Cloud Messaging / APNs |
| Payment Links | Supabase project and payment provider keys |
| Android release signing | Upload keystore (APKs are debug-signed today) |

## 3. Features in sandbox mode

- Everything that moves money or calls a provider runs in sandbox mode:
  - Deposits use "Simulate a transfer" into a 9PSB-labelled sandbox account.
  - Trades auto-approve after a short delay.
  - Codes go to an in-app Test inbox.
- **No admin in the customer app** (Chanor's rule). Staff work such as trade review, reversals, reward release, deletions, reconciliation and the audit log is not in the app. It runs on the backend and belongs in the separate admin app.
- Debug builds only have Settings → Developer tools: the test inbox, moving a rate (to see the rate-change notice), sending a test gift, simulating offline and resetting the sandbox. These tools are not in the release APK.
- Seeded community users (labelled "Sandbox user") populate the leaderboard and feed.
- Referral reward hold is 1 minute in the sandbox and 7 days in production.

## 4. Features awaiting approval

- Production launch of money services needs the partner agreements and regulatory clearance (CBN licensing via partners, SEC for crypto).
- Betting funding needs a licensed betting partner and age-verification policy sign-off.
- USA Account needs a US banking partner.
- Knock AI needs a product and compliance decision before it can give account-specific answers.
- Reward economics: the welcome bonus, referral amounts, VIP benefits and Fire Load budgets are placeholders to confirm.
- Legal copy (terms, privacy, referral terms) is placeholder text that needs a lawyer's review.

## 5. Limitations

- **Sandbox only.** Data lives on the device and is wiped by Reset or by reinstalling.
- **Only one sign-in at a time.** Several devices cannot share one account.
- **Notifications are in-app only.** There is no real push, email or SMS yet.
- **Biometrics** depend on the device. If the device does not support them, the toggle is allowed for testing only.
- **Photo uploads are stored by filename only.** Nothing is sent to a server.
- **Languages.** Only English (UK) is available. Pidgin, Yoruba, Hausa and Igbo are listed as planned.
- **My interpretation choices:**
  - Knock AI and the USA Account replace the old assistant and the Dollar card.
  - Knock Points have no cash value.
  - Biometrics unlock the app, but payments still need the PIN.
  - New accounts start at ₦0.
  - The drawer has 21 items: the spec's 20 plus Payment Links.

## 6. Production requirements

1. A real backend service that implements the same API as `lib/sandbox`.
   - Each sandbox endpoint maps 1:1 to an HTTPS route.
   - Replacing `KnockApi._invoke` with HTTPS is the only client change.
2. A managed Postgres double-entry ledger, with daily reconciliation against 9PSB statements.
3. Provider integrations:
   - All providers in section 2, with signed webhooks and idempotent processing.
4. Secrets and keys:
   - A secrets manager for provider keys.
   - A KMS for sealing gift codes and e-pins and for the BVN/NIN fingerprint key.
5. Back-office tools for operations staff:
   - Trade review, disputes, KYC review, reward approval, deletions and audit.
   - Role-based access with two-person approval for reversals.
6. Push notifications, a transactional email domain and an SMS sender ID.
7. App release:
   - Play Store signing, privacy labels and an age rating.
   - An iOS build through App Store Connect.
8. Monitoring, alerting, rate limits at the edge, and a penetration test before launch.
9. Compliance:
   - AML/KYC policies, a data-protection impact assessment under NDPA, and record retention.
   - Retention is 5 years for transactions and verification results.
