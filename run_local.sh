#!/usr/bin/env bash
set -e

# Setup environment variables for JDK, Android SDK, ADB, and Flutter
export JAVA_HOME="/home/vipulbajaj_dev/development/jdk"
export ANDROID_HOME="/home/vipulbajaj_dev/development/android-sdk"
export ANDROID_SDK_ROOT="/home/vipulbajaj_dev/development/android-sdk"
export GRADLE_USER_HOME="/home/vipulbajaj_dev/.gradle"
export PATH="/home/vipulbajaj_dev/development/flutter/bin:/home/vipulbajaj_dev/development/jdk/bin:/home/vipulbajaj_dev/platform-tools:$PATH"

DEVICE="100.92.234.115:38833"

echo "Checking ADB connection to $DEVICE..."
adb connect "$DEVICE" 2>/dev/null || true

echo "Starting Flutter run on $DEVICE..."
flutter run -d "$DEVICE" "$@"
