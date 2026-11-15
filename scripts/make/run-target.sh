#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <target>"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

flutter_bin="${FLUTTER:-flutter}"
uname_s="${UNAME_S:-$(uname -s)}"
uname_m="${UNAME_M:-$(uname -m)}"
branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
build_id="${BUILD_ID:-$(git rev-parse --short HEAD)}"
build_date="${BUILD_DATE:-$(date '+%Y-%m-%d')}"
macos_app_bundle="${MACOS_APP_BUNDLE:-build/macos/Build/Products/Release/xconnect.app}"
macos_build_lock_dir="${MACOS_BUILD_LOCK_DIR:-build/.macos-build.lock}"
macos_build_lock_pid_file="${MACOS_BUILD_LOCK_PID_FILE:-${macos_build_lock_dir}/pid}"
dmg_tag="$(git describe --tags --exact-match 2>/dev/null || echo "")"
if [[ -n "${DMG_NAME:-}" ]]; then
  dmg_name="$DMG_NAME"
elif [[ -n "$dmg_tag" ]]; then
  dmg_name="xconnect-release-${dmg_tag}.dmg"
elif [[ "$branch" == "main" || "$branch" == "master" ]]; then
  dmg_name="xconnect-latest-${build_id}.dmg"
else
  dmg_name="xconnect-dev-${build_id}.dmg"
fi
common_dart_defines=(
  --dart-define=BRANCH_NAME="$branch"
  --dart-define=BUILD_ID="$build_id"
  --dart-define=BUILD_DATE="$build_date"
)

run_macos_build() {
  local target_arch="$1"
  local expected_machine="$2"
  local human_arch="$3"
  local runtime_arch="$4"
  local make_target="$5"
  local skip_msg="$6"
  local codesign_env=()

  if [[ "${XCONNECT_MACOS_NO_CODESIGN:-0}" == "1" ]]; then
    # CI packaging builds should not require Apple provisioning profiles.
    # Disable Xcode signing so `flutter build macos` can succeed without profiles.
    codesign_env=(
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGN_IDENTITY=
      EXPANDED_CODE_SIGN_IDENTITY=
      CODE_SIGN_STYLE=Manual
      DEVELOPMENT_TEAM=
      PROVISIONING_PROFILE_SPECIFIER=
      PROVISIONING_PROFILE=
    )
  fi

  if [[ "$uname_s" != "Darwin" || "$uname_m" != "$expected_machine" ]]; then
    echo "$skip_msg"
    return 0
  fi

  echo "Building for macOS (${human_arch})..."

  if [[ "${XCONNECT_SKIP_MACOS_BUILD_LOCK:-0}" == "1" ]]; then
    echo "Skipping macOS build lock for CI execution."
  else

    if [[ "$(id -u)" == "0" ]]; then
      if [[ "${XCONNECT_SUDO_DELEGATED:-0}" == "1" ]]; then
        echo "❌ Failed to switch from root to regular user. Please run build as a regular user shell."
        return 1
      fi
      if [[ -z "${SUDO_USER:-}" ]]; then
        echo "❌ Root shell detected without SUDO_USER. Please run: sudo make ${make_target} (from a regular user)."
        return 1
      fi

      echo "↪ Detected sudo mode. Switching build to user: ${SUDO_USER}"
      for path in macos/Flutter/ephemeral ios/Flutter/ephemeral linux/flutter/ephemeral windows/flutter/ephemeral .dart_tool build; do
        if [[ -e "$path" ]]; then
          chown -R "$SUDO_USER" "$path" || true
        fi
      done

      exec sudo -H -u "$SUDO_USER" env \
        XCONNECT_SUDO_DELEGATED=1 \
        PATH="$PATH" \
        FLUTTER="$flutter_bin" \
        UNAME_S="$uname_s" \
        UNAME_M="$uname_m" \
        BRANCH="$branch" \
        BUILD_ID="$build_id" \
        BUILD_DATE="$build_date" \
        DMG_NAME="$dmg_name" \
        MACOS_APP_BUNDLE="$macos_app_bundle" \
        MACOS_BUILD_LOCK_DIR="$macos_build_lock_dir" \
        MACOS_BUILD_LOCK_PID_FILE="$macos_build_lock_pid_file" \
        "$0" "$make_target"
    fi

    if ! mkdir "$macos_build_lock_dir" 2>/dev/null; then
      local lock_pid=""
      local stale_lock=0

      if [[ -f "$macos_build_lock_pid_file" ]]; then
        lock_pid="$(cat "$macos_build_lock_pid_file" 2>/dev/null || true)"
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
          stale_lock=1
        fi
      else
        stale_lock=1
      fi

      if [[ "$stale_lock" == "1" ]]; then
        echo "⚠️ Detected stale macOS build lock. Auto-cleaning: ${macos_build_lock_dir}"
        # Use recursive cleanup to handle unexpected leftover files in lock dir.
        rm -rf "$macos_build_lock_dir" >/dev/null 2>&1 || true
        if ! mkdir "$macos_build_lock_dir" 2>/dev/null; then
          echo "❌ Another macOS build is already running (lock: ${macos_build_lock_dir})."
          if [[ -e "$macos_build_lock_dir" && ! -w "$macos_build_lock_dir" ]]; then
            echo "   Lock exists but is not writable by current user: $(id -un)"
            echo "   Fix permissions, then retry."
          fi
          echo "   Wait for it to finish, then retry."
          return 1
        fi
      else
        echo "❌ Another macOS build is already running (lock: ${macos_build_lock_dir})."
        if [[ -n "$lock_pid" ]]; then
          echo "   Active build PID: ${lock_pid}"
        fi
        echo "   Wait for it to finish, or remove lock after confirming no build process is active."
        return 1
      fi
    fi

    echo "$$" > "$macos_build_lock_pid_file"
    trap 'rm -f "$macos_build_lock_pid_file" >/dev/null 2>&1 || true; rmdir "$macos_build_lock_dir" >/dev/null 2>&1 || true' EXIT INT TERM
  fi

  if ! command -v pod >/dev/null 2>&1; then
    echo "❌ CocoaPods not installed or not in a valid state. Install with: brew install cocoapods"
    return 1
  fi

  if ! pod --version >/dev/null 2>&1; then
    echo "❌ CocoaPods command exists but failed. Reinstall with: brew reinstall cocoapods"
    return 1
  fi


  # Sync Generated.xcconfig so Xcode Archive picks up the correct version from pubspec.yaml.
  echo "Syncing Flutter build config (pubspec.yaml → Generated.xcconfig)..."
  env "${codesign_env[@]}" "$flutter_bin" build macos --config-only

  # Flutter's macOS wrapper can build plugin frameworks for the host architecture
  # while the Xcode project still requests both arm64 and x86_64. Xcode 27 then
  # tries to parse arm64-only generated Swift headers as x86_64 modules and fails
  # with "unsupported Swift architecture". Package each native target explicitly;
  # the universal archive path remains a separate xcodebuild archive workflow.
  # Keep DerivedData outside the product directory. Flutter's generated
  # CocoaPods settings otherwise resolve plugin search paths as
  # build/macos/Build/Intermediates.noindex/Build/Products, which produces
  # stale-file and missing-search-path warnings on Xcode 27.
  echo "Building macOS application via xcodebuild (${human_arch})..."
  xcodebuild \
    -workspace "${ROOT_DIR}/macos/Runner.xcworkspace" \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${ROOT_DIR}/build/macos/DerivedData" \
    CONFIGURATION_BUILD_DIR="${ROOT_DIR}/build/macos/Build/Products/Release" \
    PODS_CONFIGURATION_BUILD_DIR="${ROOT_DIR}/build/macos/Build/Products/Release" \
    ARCHS="${target_arch}" \
    ONLY_ACTIVE_ARCH=YES \
    APP_INTENTS_METADATA_PATH= \
    APP_INTENTS_DEPLOYMENT_POSTPROCESSING=NO \
    "${codesign_env[@]}" \
    2>&1 | sed -E \
      -e '/^Warning: unknown environment variable SWIFT_DEBUG_INFORMATION_(FORMAT|VERSION)$/d' \
      -e '/appintentsmetadataprocessor.*warning: Metadata extraction skipped, no AppIntents\.framework dependency found$/d'

  if [[ ! -d "$macos_app_bundle" ]]; then
    echo "❌ Build finished but app bundle was not found: ${macos_app_bundle}"
    return 1
  fi

  local extension_bridge="${macos_app_bundle}/Contents/PlugIns/PacketTunnel.appex/Contents/Frameworks/libxray_bridge.dylib"
  local app_frameworks="${macos_app_bundle}/Contents/Frameworks"
  if [[ -f "$extension_bridge" ]]; then
    echo "Syncing libxray_bridge.dylib to app Frameworks..."
    mkdir -p "$app_frameworks"
    cp -f "$extension_bridge" "${app_frameworks}/libxray_bridge.dylib"
    chmod 755 "${app_frameworks}/libxray_bridge.dylib"
  fi



  ./scripts/install-runtime-mcp.sh "$macos_app_bundle" "$runtime_arch"

  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "❌ create-dmg not found. Install with: brew install create-dmg"
    return 1
  fi

  if [[ -d "/Volumes/XConnect Installer" ]]; then
    hdiutil detach "/Volumes/XConnect Installer" -force 2>/dev/null || true
  fi
  for m in /Volumes/dmg.*; do
    if [[ -d "$m" ]]; then
      hdiutil detach "$m" -force 2>/dev/null || true
    fi
  done

  mkdir -p build/macos
  rm -f "build/macos/${dmg_name}" "build/macos"/rw.*."${dmg_name}" || true
  create-dmg \
    --filesystem APFS \
    --no-internet-enable \
    --skip-jenkins \
    --hdiutil-quiet \
    --hdiutil-retries 10 \
    --volname "XConnect Installer" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --app-drop-link 600 185 \
    "build/macos/${dmg_name}" \
    "$macos_app_bundle" \
    2> >(sed -E "/^hdiutil: WARNING: .* is deprecated\\. Please use 'diskutil /d" >&2)

  local dmg_path="build/macos/${dmg_name}"
  if [[ ! -f "$dmg_path" ]]; then
    echo "❌ DMG build completed but output file not found: ${dmg_path}" >&2
    return 1
  fi

  # Create stable convenience symlinks for developers and tooling
  ln -sf "${dmg_name}" "build/macos/xconnect.dmg"
  ln -sf "macos/${dmg_name}" "build/xconnect.dmg"

  local dmg_size
  dmg_size="$(ls -lh "$dmg_path" | awk '{print $5}')"
  echo "========================================================"
  echo "✅ macOS DMG package created successfully!"
  echo "   Artifact:  ${dmg_path} (${dmg_size})"
  echo "   Symlinks:  build/macos/xconnect.dmg"
  echo "              build/xconnect.dmg"
  echo "========================================================"
}

run_ios_install() {
  local mode="$1"

  if [[ "$uname_s" != "Darwin" ]]; then
    echo "iOS install is only supported on macOS"
    return 0
  fi

  local device_id="${IOS_DEVICE:-$($flutter_bin devices | awk -F'•' '/• ios[[:space:]]*•/ && first=="" {gsub(/ /,"",$2); first=$2} END {print first}')}"
  device_id="${device_id//[[:space:]]/}"
  if [[ -z "$device_id" ]]; then
    echo "❌ No iOS device found. Connect an iPhone or set IOS_DEVICE=<udid>."
    return 1
  fi

  if [[ "$mode" == "debug" ]]; then
    echo "Installing debug build to iOS device: ${device_id}"
    if [[ "${IOS_NO_RESIDENT:-0}" == "1" ]]; then
      "$flutter_bin" run -d "$device_id" --debug --no-resident "${common_dart_defines[@]}"
    else
      "$flutter_bin" run -d "$device_id" --debug "${common_dart_defines[@]}"
    fi
  else
    echo "Installing release build to iOS device: ${device_id}"
    "$flutter_bin" build ios --release "${common_dart_defines[@]}"
    xcrun devicectl device install app --device "$device_id" build/ios/iphoneos/Runner.app
    xcrun devicectl device process launch --device "$device_id" --terminate-existing plus.svc.xconnect >/dev/null || true
  fi
}

run_mcp() {
  local mode="${MCP_MODE:-dev}"

  case "$mode" in
    bootstrap)
      ./scripts/xcode-debug-bootstrap.sh
      ;;
    doctor)
      ./scripts/xcode-debug-bootstrap.sh
      echo "Xcode MCP workspace paths (recommended):"
      echo "  iOS:   ${ROOT_DIR}/ios/Runner.xcworkspace"
      echo "  macOS: ${ROOT_DIR}/macos/Runner.xcworkspace"
      echo "Note: building .xcodeproj directly may miss CocoaPods plugin modules."
      ;;
    install)
      (cd tools/xconnect-mcp-server && go mod tidy)
      ;;
    start-runtime)
      ./scripts/start-xconnect-runtime-mcp-server.sh
      ;;
    start-dev|start|dev)
      ./scripts/start-xconnect-dev-mcp-server.sh
      ;;
    all)
      ./scripts/xcode-debug-bootstrap.sh
      echo "Xcode MCP workspace paths (recommended):"
      echo "  iOS:   ${ROOT_DIR}/ios/Runner.xcworkspace"
      echo "  macOS: ${ROOT_DIR}/macos/Runner.xcworkspace"
      echo "Note: building .xcodeproj directly may miss CocoaPods plugin modules."
      (cd tools/xconnect-mcp-server && go mod tidy)
      ./scripts/start-xconnect-dev-mcp-server.sh
      ;;
    *)
      echo "Unknown MCP_MODE=${mode}. Use one of: bootstrap, doctor, install, start-dev, start-runtime, all"
      return 1
      ;;
  esac
}

case "$TARGET" in
  windows-icon)
    mkdir -p windows/runner/resources
    magick assets/logo.png -resize 256x256 windows/runner/resources/app_icon.ico
    echo "✅ Windows app_icon.ico generated"
    ;;
  icon)
    "$flutter_bin" pub run flutter_launcher_icons:main
    echo "✅ 图标替换完成！"
    ;;
  fix-macos-signing)
    echo "🧹 Cleaning extended attributes for macOS build..."
    xattr -rc .
    "$flutter_bin" clean
    "$flutter_bin" pub get
    ;;
  macos-intel)
    run_macos_build intel x86_64 Intel amd64 macos-intel "Skipping macOS Intel build (not on Intel architecture)"
    ;;
  macos-arm64)
    run_macos_build arm64 arm64 ARM64 arm64 macos-arm64 "Skipping macOS ARM64 build (not on ARM architecture)"
    ;;
  macos-debug-run)
    if [[ "$uname_s" == "Darwin" ]]; then
      echo "Run XConnect on macOS (debug, no resident)..."
      "$flutter_bin" run -d macos --debug --no-resident "${common_dart_defines[@]}"
    else
      echo "macOS debug run is only supported on macOS"
    fi
    ;;

  windows-x64)
    if [[ "$uname_s" == "Windows_NT" || "${OS:-}" == "Windows_NT" ]]; then
      echo "Building for Windows (native)..."
      ./build_scripts/build_windows.sh
      "$flutter_bin" pub get
      "$flutter_bin" pub outdated
      "$flutter_bin" build windows --release "${common_dart_defines[@]}"
    else
      echo "Windows build only supported on native Windows systems"
    fi
    ;;
  windows-single-file)
    if [[ "$uname_s" == "Windows_NT" || "${OS:-}" == "Windows_NT" ]]; then
      echo "Building single-file Windows launcher..."
      ./build_scripts/build_windows.sh
      "$flutter_bin" pub get
      "$flutter_bin" build windows --release "${common_dart_defines[@]}"
      powershell.exe -ExecutionPolicy Bypass -File ./build_scripts/package_windows_bundle.ps1
      powershell.exe -ExecutionPolicy Bypass -File ./build_scripts/package_windows_single_file.ps1
    else
      echo "Windows build only supported on native Windows systems"
    fi
    ;;
  linux-x64)
    if [[ "$uname_s" == "Linux" ]]; then
      echo "Building for Linux x64..."
      ./build_scripts/build_linux.sh
      "$flutter_bin" build linux --release --target-platform=linux-x64 "${common_dart_defines[@]}"
      mv build/linux/x64/release/bundle/xconnect build/linux/x64/release/bundle/xconnect-x64
    else
      echo "Linux x64 build only supported on Linux systems"
    fi
    ;;
  linux-package-deb)
    if [[ "$uname_s" == "Linux" ]]; then
      "$0" linux-x64
      ./build_scripts/package_linux_deb.sh
    else
      echo "Linux packaging is only supported on Linux systems"
    fi
    ;;
  linux-package-rpm)
    if [[ "$uname_s" == "Linux" ]]; then
      "$0" linux-x64
      ./build_scripts/package_linux_rpm.sh
    else
      echo "Linux packaging is only supported on Linux systems"
    fi
    ;;
  linux-arm64)
    if [[ "$uname_s" == "Linux" ]]; then
      if [[ "$uname_m" == "aarch64" || "$uname_m" == "arm64" ]]; then
        echo "Building for Linux arm64..."
        "$flutter_bin" build linux --release --target-platform=linux-arm64 "${common_dart_defines[@]}"
        mv build/linux/arm64/release/bundle/xconnect build/linux/arm64/release/bundle/xconnect-arm64
      else
        echo "❌ Cross-build from x64 to arm64 is not supported. Please run this on an arm64 host."
      fi
    else
      echo "Linux arm64 build only supported on Linux systems"
    fi
    ;;
  android-arm64)
    if [[ "$uname_s" == "Linux" || "$uname_s" == "Darwin" ]]; then
      echo "Building for Android arm64..."
      ./build_scripts/build_android_xray.sh
      "$flutter_bin" build apk --release "${common_dart_defines[@]}"
    else
      echo "Android build not supported on this platform"
    fi
    ;;
  android-libxray)
    ./build_scripts/build_android_xray.sh
    ;;
  android-apk)
    ./build_scripts/build_android_apk.sh
    ;;
  ios-arm64)
    if [[ "$uname_s" == "Darwin" ]]; then
      echo "Building for iOS arm64..."
      "$flutter_bin" build ios --release --no-codesign "${common_dart_defines[@]}"
      (cd build/ios/iphoneos && zip -r xconnect.app.zip Runner.app)
    else
      echo "iOS build only supported on macOS"
    fi
    ;;
  ios-ipa)
    ./build_scripts/build_ios_ipa.sh
    ;;
  ios-install-debug)
    run_ios_install debug
    ;;
  ios-install-release)
    run_ios_install release
    ;;
  ios-deploy-device)
    ./build_scripts/deploy_ios_device.sh
    ;;
  xcode-debug-bootstrap)
    MCP_MODE=bootstrap run_mcp
    ;;
  xcode-mcp-doctor)
    MCP_MODE=doctor run_mcp
    ;;
  xconnect-mcp-install)
    MCP_MODE=install run_mcp
    ;;
  xconnect-mcp-start|xconnect-mcp-start-dev)
    MCP_MODE=start-dev run_mcp
    ;;
  xconnect-mcp-start-runtime)
    MCP_MODE=start-runtime run_mcp
    ;;
  sync-macos-config)
    # Sync Generated.xcconfig from pubspec.yaml without building.
    # Run this before doing a manual Xcode Archive to ensure the version is correct.
    echo "Syncing Flutter build config (pubspec.yaml → Generated.xcconfig)..."
    "$flutter_bin" build macos --config-only
    "$flutter_bin" build ios --config-only --no-codesign
    echo "✅ Config synced. Xcode Archive will now use the correct version."
    ;;
  mcp)
    run_mcp
    ;;
  clean)
    echo "Cleaning build outputs..."
    "$flutter_bin" clean
    rm -rf macos/Flutter/ephemeral
    xattr -rc .
    ;;
  *)
    echo "Unknown target: $TARGET"
    exit 1
    ;;
esac
