#!/usr/bin/env bash
# Builds, pushes, sweeps and cleans up `storage_probe.c` on a connected Android
# device (tasks 4c55fd, 203cfd). Not part of the build.
#
# WHY A SCRIPT AND NOT A HEAD. The probe needs no APK, no install and no taps: a
# static aarch64 binary runs on bionic under `adb shell`, so the whole
# measurement is one command whose output lands in the terminal. That is the
# point — a device figure that has to be read off a screen and retyped gets
# measured once and never again.
#
#   benchmark/device/run_storage_probe.sh --source ~/some/tree
#   benchmark/device/run_storage_probe.sh --source ~/some/tree \
#     --rungs full --depths 1,2,4,8,16,32
#
# --source is a tree on *this* machine, read for its file-size distribution
# only; nothing under it is touched. Cost on the device is per-file dominated
# and byte-weighted by a tail, so the distribution is what has to be right.
#
# --cap clamps every file size, so `--cap 65536` puts every write inside one
# 64 KiB chunk and tells you whether a difference between `bare` and `chunked`
# comes from the distribution's tail or from every file.
#
# --limit subsamples that distribution by taking a stride over the size-sorted
# list, which keeps its shape rather than its head — a prefix of a real tree
# reported a mean +113% out (task 9d2158 §14). It defaults low because every
# rung × depth writes the whole corpus once.
#
# THE TREE IS SEEDED FIRST, untimed, so every timed rung overwrites a file that
# is already there. Without that the first rung in the list pays for creating the
# whole corpus — which is how an early version of this had `bare` at 16.2 ms a
# file against `chunked`'s 2.9 when the two issue the same syscall for any file
# under one chunk. `bare` and `chunked` agreeing under `--cap 65536` is the
# control for it; the cost of a *new* file is the `create` rung's job.
#
# BOTH MOUNTS BY DEFAULT, and that comparison is the main event. On Android
# `/storage/emulated` is a FUSE mount and `/data/local/tmp` is the block device
# directly, so running the same rung on both separates what the flash costs from
# what Android's emulated-storage layer adds on top. The app writes to the
# former.
#
# Nothing here touches an installed app, its data, or any granted permission.
set -euo pipefail

source_tree=""
limit=2000
cap=0
rungs="bare,chunked,create,temp,temp-reuse,temp-named,temp-dir-fresh,temp-dir-reuse,mtime,mode,full,fsync,statonly"
depths="1"
mounts="fuse,data"
keep=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_tree="$2"; shift 2 ;;
    --limit)  limit="$2";  shift 2 ;;
    --cap)    cap="$2";    shift 2 ;;
    --rungs)  rungs="$2";  shift 2 ;;
    --depths) depths="$2"; shift 2 ;;
    --mounts) mounts="$2"; shift 2 ;;
    --keep)   keep=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$source_tree" || ! -d "$source_tree" ]]; then
  echo "usage: $0 --source <dir> [--limit N] [--rungs a,b] [--depths 1,4] [--mounts fuse,data] [--keep]" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "building for aarch64 (static, so it needs no interpreter on bionic)"
aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra \
  -o "$work/storage_probe" "$here/storage_probe.c" -lpthread

# Stride over the size-sorted list: systematic sampling on the order statistic,
# which preserves the distribution's shape far better than a prefix does.
find "$source_tree" -type f -printf '%s\n' | sort -n > "$work/all_sizes.txt"
total=$(wc -l < "$work/all_sizes.txt")
if (( total == 0 )); then echo "no files under $source_tree" >&2; exit 2; fi
stride=$(( total / limit )); (( stride < 1 )) && stride=1
awk -v s="$stride" 'NR % s == 0' "$work/all_sizes.txt" > "$work/strided.txt"
# --cap clamps every size. `--cap 65536` is the one that matters: at or under the
# 64 KiB chunk, `bare` and `chunked` issue the same single write(), so a gap that
# survives capping is not about large files and one that vanishes is.
if (( cap > 0 )); then
  awk -v c="$cap" '{print ($1 > c) ? c : $1}' "$work/strided.txt" > "$work/sizes.txt"
else
  cp "$work/strided.txt" "$work/sizes.txt"
fi
files=$(wc -l < "$work/sizes.txt")
bytes=$(awk '{t+=$1} END{print t+0}' "$work/sizes.txt")

printf 'corpus: %s files, %.1f MiB, mean %d B (strided 1/%d of %d under %s)\n' \
  "$files" "$(awk -v b="$bytes" 'BEGIN{print b/1048576}')" \
  "$(( bytes / files ))" "$stride" "$total" "$source_tree"
if (( cap > 0 )); then echo "        every size capped at $cap B"; fi

remote=/data/local/tmp/dsync-probe
adb shell "mkdir -p $remote" >/dev/null
adb push -q "$work/storage_probe" "$remote/storage_probe" >/dev/null 2>&1 \
  || adb push "$work/storage_probe" "$remote/storage_probe" >/dev/null
adb push "$work/sizes.txt" "$remote/sizes.txt" >/dev/null
adb shell "chmod 755 $remote/storage_probe"

declare -A dest
dest[fuse]=/storage/emulated/0/Download/dsync-probe-tree
dest[data]=/data/local/tmp/dsync-probe-tree

printf '\n  %-6s %-14s %6s %9s %11s %10s\n' mount rung depth "µs a file" "MiB/s" ms
for mount in ${mounts//,/ }; do
  tree="${dest[$mount]}"
  adb shell "$remote/storage_probe mkdirs 1 $tree $remote/sizes.txt" >/dev/null
  # Untimed, and the reason every rung below is comparable: without it the first
  # rung pays for creating the tree and reads as an order slower than the rest.
  adb shell "$remote/storage_probe seed 1 $tree $remote/sizes.txt" >/dev/null
  for rung in ${rungs//,/ }; do
    for depth in ${depths//,/ }; do
      line=$(adb shell "$remote/storage_probe $rung $depth $tree $remote/sizes.txt")
      eval "${line//$'\r'/}"
      # shellcheck disable=SC2154
      printf '  %-6s %-14s %6s %9s %11s %10s\n' \
        "$mount" "$rung" "$depth" \
        "$(awk -v m="$ms" -v f="$files" 'BEGIN{printf "%.0f", m*1000/f}')" \
        "$(awk -v b="$bytes" -v m="$ms" 'BEGIN{printf "%.1f", (m>0) ? b/1048576/(m/1000) : 0}')" \
        "$ms"
      if [[ "${failures:-0}" != "0" ]]; then
        echo "    $failures of $files failed on $mount/$rung" >&2
      fi
    done
  done
done

if (( keep == 0 )); then
  for mount in ${mounts//,/ }; do adb shell "rm -rf ${dest[$mount]}"; done
  adb shell "rm -rf $remote"
  echo
  echo "removed the probe and both trees from the device"
fi
