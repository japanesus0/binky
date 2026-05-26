# Binky — Play Store Listing Copy

Everything you'll need to paste into Google Play Console when filing v1.0.0.
Tweak voice/details before submitting; nothing here is locked.

---

## App identity

| Field | Value |
|---|---|
| **App name** (30 char max) | `Binky` |
| **Default language** | English (United States) |
| **Application type** | App |
| **Category** | **Health & Fitness** *(recommended — daily volume tracking fits this)*. Alternative: **Lifestyle**. |
| **Tags** | hydration, drink tracker, tea timer, coffee timer (Play surfaces these in browse/search) |

---

## Short description (80 char max)

`Track what you drink. Time your brews. No accounts, no ads, no tracking.`

— 73 characters. Reads as one clear sentence. Alternates if you want a different angle:

- `Beverage log + brew timer. 100% offline, no ads, no data collected.`  *(67 chars)*
- `Log every cup. Time every brew. Stays on your phone — no internet needed.`  *(73 chars)*

---

## Full description (4000 char max)

```
Binky is a beverage tracker and brew timer that stays out of your way. Log every cup of tea, coffee, water, or whatever you drink. When you're brewing, get a proper timer with background notifications so you don't forget the kettle.

WHAT IT DOES

• Log what you drink
  – A short list of beverages, customizable to your habits
  – One tap to record a default pour
  – Long-press for instant "I just had this" logging
  – Daily and weekly volume totals with a 7-day bar chart
  – Edit or delete any past entry
  – Export your full log to CSV anytime

• Brew timer that actually works
  – Per-drink brew presets (3 / 5 / 7 min, or whatever you set)
  – "Kettle Time" — a separate prep timer for when the water's heating
  – Custom brew duration via slider
  – Live MM:SS countdown right in the notification shade
  – Alarm fires the moment the brew is done — even if you backgrounded the app, swiped it from recents, or moved on to something else
  – Tap the notification to jump straight back to the timer

• Make it yours
  – Add, edit, and remove drinks freely
  – Light, dark, or follow-system theme
  – Adjustable default kettle time

WHAT THIS APP WON'T DO

• No account. No sign-up. No login.
• No internet connection of any kind — the app does not request the INTERNET permission, so it literally cannot phone home.
• No ads. Ever.
• No analytics. No telemetry. No crash reporting collected by us.
• No advertising IDs, no device fingerprinting.

Everything you log lives on your device, and only your device. Uninstall the app and it goes with it. Export your data as CSV first if you want to keep it.

PERMISSIONS USED

• Notifications — for the brew alarm and the live countdown
• Exact alarms — so the alarm fires at the precise scheduled time
• Vibration — haptic feedback when a brew is done

That's the full list. No location, no contacts, no files, no microphone, no camera, nothing else.

FREE

Binky is free, with no in-app purchases and no premium tier. You get the whole app, every feature, no strings.
```

That's ~1,950 characters. Plenty of headroom inside the 4,000 char limit.

---

## What's new — release notes for v1.0.0 (500 char max)

```
First release.

A beverage tracker and brew timer that stays local. Log what you drink, time your tea and coffee, get notified when the brew is done. No ads, no tracking, no internet permission.
```

— ~210 chars.

---

## Data safety form

Google walks you through a questionnaire. Answer as follows:

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | **N/A** (no data is collected) |
| Do you provide a way for users to request that their data be deleted? | **Yes** — uninstalling the app deletes all local data; CSV export gives a copy. |

Once you answer "No" to the first question the form mostly ends.

---

## Content rating questionnaire

All answers are **No**:

- Violence / blood / gore: **No**
- Sex / nudity: **No**
- Profanity: **No**
- Controlled substances (alcohol, tobacco, drugs): **No** *(caffeine doesn't count)*
- Gambling / simulated gambling: **No**
- User-generated content / chat / social: **No**
- Shares user location with other users: **No**
- Allows real-money transactions: **No**
- Allows users to interact: **No**

Expected outcome: **ESRB: Everyone · PEGI 3 · IARC: All ages**.

---

## Target audience and content

| Field | Value |
|---|---|
| Target age groups | 13+ (or "Everyone"; pick the broader option if available) |
| Designed primarily for children? | **No** |
| Appeals to children? | **No** |

---

## Required graphics assets

Play Console rejects submissions missing these. Sizes are strict.

| Asset | Required? | Size | Notes |
|---|---|---|---|
| **App icon** | Required | 512×512 PNG (32-bit, with alpha) | Regenerate from `assets/icon.png` — open in any image editor and resize. Or use the same coffee-brown `B` placeholder. |
| **Feature graphic** | Required | 1024×500 PNG/JPG | The banner above the listing. Coffee-brown rectangle with "Binky" centered works fine as a placeholder. |
| **Phone screenshots** | At least 2 (max 8) | min 320 px, max 3840 px, 16:9 to 9:16 | Take from a real device or the emulator. |
| **7" tablet** | Optional | 1024×600 (or similar) | Skip — Play accepts phone-only listings. |
| **10" tablet** | Optional | 1280×800 (or similar) | Skip. |

**Recommended screenshots to capture, in order:**

1. **Home screen** with the drink list and the active-brew banner visible (start a brew first, then screenshot home — sells the "background timer" feature).
2. **Drink detail** with brew chips and the Custom slider visible.
3. **Brew timer** mid-countdown, showing the circular progress + millisecond display.
4. **Summary** showing the weekly bar chart and a few days of breakdown.
5. **Settings** showing theme radio and kettle slider.
6. *(optional)* **History** with a few entries.

For each, use `flutter screenshot` while connected to a device, or just press the camera button in the emulator toolbar.

---

## Privacy policy URL

Required field on the listing. Host [PRIVACY_POLICY.md](PRIVACY_POLICY.md) anywhere public — easiest options:

- **GitHub Pages**: push the repo to GitHub, enable Pages on `main`, point Play to `https://<user>.github.io/binky/PRIVACY_POLICY.html` (rename the file to `.html` or use a Jekyll theme).
- **GitHub Gist**: paste the markdown into a public gist, use the gist's "Raw" URL.
- **Any static host** (Netlify drop, S3 bucket, etc.) works the same.

Before publishing, replace the line `For questions about this policy, contact: _your email address here_` with a real email.

---

## Contact details

Required on the developer profile, not the listing itself.

- **Email** — must be reachable; Play uses it for policy notices. Pick one you check.
- **Website** — optional. If you want one, the same URL hosting the privacy policy is fine.
- **Phone number** — optional.

---

## Release track strategy

1. **Internal testing** — invite yourself (your Google account) as the only tester. Upload AAB. Install on a real device via the Play Store opt-in link. Run the testing checklist. Fix anything broken, bump `versionCode` to 2, re-upload.
2. **Closed testing** — *(optional)* invite a handful of friends if you want outside eyes before going public.
3. **Production** — when you're confident. Manual rollout at 5% → 50% → 100% gives you a chance to halt if reviews start coming in bad.

You don't need to use every track; Internal → Production is fine.

---

## Pre-submission self-check

Before hitting "Submit for review":

- [ ] AAB built with the **real keystore**, not debug
- [ ] `versionCode` is greater than any prior upload (Play rejects duplicates)
- [ ] Privacy policy URL is publicly reachable (open in incognito to verify)
- [ ] Screenshots are real, not placeholders
- [ ] Short + long descriptions read cleanly
- [ ] App icon and feature graphic uploaded
- [ ] Content rating questionnaire submitted
- [ ] Data safety form submitted
- [ ] Target audience set
- [ ] App content / news app declarations done (yours: not a news app)
- [ ] At least one country selected in the distribution list

Initial review typically takes 1–7 days for a first-time app. Subsequent updates are often hours.
