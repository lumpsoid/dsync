#!/usr/bin/env bash
# Builds, pushes, sweeps and cleans up `backup_probe/` (Rust) on a connected
# Android device: what keeping a file's old version costs before the write in
# place overwrites it, per place the old version could go. The rungs are
# described in backup_probe/src/main.rs. Not part of the build.
#
#   benchmark/device/run_backup_probe.sh --source ~/some/tree
#   benchmark/device/run_backup_probe.sh --source ~/some/tree \
#     --mounts fuse --workers 16 --repeats 1
#
# --source is a tree on *this* machine, read for its file-size distribution
# only. Nothing under it is touched. --limit is the corpus size exactly: the
# sorted sizes are resampled evenly to that many, fewer or more than the
# source has, so the distribution keeps its shape either way.
#
# WHERE THE REPLICA IS (--mounts):
#   fuse     /storage/emulated/0/Download: FUSE, where the app writes.
#   data     /data/local/tmp: the block device, the control.
#   appdata  /storage/emulated/0/Android/data/<no app>: whether this path
#            skips FUSE on this device. Named after no installed package, so
#            no app's own directory is touched.
#   appmedia /storage/emulated/0/Android/media/<no app>: the same question for
#            the media folder, which is not bind-mounted around FUSE the way
#            Android/data and Android/obb are.
#
# WHERE THE OLD VERSION GOES (--stores):
#   same     beside the replica, on its mount. The only store rename-aside
#            can use.
#   data     /data/local/tmp, standing in for the app's private storage.
#   appdata  Android/data/<no app>/store: not FUSE, and reachable by the
#            system file manager.
# Any of them with `-flat` puts every version in one directory instead of a
# tree mirroring the replica's (copy-aside and rename-aside; SQLite is one
# file either way).
#
# Every timed rung starts from a cold cache: `evict` (or, with root, a
# drop_caches) runs before it, and the store is emptied. `read-warm` is `read`
# again straight after `read`, to show whether eviction took on this mount.
# Rung order is rotated each repeat. Estimate before running: at one worker a
# FUSE create is ~20 ms, so a create-based rung over 1,000 files is ~20 s.
#
# Output: one row per reading, then medians. Per-step columns are the mean
# time one file spent in that step (workers overlap, so they can sum past the
# wall-clock µs a file).
#
# Nothing here touches an installed app, its data, or any granted permission.
set -euo pipefail

source_tree=""
limit=1000
cap=0
rungs="overwrite,read,read-overwrite,copy-aside,sqlite,rename-aside"
workers="1,16"
mounts="fuse,data,appdata"
stores="same,data"
syncs="none,full"
repeats=3
keep=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)  source_tree="$2"; shift 2 ;;
    --limit)   limit="$2"; shift 2 ;;
    --cap)     cap="$2"; shift 2 ;;
    --rungs)   rungs="$2"; shift 2 ;;
    --workers) workers="$2"; shift 2 ;;
    --mounts)  mounts="$2"; shift 2 ;;
    --stores)  stores="$2"; shift 2 ;;
    --syncs)   syncs="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --keep)    keep=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$source_tree" || ! -d "$source_tree" ]]; then
  echo "usage: $0 --source <dir> [--limit N] [--cap B] [--rungs a,b] [--workers 1,16]" >&2
  echo "          [--mounts fuse,data,appdata] [--stores same,data] [--syncs none,full]" >&2
  echo "          [--repeats N] [--keep]" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ndk_bin="$(echo /opt/android-ndk/toolchains/llvm/prebuilt/*/bin)"
echo "building for aarch64-linux-android"
(
  cd "$here/backup_probe"
  CC_aarch64_linux_android="$ndk_bin/aarch64-linux-android30-clang" \
  AR_aarch64_linux_android="$ndk_bin/llvm-ar" \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ndk_bin/aarch64-linux-android30-clang" \
    cargo build --release --quiet --target aarch64-linux-android
)
binary="$here/backup_probe/target/aarch64-linux-android/release/backup-probe"

find "$source_tree" -type f -printf '%s\n' | sort -n > "$work/all_sizes.txt"
total=$(wc -l < "$work/all_sizes.txt")
if (( total == 0 )); then echo "no files under $source_tree" >&2; exit 2; fi
awk -v n="$limit" -v t="$total" -v c="$cap" '
  { s[NR] = $1 }
  END { for (i = 0; i < n; i++) { v = s[int(i * t / n) + 1]
          print (c > 0 && v > c) ? c : v } }' "$work/all_sizes.txt" > "$work/sizes.txt"
files=$(wc -l < "$work/sizes.txt")
bytes=$(awk '{t+=$1} END{print t+0}' "$work/sizes.txt")
printf 'corpus: %s files, %.1f MiB, mean %d B (resampled from %d under %s)\n' \
  "$files" "$(awk -v b="$bytes" 'BEGIN{print b/1048576}')" \
  "$(( bytes / files ))" "$total" "$source_tree"

remote=/data/local/tmp/dsync-backup-probe
adb shell "mkdir -p $remote" >/dev/null
adb push "$binary" "$remote/backup-probe" >/dev/null
adb push "$work/sizes.txt" "$remote/sizes.txt" >/dev/null
adb shell "chmod 755 $remote/backup-probe"
probe="$remote/backup-probe"
sizes="$remote/sizes.txt"

if adb shell "su -c 'echo 3 > /proc/sys/vm/drop_caches'" >/dev/null 2>&1; then
  cold="root"; echo "cache: dropped with root before every rung, plus evict"
else
  cold="fadvise"; echo "cache: no root; evict (fsync + fadvise DONTNEED) before every rung"
fi

declare -A tree_of
tree_of[fuse]=/storage/emulated/0/Download/dsync-backup-probe
tree_of[data]=/data/local/tmp/dsync-backup-probe-tree
tree_of[appdata]=/storage/emulated/0/Android/data/dsync.backup.probe/files
tree_of[appmedia]=/storage/emulated/0/Android/media/dsync.backup.probe/files

# Cold, and nothing left over from the last reading in the store.
prepare() { # tree store
  adb shell "rm -rf $2" >/dev/null
  adb shell "$probe evict $1 $sizes" >/dev/null
  if [[ $cold == root ]]; then
    adb shell "su -c 'sync; echo 3 > /proc/sys/vm/drop_caches'" >/dev/null
  fi
}

reading() { # mount store sync rung workers repeat tree store-path
  # `-` labels a rung the setting does not apply to; `read-warm` is `read`.
  local line sync="${3/#-/none}" rung="${4%-warm}"
  local layout=mirror
  [[ $2 == *-flat ]] && layout=flat
  line=$(adb shell "$probe run $rung $5 $7 $sizes $8 $layout $sync" | tr -d '\r')
  # Only the fields read below: the line also says `workers=` and `rung=`,
  # which would overwrite the sweep's own.
  local ms read_us store_us write_us failures field
  for field in $line; do
    case "$field" in
      ms=*|read_us=*|store_us=*|write_us=*|failures=*) local "$field" ;;
    esac
  done
  printf '%-8s %-12s %-4s %-14s %3s %2s %9s %8s %8s %8s %6s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" \
    "$(( ms * 1000 / files ))" "$(( read_us / files ))" \
    "$(( store_us / files ))" "$(( write_us / files ))" "$failures" \
    | tee -a "$work/rows.txt"
}

printf '\n%-8s %-12s %-4s %-14s %3s %2s %9s %8s %8s %8s %6s\n' \
  mount store sync rung w rep "µs a file" read store write failed
IFS=, read -ra rung_list <<< "$rungs"
for mount in ${mounts//,/ }; do
  tree="${tree_of[$mount]}"
  if ! adb shell "mkdir -p $tree && $probe seed $tree $sizes" >/dev/null 2>&1; then
    echo "skipping $mount: cannot write $tree" >&2
    continue
  fi
  for (( rep = 1; rep <= repeats; rep++ )); do
    shift_by=$(( (rep - 1) % ${#rung_list[@]} ))
    order=("${rung_list[@]:shift_by}" "${rung_list[@]:0:shift_by}")
    for rung in "${order[@]}"; do
      for w in ${workers//,/ }; do
        for store in ${stores//,/ }; do
          case "$rung" in
            copy-aside|sqlite|rename-aside) ;;
            *) [[ $store == "${stores%%,*}" ]] || continue; store=- ;;
          esac
          [[ $rung == rename-aside && ${store%-flat} != same ]] && continue
          [[ $rung == sqlite && $store == *-flat ]] && continue
          [[ $mount == data && ${store%-flat} == data ]] && continue
          [[ $mount == appdata && ${store%-flat} == appdata ]] && continue
          case "${store%-flat}" in
            data)    store_path=/data/local/tmp/dsync-backup-probe-store ;;
            appdata) store_path=/storage/emulated/0/Android/data/dsync.backup.probe/store ;;
            *)       store_path="$tree-store" ;;
          esac
          for sync in ${syncs//,/ }; do
            case "$rung" in
              copy-aside|sqlite) ;;
              *) [[ $sync == "${syncs%%,*}" ]] || continue; sync=- ;;
            esac
            prepare "$tree" "$store_path"
            reading "$mount" "$store" "$sync" "$rung" "$w" "$rep" "$tree" "$store_path"
            if [[ $rung == read ]]; then
              reading "$mount" "$store" "$sync" read-warm "$w" "$rep" "$tree" "$store_path"
            fi
          done
        done
      done
    done
  done
done

echo
echo "medians over repeats (µs a file; read/store/write are per-step means)"
printf '%-8s %-12s %-4s %-14s %3s %9s %8s %8s %8s\n' \
  mount store sync rung w "µs a file" read store write
sort -k1,1 -k4,4 -k2,2 -k3,3 -k5,5n "$work/rows.txt" | awk '
  function median(s,   a, n) { n = split(s, a, " "); asort(a); return a[int((n + 1) / 2)] }
  { key = sprintf("%-8s %-12s %-4s %-14s %3s", $1, $2, $3, $4, $5)
    if (!(key in seen)) { seen[key] = 1; keys[++k] = key }
    t[key] = t[key] " " $7; r[key] = r[key] " " $8
    s[key] = s[key] " " $9; w[key] = w[key] " " $10 }
  END { for (i = 1; i <= k; i++) { key = keys[i]
    printf "%s %9s %8s %8s %8s\n", key, median(t[key]), median(r[key]),
      median(s[key]), median(w[key]) } }'

if (( keep == 0 )); then
  for mount in ${mounts//,/ }; do
    adb shell "rm -rf ${tree_of[$mount]} ${tree_of[$mount]}-store" >/dev/null
  done
  adb shell "rm -rf /storage/emulated/0/Android/data/dsync.backup.probe \
    /storage/emulated/0/Android/media/dsync.backup.probe \
    /data/local/tmp/dsync-backup-probe-store $remote" >/dev/null
  echo
  echo "removed the probe, its trees and its stores from the device"
fi
