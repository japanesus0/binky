# binky — Style Guide

A reference for designers producing graphics for binky. Every color in the in-app UI, marketing assets, and brand collateral is sourced from this file.

> **Caveats.** Pantone matches are approximations from the closest Pantone Solid Coated swatches — Pantone is a proprietary color system primarily for print, and digital-to-print conversion is never exact. Verify with Pantone Connect or physical chips before any printed asset gets produced. CIELAB values computed from sRGB → XYZ → Lab using D65 illuminant; rounded to one decimal.

## 1. Core brand palette

These are the colors hard-coded in the binky source. Every other color in the in-app UI is derived from the **Coffee Brown** seed by Flutter's Material 3 algorithm.

| Color | Hex | RGB | Pantone (Solid Coated) | CIELAB (D65) | Used in |
|---|---|---|---|---|---|
| **Coffee Brown** (primary seed) | `#6B4423` | `rgb(107, 68, 35)` | PANTONE 4625 C (close) | L 32.7 / a +13.5 / b +25.6 | App theme seed (`main.dart`), splash background (`_brown`), launcher icon background, foreground service notification accent |
| **Cream** (primary surface) | `#F5E6D3` | `rgb(245, 230, 211)` | PANTONE 7401 C (close) | L 92.1 / a +1.5 / b +11.6 | Splash logo + wordmark fill (`_cream`), AppBar text-on-brown contrast |
| **Cream (icon variant)** | `#F2E5D1` | `rgb(242, 229, 209)` | PANTONE 7401 C (very close) | L 91.6 / a +2.0 / b +12.4 | Bundled launcher icon `b` glyph fill |
| **Cream Dim** (alpha accent) | `#EBDAC6` | `rgb(235, 218, 198)` | PANTONE 4685 C (light side) | L 87.4 / a +2.4 / b +13.2 | Marketing accents (feature graphic taglines, splash quote at reduced opacity) |

## 2. Coffee Brown gradient pair

Used in the feature graphic and the AppBar header background. Endpoints derived FROM the seed but distinct values:

| Color | Hex | RGB | Pantone (Solid Coated) | CIELAB (D65) | Used in |
|---|---|---|---|---|---|
| **Coffee Brown Light** | `#7A502A` | `rgb(122, 80, 42)` | PANTONE 1545 C (close) | L 37.6 / a +14.7 / b +28.4 | Feature graphic top-left gradient origin |
| **Coffee Brown Dark** | `#4E3017` | `rgb(78, 48, 23)` | PANTONE 4695 C (close) | L 23.4 / a +12.9 / b +22.7 | Feature graphic bottom-right gradient destination |

## 3. Functional accents

| Color | Hex | RGB | Pantone (Solid Coated) | CIELAB (D65) | Used in |
|---|---|---|---|---|---|
| **Star Amber** (default-drink) | `#FFC107` | `rgb(255, 193, 7)` | PANTONE 137 C (very close) | L 81.3 / a +8.9 / b +82.5 | Star icon next to default drink in CategoryScreen, DrinksEditor (Flutter `Colors.amber`) |

## 4. Muted UI

| Color | Hex | RGB | Pantone (Solid Coated) | CIELAB (D65) | Used in |
|---|---|---|---|---|---|
| **Subtle Gray** (mono timestamps) | `#888888` | `rgb(136, 136, 136)` | PANTONE Cool Gray 8 C | L 56.8 / a 0 / b 0 | Diagnostics screen timestamp column |

## 5. Material 3 derived colors

The app uses `ColorScheme.fromSeed(seedColor: Color(0xFF6B4423))` for both light and dark themes. Flutter's Material 3 algorithm derives a complete palette from the Coffee Brown seed:

| Light theme role | Approximate hex | Used for |
|---|---|---|
| `primary` | `#8E4F1B` | Action buttons, highlighted chips, the `FilledButton` background |
| `onPrimary` | `#FFFFFF` | Text/icon on primary |
| `primaryContainer` | `#FFDBC8` | The "Brew in progress" banner background on Home |
| `onPrimaryContainer` | `#311300` | Banner text |
| `surface` | `#FFF8F5` | Page backgrounds |
| `surfaceContainerHighest` | `#F4DFD3` | Category header backgrounds in Edit Drinks |
| `error` | `#BA1A1A` | Destructive action UI |
| `errorContainer` | `#FFDAD6` | Swipe-to-delete background |

For the full Material 3 derivation (all 30+ roles, both light and dark variants), feed `#6B4423` into the official **Material Theme Builder** at https://m3.material.io/theme-builder — you'll get exact values for every role. The values above are approximations; the tool gives you spec-perfect values.

## 6. Typography

binky uses Flutter's default font families:

- **Serif** (`fontFamily: 'serif'`) — used for the launcher icon `b`, splash logo, splash wordmark, splash quote. On Android resolves to **Noto Serif** (or system serif). Match in design tools with **Georgia** or **Source Serif Pro** for closest metrics.
- **Sans-serif** (`fontFamily: 'sans-serif'`) — used for the splash bottom quote and the AppBar header tagline (where present). On Android resolves to **Roboto**, the closest commonly-available approximation of Helvetica.
- No custom typeface is bundled in the app.

### Typographic spec for key brand elements

| Element | Font | Size | Weight | Letter spacing | Notes |
|---|---|---|---|---|---|
| Launcher icon `b` glyph | Serif bold | filling icon canvas | Bold | — | See `app/assets/icon.png` and `icon-foreground.png` |
| Splash logo `b` glyph | Serif bold | 120 logical px | Bold | — | Inside the 160dp cream circle |
| Splash wordmark `binky` | Serif bold | 56 sp | Bold | 2 | Beneath the bouncing `b` |
| Splash quote (body) | Sans-serif | 8 sp | Regular | 0.2 | Right-aligned, bottom-pinned, multi-line |
| AppBar header lockup | Bundled image | 40dp tall | — | — | `assets/branding/header.png` |
| Body text (in-app) | System default (Roboto) | per Material 3 type scale | per role | per role | All UI text inherits theme defaults |

## 7. Layout primitives

| Token | Value |
|---|---|
| Splash logo circle diameter | 160dp |
| Gap between circle and wordmark | 36dp |
| Splash horizontal padding for quote | 20dp |
| App body padding | 16dp |
| Standard AppBar height | 56dp (Material 3 default) |
| Header lockup height in AppBar | 40dp (sized via SizedBox) |
| SnackBar standard duration (info) | 2 seconds |
| SnackBar quick-log duration (with Undo) | 3 seconds |
| SnackBar destructive duration (with Undo) | 4 seconds |

## 8. Brand assets

| Asset | Location | Dimensions | Used for |
|---|---|---|---|
| Launcher icon (full) | `app/assets/icon.png` | 1024 × 1024 | Generated by `flutter_launcher_icons` into all mipmap densities |
| Launcher icon (foreground only) | `app/assets/icon-foreground.png` | 1024 × 1024 | Adaptive icon foreground layer |
| AppBar header lockup | `app/assets/branding/header.png` | 800 × 240 | Replaces the plain text title on the Home screen |
| Feature graphic (Play Store) | `feature_graphic.png` (repo root) | 1024 × 500 | Play Console store listing |
| Bundled brew sound | `app/assets/sounds/brew_complete.wav` | 44.1 kHz / 16-bit / mono / 0.76 sec | Played at brew completion |

## 9. Modifying the palette

The Coffee Brown seed lives in `app/lib/main.dart` as `const Color(0xFF6B4423)`. Changing this single value cascades through the entire Material 3 color scheme. The splash uses two separate constants (`_brown` and `_cream`) at the top of `app/lib/splash_screen.dart` — those are independent of the theme and should be updated separately if the brand palette shifts.

Anyone proposing a brand-color change should:

1. Update the seed in `main.dart`
2. Update `_brown` and `_cream` in `splash_screen.dart` to match
3. Regenerate the launcher icon source PNGs with the new palette
4. Regenerate the AppBar header asset
5. Update this style guide
