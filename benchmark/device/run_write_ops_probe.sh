#!/usr/bin/env bash
# Builds, pushes and sweeps `write_ops_probe.c` on a connected Android device
# (task 4759eb). Not part of the build. Needs no APK and touches no app data.
#
#   benchmark/device/run_write_ops_probe.sh
#   benchmark/device/run_write_ops_probe.sh --threads 1,4,16,32 --repeats 2
#
# Every repeat runs every thread count once — a fresh write into a tree the
# runner has just removed (untimed), then an overwrite of it — in an order
# rotated by one per repeat, so a drift over the run does not land on one count.
# Output is the probe's own RESULT and OP lines, prefixed with the mount.
set -euo pipefail

threads="1,4,16,32"
repeats=2
files=1500
mounts="fuse,data"
layout=grouped
passes="fresh,overwrite"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads) threads="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --files)   files="$2";   shift 2 ;;
    --mounts)  mounts="$2";  shift 2 ;;
    --layout)  layout="$2";  shift 2 ;;
    --passes)  passes="$2";  shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra \
  -o "$work/write_ops_probe" "$here/write_ops_probe.c" -lpthread -lm

remote=/data/local/tmp/dsync-wops
adb shell "mkdir -p $remote" >/dev/null
adb push "$work/write_ops_probe" "$remote/write_ops_probe" >/dev/null
adb shell "chmod 755 $remote/write_ops_probe"

declare -A dest
dest[fuse]=/storage/emulated/0/Download/dsync-wops-tree
dest[data]=/data/local/tmp/dsync-wops-tree

IFS=, read -r -a counts <<< "$threads"
for (( r = 0; r < repeats; r++ )); do
  for mount in ${mounts//,/ }; do
    tree="${dest[$mount]}"
    for (( i = 0; i < ${#counts[@]}; i++ )); do
      t="${counts[$(( (i + r) % ${#counts[@]} ))]}"
      adb shell "rm -rf $tree"
      for pass in ${passes//,/ }; do
        adb shell "$remote/write_ops_probe $t $tree $files $pass 13007 $layout" \
          | tr -d '\r' | sed "s/^/mount=$mount repeat=$r /"
      done
    done
  done
done

for mount in ${mounts//,/ }; do adb shell "rm -rf ${dest[$mount]}"; done
adb shell "rm -rf $remote"
