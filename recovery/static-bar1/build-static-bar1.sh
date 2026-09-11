#!/usr/bin/env bash
# Build the preserved CMP unlock source in Static BAR1 mode. Does not install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/recovery/mailbox-b2/source"
WORK="$ROOT/recovery/static-bar1/work"

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ -x "$SOURCE/driver/build.sh" ]] || { echo "Missing preserved source: $SOURCE" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$SOURCE/." "$WORK/"

# 0011 selects BAR1. 0012 reverses it to mailbox/default and must be absent.
rm -f "$WORK/driver/patches/0012-mailbox-default.patch"

# The preserved recovery tree predates the 610.57.04 port. The exact current
# Static BAR1 tree differs only by this supported-version entry and by omitting
# 0012 above; keep the original recovery source itself untouched.
grep -qxF '610.57.04' "$WORK/driver/VERSION" || echo '610.57.04' >> "$WORK/driver/VERSION"

export CMPUNLOCKER_DRIVER_VERSION="${CMPUNLOCKER_DRIVER_VERSION:-610.57.04}"
export CMPUNLOCKER_KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
export CMPUNLOCKER_ENABLE_P2P=1
export CMPUNLOCKER_BUILD_DIR="$WORK/.build"

exec "$WORK/driver/build.sh"
