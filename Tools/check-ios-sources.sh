#!/bin/bash
# Apple SDK typecheck without requiring AppleProductTypes, signing, or a device.
set -eu
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
modules="$(mktemp -d "${TMPDIR:-/tmp}/stencil-ios-modules.XXXXXX")"
target="arm64-apple-ios17.0-simulator"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target "$target" -sdk "$sdk" \
  -parse-as-library -emit-module -module-name StencilCore \
  -emit-module-path "$modules/StencilCore.swiftmodule" StencilStudio.swiftpm/Core/*.swift
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target "$target" -sdk "$sdk" \
  -parse-as-library -typecheck -I "$modules" StencilStudio.swiftpm/App/*.swift
echo "StencilCore and iPad app sources passed iOS 17 simulator SDK typechecking."
