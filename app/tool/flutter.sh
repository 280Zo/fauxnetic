#!/usr/bin/env bash
# The only way to run Flutter in this repo. Keeps the Android SDK, pub cache and Gradle home
# under <repo>/tools so nothing is written to user-level config or caches.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ANDROID_HOME="$REPO/tools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PUB_CACHE="$REPO/tools/pub-cache"
export GRADLE_USER_HOME="$REPO/tools/gradle-home"
export FLUTTER_SUPPRESS_ANALYTICS=true
# Gradle cannot run on the system JDK 27; use the project-local Temurin 21 when present.
if [ -x "$REPO/tools/jdk-21/bin/java" ]; then
  export JAVA_HOME="$REPO/tools/jdk-21"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

FLUTTER="$REPO/tools/flutter/bin/flutter"
MARKER="$REPO/tools/flutter/.analytics-disabled"
if [ ! -f "$MARKER" ]; then
  "$FLUTTER" --disable-analytics >/dev/null
  touch "$MARKER"
fi
exec "$FLUTTER" "$@"
