#!/usr/bin/env bash
# Capture the visual assets used by README.md.
#
# The README hero and stills are generated from the HTML design studies under
# app/docs/plans/ so the marketing images stay traceable to the approved
# designs instead of being hand-maintained binaries.
#
# Two capture paths:
#
#   shoot         one still, isolated to a single element
#   shoot_frames  the same element cloned N times down the page, each with a
#                 different animation phase, captured as one tall strip and
#                 sliced into N frames by ffmpeg. This is how the animated hero
#                 is made: one browser launch produces the whole cycle.
#
# The studies drive their waveform from a requestAnimationFrame loop. Clones
# created after that loop has registered its bars are never touched by it, so a
# clone keeps whatever inline --h we give it. That is what makes the frames
# controllable.
#
# Usage:
#   ./scripts/capture-readme-visuals.sh            # capture everything
#   ./scripts/capture-readme-visuals.sh --measure  # print target sizes only
#
# Env overrides:
#   CHROME_BIN   path to a Chrome / chrome-headless-shell binary
#   OUT_DIR      output directory (default: assets/readme)
#   KEEP_WORK=1  keep the generated HTML variants for inspection

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

# Transparent page background everywhere. The captured surfaces are rounded
# panels; without this the page background shows through as square corners that
# read as a stray box once the image sits on a different background in the README.
CHROME_OPTS=(--headless --disable-gpu --hide-scrollbars --virtual-time-budget=3000
             --default-background-color=00000000)

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

# write_css <file> <sel> <phase> <extra>
# phase is an optional negative CSS animation-delay in seconds, used to freeze
# a looping visual at a chosen phase so captures are reproducible.
# extra is caller CSS, e.g. forcing a surface onto one appearance.
write_css() {
  local out="$1" sel="$2" phase="$3" extra="$4"
  local phase_rule=""
  [[ -n "$phase" ]] && \
    phase_rule="*,*::before,*::after{animation-delay:${phase}s!important;animation-play-state:paused!important}"
  cat > "$out" <<CSS
<style id="kalam-readme-capture">
  html,body{margin:0!important;padding:0!important;overflow:hidden!important;background:transparent!important}
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

# write_meter_pose <file> <sel>
# Pins a static speech envelope onto the waveform bars for still captures.
# A stylesheet declaration marked !important outranks the inline custom property
# the study's animation loop writes, so this survives the loop.
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

# measure <source-html> <sel> <phase> <extra>
# Diagnostic only. Chrome intermittently dumps the DOM before the inline probe
# runs, so the capture path never depends on this: every target below has a
# size that is fixed in CSS, either by the study itself or by the extra rules
# we inject. Kept so --measure can confirm a study still lays out as expected.
measure() {
  local src="$1" sel="$2" phase="$3" extra="$4"
  local variant="$WORK_DIR/measure.html"
  local css="$WORK_DIR/measure.css"
  local probe="$WORK_DIR/measure-probe.html"
  write_css "$css" "$sel" "$phase" "$extra"
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

  local dump="" attempt
  for attempt in 1 2 3 4; do
    dump=$("${CHROME_OPTS[@]}" --window-size=1600,1200 --dump-dom "file://$variant" 2>/dev/null \
      | grep -o 'data-kalam-measure="[^"]*"' \
      | head -1 \
      | sed 's/data-kalam-measure="//; s/"$//' || true)
    [[ -n "$dump" ]] && break
    sleep 0.3
  done
  printf '%s' "$dump"
}

# run_chrome <log-label> <args...>
# Runs Chrome, never aborts the script on a non-zero exit, and echoes the
# captured stderr when the run fails. Chrome is flaky enough under headless
# that a single failure should be reported, not silently fatal.
run_chrome() {
  local label="$1"; shift
  local log="$WORK_DIR/$label.chrome.log"
  if "$CHROME" "$@" >"$log" 2>&1; then
    return 0
  fi
  echo "  chrome failed for $label:" >&2
  sed 's/^/    /' "$log" >&2
  return 1
}

# shoot <source-html> <sel> <outfile> <w> <h> <phase> <extra>
shoot() {
  local src="$1" sel="$2" out="$3" w="$4" h="$5" phase="$6" extra="$7"
  local inject="$WORK_DIR/$(basename "$out").inject"
  local pose="$WORK_DIR/$(basename "$out").pose"
  local variant="$WORK_DIR/$(basename "$out").html"
  write_css "$inject" "$sel" "$phase" "$extra"
  write_meter_pose "$pose" "$sel"
  cat "$inject" "$pose" > "$WORK_DIR/$(basename "$out").combined"
  build_variant "$src" "$WORK_DIR/$(basename "$out").combined" "$variant" head

  run_chrome "$(basename "$out")" \
    --headless --disable-gpu --hide-scrollbars --virtual-time-budget=3000 \
    --default-background-color=00000000 --force-device-scale-factor=2 \
    --window-size="$w,$h" --screenshot="$out" "file://$variant"

  if [[ ! -s "$out" ]]; then
    echo "  skip $(basename "$out") (screenshot produced nothing)" >&2
    return 1
  fi
  echo "  $(basename "$out")  ${w}x${h}"
}

# --------------------------------------------------------------------------
# Animated frame strip
# --------------------------------------------------------------------------

# write_frames_script <file> <sel> <count> <w> <h> <shimmer-period>
#
# Builds a vertical strip of `count` clones of the target, each frozen at a
# different point in its animation, so one screenshot yields the whole cycle.
#
# The waveform is driven by the study's requestAnimationFrame loop, which only
# touches the bars it registered at init. These clones are made afterwards and
# are never registered, so setting --h inline sticks. CSS animations (the
# shimmer) are frozen instead with a negative animation-delay plus
# animation-play-state:paused, which is exact rather than sampled.
write_frames_script() {
  local out="$1" sel="$2" count="$3" w="$4" h="$5" period="$6"
  cat > "$out" <<HTML
<script>
(function () {
  var SEL = '${sel}', COUNT = ${count}, W = ${w}, H = ${h}, PERIOD = ${period};
  var src = document.querySelector(SEL);
  if (!src) { document.documentElement.setAttribute('data-kalam-frames', 'MISS'); return; }

  // The app's waveform is a scrolling history buffer: the newest sample enters
  // at the right edge and the whole trace drifts left. That needs a travelling
  // shape, not a per-bar oscillation — an oscillation just shimmers in place
  // because the total energy stays centred.
//
// u runs -1 (left edge) to +1 (right edge). Two bumps travel from +1 to -1 as
  // the frame index advances; distance is measured on a circle so each bump
  // wraps off the left edge and re-enters at the right, and because bump() goes
  // to zero at the wrap point the seam is invisible and the cycle loops clean.
  function bump(u, centre, width) {
    var d = Math.abs(u - centre);
    if (d > 1) d = 2 - d;
    var t = d / width;
    return Math.exp(-t * t * 2.4);
  }
  function waveH(i, n, f) {
    var u = (n > 1 ? i / (n - 1) : 0.5) * 2 - 1;
    var travel = f / COUNT;
    var c1 = 1 - travel * 2;
    var c2 = -1 - travel * 2 + 0.9;
    var floor = 0.05 + 0.035 * Math.sin(i * 0.9 + f * 0.6);
    var h = floor + 0.78 * bump(u, c1, 0.42) + 0.45 * bump(u, c2, 0.30);
    return Math.min(0.95, h).toFixed(3);
  }

  var stack = document.createElement('div');
  stack.id = 'kalam-frame-stack';
  stack.style.cssText = 'position:relative;margin:0;padding:0;width:' + W + 'px';

  for (var f = 0; f < COUNT; f++) {
    var clone = src.cloneNode(true);
    clone.style.cssText += ';position:absolute;left:0;top:0;margin:0;transform:none';

    var bars = clone.querySelectorAll('.wave .bar');
    for (var b = 0; b < bars.length; b++) {
      bars[b].style.setProperty('--h', waveH(b, bars.length, f));
    }
    var eq = clone.querySelectorAll('.eq b');
    for (var q = 0; q < eq.length; q++) {
      eq[q].style.setProperty('--e', (0.2 + 0.8 * Math.abs(Math.sin(f * 0.4 + q * 0.8))).toFixed(3));
    }

    var t = -(f / COUNT) * PERIOD;
    var anim = clone.querySelectorAll('.shimmer b, .dot, .b');
    for (var a = 0; a < anim.length; a++) {
      anim[a].style.animationDelay = t.toFixed(3) + 's';
      anim[a].style.animationPlayState = 'paused';
    }

    var wrap = document.createElement('div');
    wrap.style.cssText = 'width:' + W + 'px;height:' + H + 'px;overflow:hidden;position:relative';
    wrap.appendChild(clone);
    stack.appendChild(wrap);
  }
  stack.style.height = (H * COUNT) + 'px';
  document.body.appendChild(stack);
  document.documentElement.setAttribute('data-kalam-frames', 'OK');
})();
</script>
HTML
}

# shoot_frames <source-html> <sel> <outdir> <base> <count> <w> <h> <period> <extra>
# Captures `count` frames at 2x into <outdir>/<base>-NN.png
shoot_frames() {
  local src="$1" sel="$2" outdir="$3" base="$4" count="$5" w="$6" h="$7" period="$8" extra="$9"
  local css="$WORK_DIR/$base.css"
  local script="$WORK_DIR/$base.frames.js"
  local variant="$WORK_DIR/$base.frames.html"

  # The strip replaces the page: everything already in the body is removed from
  # layout and the stack, appended by the script, is left to render. Hiding
  # siblings rather than body itself matters: visibility on body does not paint
  # reliably in headless.
  cat > "$css" <<CSS
<style id="kalam-frames-capture">
  html,body{margin:0!important;padding:0!important;overflow:hidden!important;background:transparent!important}
  body > *:not(#kalam-frame-stack){display:none!important}
  .desk-label,.cap,figcaption,.note{display:none!important}
  ${extra}
</style>
CSS
  write_frames_script "$script" "$sel" "$count" "$w" "$h" "$period"
  build_variant "$src" "$css" "$WORK_DIR/$base.styled.html" head
  build_variant "$WORK_DIR/$base.styled.html" "$script" "$variant" body

  mkdir -p "$outdir"
  local strip="$WORK_DIR/$base-strip.png"
  run_chrome "$base-strip" \
    --headless --disable-gpu --hide-scrollbars --virtual-time-budget=3000 \
    --default-background-color=00000000 --force-device-scale-factor=2 \
    --window-size="$w,$((h * count))" --screenshot="$strip" "file://$variant"

  if [[ ! -s "$strip" ]]; then
    echo "  skip $base (strip capture produced nothing)" >&2
    return 1
  fi

  # The strip is 2x, so each frame is twice the CSS height.
  local i
  for i in $(seq 0 $((count - 1))); do
    ffmpeg -hide_banner -loglevel error -y -i "$strip" \
      -vf "crop=iw:$((h * 2)):0:$((i * h * 2))" \
      "$(printf '%s/%s-%02d.png' "$outdir" "$base" "$i")"
  done
  echo "  $base  ${count} frames  ${w}x${h}"
}

# --------------------------------------------------------------------------
# Hero assembly
# --------------------------------------------------------------------------

# Frames per animated state, and how long each frame is held. The hero is meant
# to read as calm, so the frame rate is low and each state is held long enough
# to land before it moves on.
# The hero is an APNG, not a GIF. GitHub will not autoplay video and strips
# <video>, so an animated image is the only option; APNG animates in an <img>
# like a GIF but keeps 24-bit colour and alpha and compresses far better, which
# is what makes a smooth frame rate affordable.
#
# Motion is deliberately slow: the frame rate is high enough to look continuous
# while each state is held long enough to read.
FRAMES=48
FPS=20
SHIMMER_PERIOD=1.2
PAUSE_SECONDS=1.5
HERO_WIDTH=720

# Per-frame hold. Integer math rather than awk: BSD awk parses 1/8 in a printf
# argument ambiguously, and the duration has to be exact for the concat demuxer.
# Requires FPS to divide 1000.
if (( 1000 % FPS != 0 )); then
  echo "error: FPS must divide 1000 (got $FPS)" >&2
  exit 1
fi
FRAME_SEC="0.$(printf '%03d' $((1000 / FPS)))"

build_hero_apng() {
  echo "hero apng"
  command -v ffmpeg >/dev/null 2>&1 || {
    echo "  skip (ffmpeg not installed)" >&2
    return 0
  }

  local frames_dir="$WORK_DIR/frames"
  local list="$WORK_DIR/hero-concat.txt"
  : > "$list"

  local f
  for f in $(seq 0 $((FRAMES - 1))); do
    printf "file '%s'\nduration %s\n" \
      "$(printf '%s/listen-%02d.png' "$frames_dir" "$f")" "$FRAME_SEC" >> "$list"
  done
  printf "file '%s'\nduration %s\n" "$WORK_DIR/state-pausing.png" "$PAUSE_SECONDS" >> "$list"
  for f in $(seq 0 $((FRAMES - 1))); do
    printf "file '%s'\nduration %s\n" \
      "$(printf '%s/write-%02d.png' "$frames_dir" "$f")" "$FRAME_SEC" >> "$list"
  done
  # Repeat the last frame so the loop does not cut on a missing duration.
  printf "file '%s'\n" "$(printf '%s/write-%02d.png' "$frames_dir" $((FRAMES - 1)))" >> "$list"

  # -f apng is required: a .png output otherwise goes to the image2 muxer,
  # which refuses more than one file. -plays 0 loops forever. The last input's
  # duplicated frame gives the loop a matching first and last pose, so it does
  # not visibly jump.
  ffmpeg -hide_banner -loglevel error -y \
    -f concat -safe 0 -i "$list" \
    -vf "fps=$FPS,scale=${HERO_WIDTH}:-2:flags=lanczos,setsar=1" \
    -f apng -plays 0 "$OUT_DIR/hero-indicator.png"

  local total
  total=$(awk "BEGIN{printf \"%.1f\", ($FRAMES * $FRAME_SEC) + $PAUSE_SECONDS + ($FRAMES * $FRAME_SEC)}")
  echo "  hero-indicator.png  $(du -h "$OUT_DIR/hero-indicator.png" | cut -f1)  ${total}s  ${FRAMES}f/state @ ${FPS}fps"
}

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------

# nth-of-type counts div siblings only, and each section's first div is
# .sec-head, so the three .row blocks in #style-a are divs 2, 3 and 4. Within a
# row, .desk-light and .desk-dark are divs 1 and 2.
#
# String copy is pinned to app/Kalam/IndicatorStateModel.swift. The rejected
# "H caret chip" variant is deliberately absent: it was removed on 2026-09-12
# (see AGENTS.md), so it must not appear in the README. Neither are the held or
# blocked states: they are error and confirmation surfaces, and a reader's first
# impression of the app should not be a permission warning.
#
# Sizes are fixed in CSS rather than measured. The isolation stylesheet pins the
# target with position:fixed, which takes it out of flow, so the desk size is
# set explicitly. Every hero frame shares one size so the cut between states
# does not jump.
DESK_W=520
DESK_H=168
DARK=".desk{width:${DESK_W}px!important;height:${DESK_H}px!important;min-height:${DESK_H}px!important;flex:none!important;background:radial-gradient(120% 85% at 50% 0%, rgba(130,130,140,0.12) 0%, rgba(0,0,0,0) 55%), linear-gradient(170deg, #242427 0%, #141417 55%, #0B0B0D 100%)!important}"

SEL_LISTEN='#style-a .row:nth-of-type(2) .desk:nth-of-type(1)'
SEL_PAUSE='#style-a .row:nth-of-type(2) .desk:nth-of-type(2)'
SEL_WRITE='#style-a .row:nth-of-type(3) .desk:nth-of-type(1)'
SEL_WHISPER='#style-e .row:nth-of-type(2) .desk:nth-of-type(1)'
SEL_ONBOARD='figure.shot:nth-of-type(6) .frame > .scaler > div[data-w]'
SEL_SETTINGS='figure.shot:nth-of-type(1) .cw'

capture_indicator_states() {
  echo "indicator states"

  # Animated: listening, the waveform sweep. One browser launch, all frames.
  shoot_frames "$INDICATOR_SRC" "$SEL_LISTEN" \
    "$WORK_DIR/frames" listen "$FRAMES" "$DESK_W" "$DESK_H" "$SHIMMER_PERIOD" "$DARK"

  # Animated: transcribing, the shimmer.
  shoot_frames "$INDICATOR_SRC" "$SEL_WRITE" \
    "$WORK_DIR/frames" write "$FRAMES" "$DESK_W" "$DESK_H" "$SHIMMER_PERIOD" "$DARK"

  # Static holds: pausing (goes into the GIF, not into the README, so it is
  # written to the work dir), and the whisper pill as a standalone still.
  shoot "$INDICATOR_SRC" "$SEL_PAUSE" \
    "$WORK_DIR/state-pausing.png" "$DESK_W" "$DESK_H" '-1.6' "$DARK"
  shoot "$INDICATOR_SRC" "$SEL_WHISPER" \
    "$OUT_DIR/state-whisper.png" 320 "$DESK_H" '-1.1' \
    ".desk{width:320px!important;height:${DESK_H}px!important;min-height:${DESK_H}px!important;flex:none!important}"
}

capture_onboarding() {
  echo "onboarding deck"
  # figure 6 is the model-folder step, which shows the numbered wizard list.
  # The card is width:700px;height:600px inline in the study.
  shoot "$ONBOARDING_SRC" "$SEL_ONBOARD" \
    "$OUT_DIR/onboarding-steps.png" 700 600 '' ''
}

capture_settings() {
  echo "settings map"
  # .cw is width:980px;height:660px in the study, but the map grid ends around
  # 470px and the Updates footer below it never paints under headless (a nested
  # overflow-y:auto inside .cw's overflow:hidden). Capturing the full 660 leaves
  # a large empty band; capturing at content height keeps the rounded frame
  # intact and drops the dead space.
  shoot "$SETTINGS_SRC" "$SEL_SETTINGS" \
    "$OUT_DIR/settings-map.png" 980 486 '' '.cw{height:486px!important}'
}

# --------------------------------------------------------------------------

MEASURE_ONLY=0
[[ "${1:-}" == "--measure" ]] && MEASURE_ONLY=1

mkdir -p "$OUT_DIR"

if [[ $MEASURE_ONLY -eq 1 ]]; then
  echo "-- measured (expected in parens) --"
  printf '%-52s %-10s %s\n' "listening"  "$(measure "$INDICATOR_SRC" "$SEL_LISTEN" '' "$DARK")"  "(${DESK_W}x${DESK_H})"
  printf '%-52s %-10s %s\n' "pausing"   "$(measure "$INDICATOR_SRC" "$SEL_PAUSE" '' "$DARK")"   "(${DESK_W}x${DESK_H})"
  printf '%-52s %-10s %s\n' "transcribing" "$(measure "$INDICATOR_SRC" "$SEL_WRITE" '' "$DARK")" "(${DESK_W}x${DESK_H})"
  printf '%-52s %-10s %s\n' "whisper"    "$(measure "$INDICATOR_SRC" "$SEL_WHISPER" '' '')"     "(320x${DESK_H})"
  printf '%-52s %-10s %s\n' "onboarding" "$(measure "$ONBOARDING_SRC" "$SEL_ONBOARD" '' '')"    "(700x600)"
  printf '%-52s %-10s %s\n' "settings"   "$(measure "$SETTINGS_SRC" "$SEL_SETTINGS" '' '')"     "(980x660)"
  exit 0
fi

echo "chrome: $CHROME"
echo "-- capturing to $OUT_DIR --"
capture_indicator_states
capture_onboarding
capture_settings
build_hero_apng

echo "-- done --"
ls -la "$OUT_DIR"