#!/usr/bin/env bash
# Release check on an Android phone (task 83c7d4): the real app, on a test
# device, against a desktop `dsync` over peer://, driven from this desktop.
# A release checklist item, not CI. From the repo root:
#
#   integration_test/phone_release_check.sh --device <adb serial> \
#     --i-understand-this-reinstalls
#
#   integration_test/phone_release_check.sh --dry-run   # the plan, nothing run
#
# IT WIPES THE APP ON THAT PHONE. It uninstalls com.example.dsync first — its
# archives, identity, pairings and All-files grant go with it — and installs a
# test build whose entry point is integration_test/phone_release_check_test.dart,
# removed again at the end. Reinstall your own build afterwards. Use a test
# device, never one holding a replica you care about. On the phone it touches
# only /storage/emulated/0/dsync-e2e, which it deletes and recreates.
#
# What it checks, each ending PASS or FAIL in the summary:
#   (a) All-files access: a picked folder is refused without it, the access
#       settings are opened, and the same folder is accepted once granted.
#   (b) The system chooser's pick comes back as the folder's path.
#   (c) A sync the app starts against `dsync agent --serve` here, and one this
#       desktop's CLI starts against the app's Serve page.
#   (d) The app force-stopped mid-apply (`am force-stop`), relaunched, the
#       §7.6 run marker on its profile, and the run recovered by running again.
# Every check that matters is a tree comparison (sha256 of every file) between
# the desktop folder and the phone folder, read with `adb shell` in the test
# folder only.
#
# How. The on-device half is `flutter test -d <serial>` on the test file,
# twice: phase `main` runs (a)–(c) and starts (d)'s run, which this script
# kills; phase `recover` is the relaunch. The test prints `E2E|…` lines that
# `flutter test` streams into this script's log; this script answers by
# creating files in the phone's test folder (control/), which the app can read
# once step (a) has given it All-files access. The steps a person has to do —
# the folder chooser twice, refusing then granting access — are printed here,
# and the script waits for Enter. The grant can instead be made with
# `adb shell appops set --uid com.example.dsync MANAGE_EXTERNAL_STORAGE allow`,
# which the script runs only when you ask for it at that step.
#
# Needs: adb, flutter, cargo; the phone on the same Wi-Fi as this desktop,
# unlocked, screen kept on (Developer options → Stay awake); this desktop
# accepting inbound TCP on --agent-port (28791), where the app dials the agent.
# --desktop-ip overrides the address the app dials, which is otherwise this
# desktop's source address on its default route.
#
# Output: ~/.cache/dsync/scratch/e2e-<time>/ — the desktop trees, the CLI's
# isolated state (XDG_STATE_HOME/XDG_CONFIG_HOME under it; never your own),
# and logs/ with both flutter test runs, the agent and every CLI sync.

set -euo pipefail

pkg=com.example.dsync
test_dir=/storage/emulated/0/dsync-e2e
agent_port=28791
big_files=400
big_kib=1024
serial=""
reinstall_ok=0
dry=0
desktop_ip=""

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
    --device) serial="$2"; shift 2 ;;
    --i-understand-this-reinstalls) reinstall_ok=1; shift ;;
    --dry-run) dry=1; shift ;;
    --desktop-ip) desktop_ip="$2"; shift 2 ;;
    --agent-port) agent_port="$2"; shift 2 ;;
    --big-files) big_files="$2"; shift 2 ;;
    --big-kib) big_kib="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "phone_release_check: unknown option $1" >&2; exit 2 ;;
  esac
done

if ((!dry)) && [[ -z "$serial" || $reinstall_ok -ne 1 ]]; then
  cat >&2 <<EOF
phone_release_check: refusing to run.
This uninstalls $pkg on the phone — its archives, identity, pairings and
All-files grant are lost — and wipes $test_dir. Pass both
  --device <adb serial> --i-understand-this-reinstalls
to run it against a test device, or --dry-run to see the plan.
EOF
  exit 2
fi
serial=${serial:-<serial>}

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
scratch="$HOME/.cache/dsync/scratch/e2e-$(date +%Y-%m-%dT%H-%M-%S)"
logs="$scratch/logs"
dsync="$repo/native/target/release/dsync"
test_file=integration_test/phone_release_check_test.dart

# --- plumbing -----------------------------------------------------------------

# Prints a command on the terminal (fd 3, whatever the command's own output
# is redirected to), then runs it unless this is a dry run.
exec 3>&1
run() {
  {
    printf '  $'
    printf ' %q' "$@"
    printf '\n'
  } >&3
  ((dry)) || "$@"
}

phone() { run adb -s "$serial" "$@"; }

# The desktop CLI, on this session's own state: never the user's.
cli() {
  run env XDG_STATE_HOME="$scratch/state" XDG_CONFIG_HOME="$scratch/config" \
    "$dsync" "$@"
}

say() { printf '\n==> %s\n' "$*"; }

# A step for the person at the phone; waits for Enter and leaves the line
# typed in $reply.
prompt() {
  reply=""
  printf '\n  ┌─ ON THE PHONE ─────────────────────────────────────────────\n'
  printf '  │ %s\n' "$@"
  printf '  └────────────────────────────────────────────────────────────\n'
  if ((dry)); then
    echo "  (waits for Enter)"
  else
    read -r -p "  Press Enter when done " reply </dev/tty
  fi
}

declare -A result=([a]="NOT RUN" [b]="NOT RUN" [c1]="NOT RUN" [c2]="NOT RUN" [d]="NOT RUN")
declare -A detail=()
current=a
flutter_pid=""
agent_pid=""
log=""

# A dry run records nothing: every step stays NOT RUN.
pass() { ((dry)) || { result[$1]=PASS; detail[$1]="${2:-}"; }; }
failed() { ((dry)) || { result[$1]=FAIL; detail[$1]="$2"; }; }

summary() {
  printf '\n== Release check on %s ==\n' "$serial"
  local step label
  for step in a b c1 c2 d; do
    case $step in
      a) label='(a) All-files grant, refused then granted' ;;
      b) label='(b) chooser pick turned into a path' ;;
      c1) label='(c) sync, the app initiates' ;;
      c2) label='(c) sync, the desktop CLI initiates' ;;
      d) label='(d) killed mid-apply, relaunched, recovered' ;;
    esac
    printf '%-46s %-8s %s\n' "$label" "${result[$step]}" "${detail[$step]:-}"
  done
  echo "Session folder: $scratch"
}

cleanup() {
  [[ -n "$flutter_pid" ]] && kill "$flutter_pid" 2>/dev/null || true
  [[ -n "$agent_pid" ]] && kill "$agent_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Ends the session: the step under way failed with $1, unless its failure
# is already recorded.
abort() {
  [[ ${result[$current]} == FAIL ]] || failed "$current" "$1"
  echo "phone_release_check: $1" >&2
  [[ -n "$log" ]] && echo "  see $log" >&2
  summary
  exit 1
}

# Waits for the app's `E2E|<prefix>…` line in $log; the whole line after
# `E2E|` lands in $marker. An `E2E|fail|` line, the test process ending, or
# the deadline ends the session.
wait_marker() {
  local prefix=$1 seconds=${2:-600} line
  marker=""
  if ((dry)); then
    echo "  (waits for the app's E2E|$prefix line)"
    marker="$prefix<from the app>"
    return
  fi
  local deadline=$((SECONDS + seconds))
  while :; do
    line=$(grep -a -m 1 -o "E2E|fail|.*" "$log" || true)
    if [[ -n "$line" ]]; then
      local rest=${line#E2E|fail|} step
      step=${rest%%|*}
      # The app's (c) is whichever half of it is under way here.
      [[ $step == c ]] && step=$current
      failed "$step" "the app: ${rest#*|}"
      abort "the app failed step $step: ${rest#*|}"
    fi
    line=$(grep -a -m 1 -o "E2E|$prefix.*" "$log" || true)
    if [[ -n "$line" ]]; then
      marker=${line#E2E|}
      return
    fi
    kill -0 "$flutter_pid" 2>/dev/null ||
      abort "flutter test ended before the app reported $prefix"
    ((SECONDS < deadline)) || abort "no E2E|$prefix from the app in ${seconds}s"
    sleep 0.2
  done
}

# Tells the app the desktop is ready for it (see the test file's header).
signal_app() { phone shell "touch $test_dir/control/$1"; }

# `sha256  ./path` for every file under a folder, in one order on both sides.
desktop_sums() { (cd "$1" && find . -type f -exec sha256sum {} +) | LC_ALL=C sort -k2; }
phone_sums() {
  adb -s "$serial" shell "cd '$1' && find . -type f -exec sha256sum {} +" |
    tr -d '\r' | LC_ALL=C sort -k2
}

# Compares a desktop folder with a phone folder; the diff, if any, goes to
# logs/<name>.diff.
same_tree() {
  local name=$1 desk=$2 phone_dir=$3
  echo "  compare $desk with phone:$phone_dir"
  ((dry)) && return 0
  if diff <(desktop_sums "$desk") <(phone_sums "$phone_dir") >"$logs/$name.diff"; then
    return 0
  fi
  echo "  trees differ; see $logs/$name.diff" >&2
  return 1
}

# A small tree with a subfolder, a name with a space and one binary file.
seed_small() {
  local dir=$1 tag=$2 i
  mkdir -p "$dir/sub/deeper"
  for i in $(seq 1 12); do printf '%s note %d\n' "$tag" "$i" >"$dir/note-$i.txt"; done
  for i in 1 2 3; do printf '%s deep %d\n' "$tag" "$i" >"$dir/sub/deeper/deep-$i.txt"; done
  printf '%s spaced\n' "$tag" >"$dir/sub/with a space.txt"
  head -c 3145728 /dev/urandom >"$dir/sub/blob.bin"
}

# (d)'s tree: big enough that the apply is still running when it is killed.
seed_big() {
  local dir=$1 i
  for i in $(seq 1 "$big_files"); do
    mkdir -p "$dir/d$((i % 10))"
    head -c $((big_kib * 1024)) /dev/urandom >"$dir/d$((i % 10))/f-$i.bin"
  done
}

# Starts one flutter test phase in the background, logging to logs/<phase>.log.
start_phase() {
  local phase=$1
  shift
  log="$logs/$phase.log"
  local cmd=(flutter test -d "$serial" --reporter expanded "$@" "$test_file"
    --dart-define=E2E_PHASE="$phase"
    --dart-define=DESKTOP_ADDR="$desktop_ip:$agent_port"
    --dart-define=DESKTOP_PUSH_ROOT="$scratch/cli-root"
    --dart-define=DESKTOP_BIG_ROOT="$scratch/cli-big")
  printf '  $'
  printf ' %q' "${cmd[@]}"
  printf ' >%q 2>&1 &\n' "$log"
  ((dry)) && return
  "${cmd[@]}" </dev/null >"$log" 2>&1 &
  flutter_pid=$!
}

# --- the session ----------------------------------------------------------------

say "Release check on $serial$( ((dry)) && echo ' (dry run: nothing is run)')"
cat <<EOF
  This UNINSTALLS $pkg on the phone: its archives, identity, pairings and
  All-files grant are lost. It deletes and recreates $test_dir.
  Session folder: $scratch
EOF

if ((!dry)); then
  for tool in adb flutter cargo sha256sum; do
    command -v "$tool" >/dev/null || { echo "phone_release_check: $tool not on PATH" >&2; exit 2; }
  done
  attached=$(adb devices)
  grep -q "^${serial}[[:space:]]*device$" <<<"$attached" ||
    { echo "phone_release_check: $serial is not an attached adb device" >&2; exit 2; }
  if [[ -z "$desktop_ip" ]]; then
    desktop_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  fi
  [[ -n "$desktop_ip" ]] || { echo "phone_release_check: pass --desktop-ip" >&2; exit 2; }
else
  desktop_ip=${desktop_ip:-<desktop-ip>}
fi
echo "  The app will dial this desktop at $desktop_ip:$agent_port."

prompt "Unlock the phone and keep it unlocked, on the same Wi-Fi as this desktop." \
  "Last chance: Ctrl-C now keeps $pkg and its data."

say "Build the desktop CLI and seed the trees"
run bash -c 'cd native && cargo build --release -p dsync-cli'
run mkdir -p "$logs" "$scratch/state" "$scratch/config" "$scratch/cli-root" "$scratch/cli-big"
run seed_small "$scratch/seed/app-root" phone
run seed_small "$scratch/desk-push" desktop
run seed_big "$scratch/cli-big"

say "Wipe the app and the test folder on the phone"
phone uninstall "$pkg" || true
phone shell "rm -rf $test_dir && mkdir -p $test_dir/control $test_dir/serve-root $test_dir/app-big"
phone push "$scratch/seed/app-root" "$test_dir/"

say "Phase main: build, install and start the test build (the first build takes minutes)"
start_phase main --no-uninstall

# (a) and (b) -------------------------------------------------------------------
current=a
wait_marker 'step|a1-chooser' 1800
prompt "The folder chooser is open. Go to dsync-e2e → app-root and tap" \
  "'Use this folder', then 'Allow'." \
  "Next an 'All files access' screen opens: leave the switch OFF, press Back." \
  "If a dialog asks for access to files, tap 'Don't allow'."
wait_marker 'a|probe-refused' 900
echo "  refused without the grant: ${marker#a|probe-refused|}"

wait_marker 'step|a2-settings' 60
prompt "dsync's App info page is open. Grant All-files access there" \
  "(Permissions → Files → 'Allow management of all files'; wording varies)," \
  "then switch back to the dsync screen." \
  "Or type 'appops' and Enter to have this script grant it over adb instead."
if [[ "$reply" == appops ]]; then
  read -r -p "  Run 'adb shell appops set --uid $pkg MANAGE_EXTERNAL_STORAGE allow'? [y/N] " yes </dev/tty
  if [[ "$yes" == y || "$yes" == Y ]]; then
    phone shell appops set --uid "$pkg" MANAGE_EXTERNAL_STORAGE allow
    prompt "Switch back to the dsync screen (press Back until it shows)."
  fi
fi
wait_marker 'a|granted' 900
pass a

current=b
wait_marker 'step|b-chooser' 60
prompt "The folder chooser is open again. Pick dsync-e2e → app-root once more."
wait_marker 'b|ok|' 900
picked=${marker#b|ok|}
if ((dry)) || [[ "$picked" == "$test_dir/app-root" ]]; then
  pass b "$picked"
else
  abort "the form holds $picked"
fi

# (c) ---------------------------------------------------------------------------
current=c1
say "Pair: the app shows a code, this desktop redeems it"
wait_marker 'pair|' 60
payload=${marker#pair|}
cli pair accept --name phone "$payload" </dev/null || abort "dsync pair accept failed"
wait_marker 'paired|' 120
cli pair grant phone "$scratch/cli-root" || abort "dsync pair grant failed"
cli pair grant phone "$scratch/cli-big" || abort "dsync pair grant failed"

say "Serve here: dsync agent --serve on port $agent_port"
printf '  $ %s &\n' "env XDG_STATE_HOME=$scratch/state XDG_CONFIG_HOME=$scratch/config $dsync agent --serve --bind 0.0.0.0 --port $agent_port >$logs/agent.log 2>&1"
if ((!dry)); then
  env XDG_STATE_HOME="$scratch/state" XDG_CONFIG_HOME="$scratch/config" \
    "$dsync" agent --serve --bind 0.0.0.0 --port "$agent_port" \
    </dev/null >"$logs/agent.log" 2>&1 &
  agent_pid=$!
  for _ in $(seq 50); do
    grep -q 'serving paired devices' "$logs/agent.log" && break
    sleep 0.2
  done
  grep -q 'serving paired devices' "$logs/agent.log" || abort "the agent did not start; see $logs/agent.log"
fi
signal_app agent-serving

wait_marker 'c1|done|' 900
if same_tree c1 "$scratch/cli-root" "$test_dir/app-root"; then
  pass c1 "${marker#c1|done|}"
else
  failed c1 "the desktop's copy differs from the phone's"
fi

current=c2
say "The desktop CLI syncs into the app's Serve page"
wait_marker 'serving|' 120
echo "  the app serves at ${marker#serving|}"
c2_ok=1
c2_sync=(sync "$scratch/desk-push" "peer://phone:$test_dir/serve-root" --batch)
if ((dry)); then
  cli "${c2_sync[@]}"
else
  cli "${c2_sync[@]}" >"$logs/c2-sync.txt" 2>&1 || c2_ok=0
  grep -q 'failed=0 unreadable=0' "$logs/c2-sync.txt" || c2_ok=0
fi
if ((c2_ok)) && same_tree c2 "$scratch/desk-push" "$test_dir/serve-root"; then
  pass c2
else
  failed c2 "see $logs/c2-sync.txt"
fi
signal_app c2-done

# (d) ---------------------------------------------------------------------------
current=d
say "Kill the app mid-apply"
wait_marker 'd|applying|' 900
phone shell am force-stop "$pkg"
echo "  killed at ${marker#d|applying|} actions"
killed_mid=1
if ((!dry)); then
  sleep 2
  on_phone=$(adb -s "$serial" shell "find $test_dir/app-big -type f | wc -l" | tr -d '\r ')
  echo "  $on_phone of $big_files files on the phone after the kill"
  ((on_phone < big_files)) || killed_mid=0
  kill "$flutter_pid" 2>/dev/null || true
  wait "$flutter_pid" 2>/dev/null || true
  flutter_pid=""
fi

say "Phase recover: relaunch the same app (its data kept) and run the profile again"
start_phase recover
wait_marker 'd|marker|true' 1800
wait_marker 'd|recovered|' 900
recovered=${marker#d|recovered|}
if ((!dry)); then
  wait "$flutter_pid" || abort "flutter test (recover) failed; see $log"
  flutter_pid=""
fi
if ! same_tree d "$scratch/cli-big" "$test_dir/app-big"; then
  failed d "the recovered tree differs from the desktop's"
elif ((!killed_mid)); then
  failed d "every file had landed before the kill; raise --big-files"
else
  pass d "marker seen; $recovered"
fi

say "Stop the agent"
cleanup
agent_pid=""
((dry)) && echo "  (dry run: nothing was checked)"
summary
((dry)) && exit 0
for step in a b c1 c2 d; do [[ ${result[$step]} == PASS ]] || exit 1; done
