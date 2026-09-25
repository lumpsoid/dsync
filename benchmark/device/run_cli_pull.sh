#!/usr/bin/env bash
# Times phone -> desktop pulls over peer:// with no APK: the dsync CLI runs on
# the phone under `adb shell` as `dsync agent --serve`, and the desktop CLI
# pulls a tree already on the phone into a new empty folder each run (task
# ad44db). Two arms, interleaved abab, each arm a desktop binary and a phone
# binary built from the same commit (both ends speak one protocol). Not part of
# the build.
#
#   benchmark/device/run_cli_pull.sh \
#     --state ~/.cache/dsync/scratch/ad44db-2026-09-25 --peer phone-cli \
#     --root /storage/emulated/0/dsync-cli-test/large \
#     --arm before=$S/bin/desktop-before,$S/bin/phone-before \
#     --arm after=$S/bin/desktop-after,$S/bin/phone-after
#
# WHY NOT THE APP. interleaved_pairs.dart drives desktop -> phone against the
# app's Serve page, which has to be restarted by hand after every install, so
# an A/B of a protocol change needs an APK swap per arm. Here the phone end is a
# binary pushed to /data/local/tmp: swapping arms is a push and a restart, and
# the app, its data and its grants are never touched.
#
# ONE-TIME SETUP, by hand, because pairing asks a human to confirm:
#   - Build the phone binary: `cargo build --release -p dsync-cli --target
#     aarch64-linux-android` in native/, with CC_/AR_ and
#     CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER pointing into the NDK's llvm
#     toolchain (aarch64-linux-android30-clang, llvm-ar).
#   - Pair: on the desktop, in a terminal,
#       XDG_STATE_HOME=<state>/state dsync pair show --name <peer>
#     and on the phone
#       adb shell /data/local/tmp/dsync-cli/dsync pair accept --name desktop \
#         --state-dir /data/local/tmp/dsync-cli/state <payload>
#     then confirm on the desktop. The desktop dials the phone on 28771, the
#     app's port: stop the app's Serve first.
#   - Seed and grant: push a tree to <root> (synthetic_tree.dart create, then
#     `adb push`), and `dsync pair grant --state-dir ... desktop <root>` on the
#     phone. A grant is for that exact root.
#
# WHAT ONE RUN IS. `<desktop bin> sync <out>/pull/run-NN peer://<peer>:<root>
# --batch --timings` with XDG_STATE_HOME/XDG_CONFIG_HOME under --state. A new
# desktop folder is a new pair, so both archives start empty and every run
# copies the whole tree phone -> desktop; the folder is deleted afterwards. Each
# run leaves one small archive log per side behind in the two state dirs.
#
# Output: <out>/run-NN.txt (each run's full report), <out>/agent-<arm>.log
# (the phone agent's), and summary.txt. The adb device is adb's own choice; set
# ANDROID_SERIAL to pick one.

set -euo pipefail

state=""
peer=""
root=""
pairs=3
out="$HOME/.cache/dsync/scratch/pairs/cli-$(date +%Y-%m-%dT%H-%M-%S)"
arms=()

while (($#)); do
  case "$1" in
    --state) state="$2"; shift 2 ;;
    --peer) peer="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --pairs) pairs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --arm) arms+=("$2"); shift 2 ;;
    *) echo "run_cli_pull: unknown option $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$state" || -z "$peer" || -z "$root" || ${#arms[@]} -ne 2 ]]; then
  echo "run_cli_pull: needs --state, --peer, --root and two --arm name=desktop,phone" >&2
  exit 2
fi

phone_dir=/data/local/tmp/dsync-cli
names=()
desktops=()
phones=()
for arm in "${arms[@]}"; do
  names+=("${arm%%=*}")
  bins="${arm#*=}"
  desktops+=("${bins%%,*}")
  phones+=("${bins#*,}")
done

mkdir -p "$out/pull"
echo "session folder: $out"

# Stops every process running a binary out of $phone_dir. Matched on each
# process's executable, not its command line, so it never matches itself.
stop_agents() {
  adb shell 'for p in /proc/[0-9]*; do case "$(readlink $p/exe 2>/dev/null)" in '"$phone_dir"'/*) kill ${p#/proc/};; esac; done'
}

# Serves with arm $1's phone binary. The adb client that starts the agent
# is left running in the background: killing it takes the agent down with it,
# and it exits by itself once stop_agents stops the agent.
serve_arm() {
  local arm=$1 bin="$phone_dir/dsync-${names[$1]}"
  stop_agents
  adb push "${phones[$arm]}" "$bin" >/dev/null
  adb shell "chmod 755 $bin && rm -f $phone_dir/agent.log"
  adb shell "cd $phone_dir && $bin agent --serve --state-dir $phone_dir/state </dev/null >agent.log 2>&1" &
  for _ in $(seq 50); do
    if adb shell "grep -q 'serving paired devices' $phone_dir/agent.log 2>/dev/null"; then
      return
    fi
    sleep 0.2
  done
  echo "run_cli_pull: the ${names[$arm]} agent did not start" >&2
  adb shell "cat $phone_dir/agent.log" >&2
  exit 1
}

# A --timings duration ("5050.0 ms", "2.3 s", "239 µs") in milliseconds.
to_ms() {
  awk -v n="$1" -v u="$2" 'BEGIN {
    if (u == "s") n *= 1000; else if (u == "µs") n /= 1000;
    printf "%.1f", n }'
}

trap stop_agents EXIT

runs=$((pairs * 2))
current=-1
printf 'run  arm       apply ms   total ms  applied   MiB/s\n' > "$out/summary.txt"
declare -a apply_of
for ((run = 1; run <= runs; run++)); do
  arm=$(((run - 1) % 2))
  if ((arm != current)); then
    if ((current >= 0)); then
      adb shell "cat $phone_dir/agent.log" > "$out/agent-${names[$current]}.log"
    fi
    serve_arm "$arm"
    current=$arm
  fi
  tag=$(printf 'run-%02d' "$run")
  dest="$out/pull/$tag"
  report="$out/$tag.txt"
  XDG_STATE_HOME="$state/state" XDG_CONFIG_HOME="$state/config" \
    "${desktops[$arm]}" sync "$dest" "peer://$peer:$root" --batch --timings \
    > "$report" 2>&1 || true
  rm -r "$dest" 2>/dev/null || true
  if ! grep -q 'failed=0 unreadable=0' "$report"; then
    echo "run_cli_pull: $tag (${names[$arm]}) did not apply cleanly; see $report" >&2
    exit 1
  fi
  read -r value unit < <(awk '$1 == "apply" { print $2, $3; exit }' "$report")
  apply=$(to_ms "$value" "$unit")
  read -r value unit < <(awk '$1 == "run:" { print $2, $3; exit }' "$report")
  total=$(to_ms "$value" "$unit")
  applied=$(sed -n 's/^summary: applied=\([0-9]*\).*/\1/p' "$report")
  mib=$(awk '$1 == "run:" { for (i = 1; i <= NF; i++) if ($i == "MiB") print $(i - 1) }' "$report")
  rate=$(awk -v m="${mib:-0}" -v a="$apply" 'BEGIN { printf "%.1f", (a > 0 ? m / (a / 1000) : 0) }')
  apply_of[$run]=$apply
  line=$(printf '%-4s %-8s %9s %10s %8s %7s' "$run" "${names[$arm]}" "$apply" "$total" "$applied" "$rate")
  echo "$line" | tee -a "$out/summary.txt"
done
adb shell "cat $phone_dir/agent.log" > "$out/agent-${names[$current]}.log"

{
  echo
  echo "per pair, apply ${names[1]} / ${names[0]}"
  for ((pair = 1; pair <= pairs; pair++)); do
    a=${apply_of[$((pair * 2 - 1))]}
    b=${apply_of[$((pair * 2))]}
    awk -v p="$pair" -v a="$a" -v b="$b" 'BEGIN { printf "  pair %d  %.3f\n", p, b / a }'
  done
} | tee -a "$out/summary.txt"
