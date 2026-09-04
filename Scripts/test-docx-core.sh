#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_root/.build/DerivedData"
products="$derived_data/Build/Products/Debug"
test_binary="$repo_root/.build/DocxCoreRegression"

xcodebuild -quiet \
  -project "$repo_root/FreeDocx.xcodeproj" \
  -scheme FreeDocx \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  build

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$repo_root/.build/ModuleCache" \
  -I "$products" \
  "$repo_root/FreeDocx/DocxCore/DocumentPageLayout.swift" \
  "$repo_root/FreeDocx/DocxCore/DocxPackage.swift" \
  "$repo_root/FreeDocx/DocxCore/DocxDocumentModel.swift" \
  "$repo_root/FreeDocx/DocxCore/DocxEditorProjection.swift" \
  "$repo_root/FreeDocx/DocxCore/DocxDocumentSession.swift" \
  "$repo_root/Tests/DocxCoreRegression.swift" \
  "$products/ZIPFoundation.o" \
  -o "$test_binary"

"$test_binary"
