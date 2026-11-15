#!/usr/bin/env bash
set -euox pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  echo "[xray-bridge] skip non-macos platform: ${PLATFORM_NAME:-unknown}"
  exit 0
fi

# Xcode does not load the user's shell startup files, so the Go installation
# used by the terminal may not be present in PATH. Keep the inherited PATH,
# then probe it and the common installation locations explicitly.
GO_BIN=""
if command -v go >/dev/null 2>&1; then
  GO_BIN="$(command -v go)"
fi

if [[ -z "${GO_BIN}" && -n "${GOROOT:-}" && -x "${GOROOT}/bin/go" ]]; then
  GO_BIN="${GOROOT}/bin/go"
fi

for candidate in \
  "${HOME:-}/.local/devtools/go/bin/go" \
  "/opt/homebrew/bin/go" \
  "/usr/local/bin/go"; do
  if [[ -z "${GO_BIN}" && -x "${candidate}" ]]; then
    GO_BIN="${candidate}"
  fi
done

if [[ -z "${GO_BIN}" ]]; then
  echo "error: go command not found. Install Go or expose it through PATH/GOROOT." >&2
  exit 1
fi

echo "[xray-bridge] using Go: ${GO_BIN}"

ROOT_DIR="${SRCROOT}/.."
GO_CORE_DIR="${ROOT_DIR}/go_core"
OUTPUT_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
OUTPUT_LIB="${OUTPUT_DIR}/libxray_bridge.dylib"
TMP_OUT_DIR="${TARGET_TEMP_DIR}/xray-bridge"
TMP_LIB="${TMP_OUT_DIR}/libxray_bridge.dylib"

if [[ ! -d "${GO_CORE_DIR}" ]]; then
  echo "error: go_core directory not found: ${GO_CORE_DIR}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${TMP_OUT_DIR}"

ARCH="${CURRENT_ARCH:-}"
if [[ -z "${ARCH}" || "${ARCH}" == "undefined_arch" ]]; then
  ARCH="${NATIVE_ARCH_ACTUAL:-}"
fi
if [[ -z "${ARCH}" || "${ARCH}" == "undefined_arch" ]]; then
  ARCH="$(echo "${ARCHS:-}" | awk '{print $1}')"
fi
if [[ -z "${ARCH}" || "${ARCH}" == "undefined_arch" ]]; then
  ARCH="$(uname -m)"
fi
if [[ "${ARCH}" == "x86_64h" ]]; then
  ARCH="x86_64"
fi

BUILD_ARCHS="${ARCH}"
if [[ "${ONLY_ACTIVE_ARCH:-NO}" != "YES" && -n "${ARCHS:-}" ]]; then
  BUILD_ARCHS="${ARCHS}"
fi
SLICE_LIBS=()
for slice_arch in ${BUILD_ARCHS}; do
case "${slice_arch}" in
  arm64) go_arch=arm64 ;;
  x86_64|x86_64h) slice_arch=x86_64; go_arch=amd64 ;;
  *) echo "error: unsupported bridge architecture: ${slice_arch}" >&2; exit 1 ;;
esac
SLICE_LIB="${TMP_OUT_DIR}/libxray_bridge-${slice_arch}.dylib"
echo "[xray-bridge] building for darwin/${slice_arch} -> ${SLICE_LIB}"
(
  cd "${GO_CORE_DIR}"
  export CGO_ENABLED=1
  export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
  export GOOS=darwin
  export GOARCH="${go_arch}"
  export CC="$(xcrun --sdk macosx --find clang)"
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
  export CGO_CFLAGS="-arch ${slice_arch} -isysroot $(xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
  export CGO_LDFLAGS="${CGO_CFLAGS}"
  "$GO_BIN" mod download
  "$GO_BIN" build -trimpath -buildmode=c-shared -o "${SLICE_LIB}" .
)
SLICE_LIBS+=("${SLICE_LIB}")
done

if [[ ${#SLICE_LIBS[@]} -gt 1 ]]; then
  xcrun lipo -create "${SLICE_LIBS[@]}" -output "${TMP_LIB}"
else
  cp -f "${SLICE_LIBS[0]}" "${TMP_LIB}"
fi

if [[ ! -f "${TMP_LIB}" ]]; then
  echo "error: failed to build ${TMP_LIB}" >&2
  exit 1
fi

# A build constraint that silently drops the bridge sources still produces a
# valid dylib, so the appex only fails at dlsym time. Fail the build instead.
for required_symbol in _StartXrayTunnelWithFd _StopXrayTunnel _FreeXrayTunnel _GetLastXrayTunnelError; do
  if ! nm -gU "${TMP_LIB}" | grep -q " T ${required_symbol}$"; then
    echo "error: ${TMP_LIB} does not export ${required_symbol}" >&2
    exit 1
  fi
done

cp -f "${TMP_LIB}" "${OUTPUT_LIB}"

if [[ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]] && /usr/bin/otool -l "${OUTPUT_LIB}" | /usr/bin/grep '__debug_info' >/dev/null; then
  echo "[xray-bridge] generating dSYM at ${DWARF_DSYM_FOLDER_PATH}/libxray_bridge.dylib.dSYM"
  mkdir -p "${DWARF_DSYM_FOLDER_PATH}"
  dsymutil "${OUTPUT_LIB}" -o "${DWARF_DSYM_FOLDER_PATH}/libxray_bridge.dylib.dSYM"
fi

rm -f "${OUTPUT_DIR}/libxray_bridge.h"
chmod 755 "${OUTPUT_LIB}"

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -n "${SIGN_IDENTITY}" && "${SIGN_IDENTITY}" != "-" ]]; then
  echo "[xray-bridge] signing with identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-unknown}"
  /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${OUTPUT_LIB}"
fi

if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
  for app_name in xconnect.app XConnect.app; do
    target_app="${BUILT_PRODUCTS_DIR}/${app_name}"
    if [[ -d "${target_app}" ]]; then
      app_frameworks="${target_app}/Contents/Frameworks"
      mkdir -p "${app_frameworks}"
      cp -f "${OUTPUT_LIB}" "${app_frameworks}/libxray_bridge.dylib"
      chmod 755 "${app_frameworks}/libxray_bridge.dylib"
      if [[ -n "${SIGN_IDENTITY}" && "${SIGN_IDENTITY}" != "-" ]]; then
        /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${app_frameworks}/libxray_bridge.dylib"
      fi
    fi
  done
fi

echo "[xray-bridge] built: ${OUTPUT_LIB}"
