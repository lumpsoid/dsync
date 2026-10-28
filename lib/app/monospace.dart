/// A monospace face on every platform the app ships to: pair it with
/// `fontFamily: 'monospace'`.
///
/// `monospace` is a generic alias, not a font: Android and Linux's
/// fontconfig resolve it, Windows and macOS do not, and columns only align
/// in a fixed-pitch face. So the fallbacks name one font each platform is
/// known to carry — Menlo (macOS and iOS), Consolas (Windows), DejaVu Sans
/// Mono (the Linux default, should the alias be unset) — with Courier New
/// last, present on both Windows and macOS.
///
/// Lives in `app/` because two features set text in it — the run's timings
/// report and the file diff — and one list is one answer to "which fonts
/// are fixed-pitch here".
const monospaceFallback = [
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'Courier New',
];
