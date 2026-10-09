#!/usr/bin/env bash
# Capture the visual assets used by README.md.
#
# The README hero and stills are generated from the HTML design studies under
# app/docs/plans/ so the marketing images stay traceable to the approved
# designs instead of being hand-maintained binaries.
#
# Method: each source mockup is copied to a temp file with an injected
# stylesheet that hides every element except one target, pins that target to
# the viewport origin, drops the study's own annotation labels, and freezes
# animations. A first pass dumps the DOM to measure the target; a second pass
# screenshots the window at that size. Both passes share the same stylesheet,
# so a measured size always matches the captured size.
#
# Usage:
#   ./scripts/capture-readme-visuals.sh            # capture everything
#   ./scripts/capture-readme-visuals.sh --measure  # print target sizes only
#
# Env overrides:
#   CHROME_BIN   path to a Chrome / chrome-headless-shell binary
#   OUT_DIR      output directory (default: assets/readme)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/assets/readme}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kalam-readme-capture.XXXXXX")"

INDICATOR_SRC="$REPO_ROOT/app/docs/plans/kalam-indicator-v1/index.html"
ONBOARDING_SRC="$REPO_ROOT/app/docs/plans/kalam-onboarding-v3.2/kalam-onboarding-v3.2.html"
SETTINGS_SRC="$REPO_ROOT/app/docs/plans/kalam-compass-1.7/kalam-compass-v1.7.html"

if [[ -z "${KEEP_WORK:-}" ]]; then
  trap 'rm -rf "$WORK_DIR"' EXIT
else
  echo "KEEP_WORK: $WORK_DIR"
fi

# --------------------------------------------------------------------------
# Browser discovery
# --------------------------------------------------------------------------

find_chrome() {
  if [[ -n "${CHROME_BIN:-}" ]]; then
    echo "$CHROME_BIN"
    return 0
  fi
  local candidate
  for candidate in \
    "$HOME/Library/Caches/ms-playwright"/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell \
    "$HOME/Library/Caches/ms-playwright"/chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! CHROME="$(find_chrome)"; then
  echo "error: no Chrome binary found." >&2
  echo "       Set CHROME_BIN=/path/to/chrome or install a Playwright chromium." >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Variant construction
# --------------------------------------------------------------------------

# build_variant <source-html> <inject-file> <dest> [head|body]
# Copies $1 to $3, splicing the contents of $2 in just before </head> (default)
# or just before </body>.
#
# Probe scripts go at the end of the body, not in the head: these studies link
# Google Fonts, and with no network the window load event never fires, so a
# load listener would never run.
build_variant() {
  local src="$1" inject="$2" dest="$3" where="${4:-head}"
  local marker='<\/head>'
  [[ "$where" == "body" ]] && marker='<\/body>'
  awk -v injectfile="$inject" -v marker="$marker" '
    $0 ~ marker && !done {
      while ((getline line < injectfile) > 0) print line
      close(injectfile)
      done = 1
    }
    { print }
  ' "$src" > "$dest"
}

# write_css <file> <sel> <bg> <phase> <extra>
# phase is an optional negative CSS animation-delay in seconds, used to freeze
# a looping visual at a chosen phase so captures are reproducible.
# extra is caller CSS, e.g. forcing every captured surface onto one appearance.
write_css() {
  local out="$1" sel="$2" bg="$3" phase="$4" extra="$5"
  local phase_rule=""
  [[ -n "$phase" ]] && \
    phase_rule="*,*::before,*::after{animation-delay:${phase}s!important;animation-play-state:paused!important}"
  cat > "$out" <<CSS
<style id="kalam-readme-capture">
  html,body{margin:0!important;padding:0!important;overflow:hidden!important;background:${bg}!important}
  body *{visibility:hidden!important}
  ${sel},${sel} *{visibility:visible!important}
  ${sel}{position:fixed!important;left:0!important;top:0!important;z-index:2147483647!important;
         margin:0!important;transform:none!important}
  .desk-label,.cap,figcaption,.note{display:none!important}
  *,*::before,*::after{animation-play-state:paused!important;transition:none!important}
  ${phase_rule}
  ${extra}
</style>
CSS
}

# measure <source-html> <sel> <bg> <phase> <extra>
# Prints WxH for the target element, MISS if the selector does not resolve.
measure() {
  local src="$1" sel="$2" bg="$3" phase="$4" extra="$5"
  local variant="$WORK_DIR/measure.html"
  local css="$WORK_DIR/measure.css"
  local probe="$WORK_DIR/measure-probe.html"
  write_css "$css" "$sel" "$bg" "$phase" "$extra"
  cat > "$probe" <<HTML
<script>
(function () {
  var el = document.querySelector('${sel}');
  if (!el) {
    document.documentElement.setAttribute('data-kalam-measure', 'MISS');
    return;
  }
  var r = el.getBoundingClientRect();
  document.documentElement.setAttribute('data-kalam-measure',
    Math.ceil(r.width) + 'x' + Math.ceil(r.height));
})();
</script>
HTML
  build_variant "$src" "$css" "$WORK_DIR/measure-styled.html" head
  build_variant "$WORK_DIR/measure-styled.html" "$probe" "$variant" body
  "$CHROME" --headless --disable-gpu --hide-scrollbars --virtual-time-budget=3000 \
    --window-size=1600,1200 --dump-dom "file://$variant" 2>/dev/null \
    | grep -o 'data-kalam-measure="[^"]*"' \
    | head -1 \
    | sed 's/data-kalam-measure="//; s/"$//'
}

# write_meter_pose <file> <sel>
# The studies drive the waveform and level meters from a requestAnimationFrame
# loop, so any inline style set before paint gets overwritten on the next tick.
# A stylesheet declaration marked !important outranks an inline custom property,
# so the meter envelope is pinned with CSS instead.
#
# The shape is deterministic: a raised-cosine speech envelope over the bar
# array, modulated by a fixed two-frequency wobble, so repeated captures of the
# same state are byte-identical.
write_meter_pose() {
  local out="$1" sel="$2" i h e
  {
    echo '<style id="kalam-meter-pose">'
    for i in $(seq 0 52); do
      h=$(awk -v i="$i" 'BEGIN {
        n = 53
        u = i / (n - 1)
        speech = sin(3.14159265358979 * u)
        wobble = 0.55 + 0.45 * sin(i * 1.7) * cos(i * 0.63)
        if (wobble < 0.22) wobble = 0.22
        printf "%.3f", 0.07 + 0.78 * speech * wobble
      }')
      echo "${sel} .wave .bar:nth-child($((i + 1))){--h:${h}!important}"
    done
    for i in 0 1 2; do
      e=$(awk -v i="$i" 'BEGIN {
        v = 0.5 + 0.5 * sin(i * 0.9 + 0.6)
        printf "%.3f", 0.18 + 0.82 * v
      }')
      echo "${sel} .eq b:nth-child($((i + 1))){--e:${e}!important}"
    done
    echo '</style>'
  } > "$out"
}

# shoot <source-html> <sel> <outfile> <bg> <phase> <extra>
shoot() {
  local src="$1" sel="$2" out="$3" bg="$4" phase="$5" extra="$6"
  local dims
  dims="$(measure "$src" "$sel" "$bg" "$phase" "$extra")"
  if [[ -z "$dims" || "$dims" == "MISS" ]]; then
    echo "  skip $(basename "$out") (selector missed: $sel)" >&2
    return 1
  fi

  local inject="$WORK_DIR/$(basename "$out").inject"
  local pose="$WORK_DIR/$(basename "$out").pose"
  local variant="$WORK_DIR/$(basename "$out").html"
  write_css "$inject" "$sel" "$bg" "$phase" "$extra"
  write_meter_pose "$pose" "$sel"
  cat "$inject" "$pose" > "$WORK_DIR/$(basename "$out").combined"
  build_variant "$src" "$WORK_DIR/$(basename "$out").combined" "$variant" head

  local w="${dims%x*}" h="${dims#*x}"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --virtual-time-budget=3000 \
    --force-device-scale-factor=2 --window-size="$w,$h" \
    --screenshot="$out" "file://$variant" >/dev/null 2>&1

  echo "  $(basename "$out")  ${w}x${h}"
}

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------

# Hero frames are forced onto one dark desktop at one fixed size, so the
# crossfade neither strobes between light and dark appearances nor jumps when
# the states differ in natural width. The isolation stylesheet pins the target
# with position:fixed, which takes it out of flow, so the size must be set
# explicitly rather than through flex-basis.
DARK='.desk{width:520px!important;height:168px!important;min-height:168px!important;flex:none!important;background:radial-gradient(120% 85% at 50% 0%, rgba(130,130,140,0.12) 0%, rgba(0,0,0,0) 55%), linear-gradient(170deg, #242427 0%, #141417 55%, #0B0B0D 100%)!important}'

# nth-of-type counts div siblings only, and each section's first div is
# .sec-head, so the three .row blocks in #style-a are divs 2, 3 and 4. Within a
# row, .desk-light and .desk-dark are divs 1 and 2.
#
# String copy is pinned to app/Kalam/IndicatorStateModel.swift. The rejected
# "H caret chip" variant is deliberately absent: it was removed on 2026-09-12
# (see AGENTS.md), so it must not appear in the README.
capture_indicator_states() {
  echo "indicator states (machined A / whisper E)"
  shoot "$INDICATOR_SRC" '#style-a .row:nth-of-type(2) .desk:nth-of-type(1)' \
    "$OUT_DIR/state-listening.png" '#141417' '-0.9' "$DARK"
  shoot "$INDICATOR_SRC" '#style-a .row:nth-of-type(2) .desk:nth-of-type(2)' \
    "$OUT_DIR/state-pausing.png" '#141417' '-1.6' "$DARK"
  shoot "$INDICATOR_SRC" '#style-a .row:nth-of-type(3) .desk:nth-of-type(1)' \
    "$OUT_DIR/state-transcribing.png" '#141417' '' "$DARK"
  shoot "$INDICATOR_SRC" '#style-a .row:nth-of-type(3) .desk:nth-of-type(2)' \
    "$OUT_DIR/state-held.png" '#141417' '' "$DARK"
  shoot "$INDICATOR_SRC" '#style-a .row:nth-of-type(4) .desk:nth-of-type(1)' \
    "$OUT_DIR/state-blocked.png" '#141417' '' "$DARK"
  # whisper pill, the compact alternative
  shoot "$INDICATOR_SRC" '#style-e .row:nth-of-type(2) .desk:nth-of-type(1)' \
    "$OUT_DIR/state-whisper.png" '#141417' '-1.1' ''
}

capture_onboarding() {
  echo "onboarding deck"
  # figure 6 is the model-folder step, which shows the numbered wizard list
  shoot "$ONBOARDING_SRC" 'figure.shot:nth-of-type(6) .frame > .scaler > div[data-w]' \
    "$OUT_DIR/onboarding-steps.png" '#F7F5EF' '' ''
}

capture_settings() {
  echo "settings map"
  # The study pins .cw to 980x660 but the map body only fills the top ~880px,
  # so the height is released to avoid a large empty band in the README.
  shoot "$SETTINGS_SRC" 'figure.shot:nth-of-type(1) .cw' \
    "$OUT_DIR/settings-map.png" '#1A1A18' '' '.cw{height:auto!important;min-height:0!important}'
}

# build_hero_gif
# The five machined states in sequence, each held for $HOLD seconds, with the
# final frame repeated so the loop closes cleanly. Hard cuts are used rather
# than xfade: crossfading two indicator surfaces reads as a smear, and xfade
# over looping image inputs emits non-monotonic timestamps that truncate the
# output.
build_hero_gif() {
  echo "hero gif"
  command -v ffmpeg >/dev/null 2>&1 || {
    echo "  skip (ffmpeg not installed)" >&2
    return 0
  }

  local states=(state-listening state-pausing state-transcribing state-held state-blocked)
  local f
  for f in "${states[@]}"; do
    if [[ ! -f "$OUT_DIR/$f.png" ]]; then
      echo "  skip (missing $f.png)" >&2
      return 0
    fi
  done

  local hold=0.9
  local list="$WORK_DIR/hero-concat.txt"
  : > "$list"
  for f in "${states[@]}"; do
    printf "file '%s'\nduration %s\n" "$OUT_DIR/$f.png" "$hold" >> "$list"
  done
  printf "file '%s'\n" "$OUT_DIR/state-blocked.png" >> "$list"

  ffmpeg -hide_banner -loglevel error -y \
    -f concat -safe 0 -i "$list" \
    -vf "fps=12,scale=720:-2:flags=lanczos,setsar=1,split[pa][pb];\
[pa]palettegen=max_colors=128:stats_mode=diff[pal];\
[pb][pal]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$OUT_DIR/hero-indicator.gif"

  echo "  hero-indicator.gif  $(du -h "$OUT_DIR/hero-indicator.gif" | cut -f1)"
}

# --------------------------------------------------------------------------

MEASURE_ONLY=0
[[ "${1:-}" == "--measure" ]] && MEASURE_ONLY=1

mkdir -p "$OUT_DIR"

if [[ $MEASURE_ONLY -eq 1 ]]; then
  echo "-- measuring targets --"
  while IFS='|' read -r sel src; do
    [[ -z "$sel" ]] && continue
    printf '%-58s %s\n' "$sel" "$(measure "$src" "$sel" '#141417' '' "$DARK")"
  done <<TARGETS
#style-a .row:nth-of-type(2) .desk:nth-of-type(1)|$INDICATOR_SRC
#style-a .row:nth-of-type(2) .desk:nth-of-type(2)|$INDICATOR_SRC
#style-a .row:nth-of-type(3) .desk:nth-of-type(1)|$INDICATOR_SRC
#style-a .row:nth-of-type(3) .desk:nth-of-type(2)|$INDICATOR_SRC
#style-a .row:nth-of-type(4) .desk:nth-of-type(1)|$INDICATOR_SRC
#style-e .row:nth-of-type(2) .desk:nth-of-type(1)|$INDICATOR_SRC
figure.shot:nth-of-type(6) .frame > .scaler > div[data-w]|$ONBOARDING_SRC
figure.shot:nth-of-type(1) .cw|$SETTINGS_SRC
TARGETS
  exit 0
fi

echo "-- capturing to $OUT_DIR --"
capture_indicator_states
capture_onboarding
capture_settings
build_hero_gif

echo "-- done --"
ls -la "$OUT_DIR"