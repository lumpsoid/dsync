#!/usr/bin/env bash
# Runs every gate CI runs (.github/workflows/test.yml), in its order, and
# stops at the first failure. From anywhere in the repo:
#
#   scripts/check.sh
#
# cargo-deny runs only where it is installed (`cargo install cargo-deny`);
# CI always runs it.
set -euo pipefail

cd "$(dirname "$0")/.."

step() {
  echo
  echo "check: $*"
}

step "version files agree"
scripts/version.sh check

step "flutter pub get"
flutter pub get
step "dart analyze"
dart analyze
step "flutter test"
flutter test

cd native
step "cargo fmt --check"
cargo fmt --check
step "cargo clippy"
cargo clippy --workspace --all-targets -- -D warnings
step "cargo build"
cargo build --workspace --all-targets
step "cargo test"
cargo test --workspace
step "dsync-domain has no tokio dependency"
if cargo tree -p dsync-domain -e normal | grep -q tokio; then
  echo "check: dsync-domain depends on tokio; it must stay pure (SPEC §13)." >&2
  exit 1
fi

if cargo deny --version >/dev/null 2>&1; then
  step "cargo deny check advisories"
  cargo deny check advisories
else
  echo
  echo "check: cargo-deny not installed; skipping advisories (CI runs them)."
fi

echo
echo "check: all gates passed."
