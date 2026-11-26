#!/bin/bash
# Builds the parts of Open CASCADE Technology (OCCT) that read STEP and IGES files, as static libraries for the
# iPhone and the iPhone simulator, into Vendor/occt, where the Xcode project links them from (App/CADMesh.cpp).
# GitHub Actions runs this on a Mac when its cache has no copy yet; a change to this file builds a new copy.
set -euo pipefail

VERSION=V7_9_3
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/occt"
OUT="$ROOT/Vendor/occt"
JOBS="$(sysctl -n hw.ncpu)"

cmake --version | head -1
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
git clone --quiet --depth 1 --branch "$VERSION" https://github.com/Open-Cascade-SAS/OCCT.git "$WORK/source"

for sdk in iphoneos iphonesimulator; do
  # Only the STEP and IGES readers and the mesher; OCCT adds the toolkits they need.
  cmake -S "$WORK/source" -B "$WORK/$sdk" -G "Unix Makefiles" \
    -D CMAKE_SYSTEM_NAME=iOS \
    -D CMAKE_OSX_SYSROOT="$sdk" \
    -D CMAKE_OSX_ARCHITECTURES=arm64 \
    -D CMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -D CMAKE_BUILD_TYPE=Release \
    -D BUILD_LIBRARY_TYPE=Static \
    -D BUILD_MODULE_FoundationClasses=OFF \
    -D BUILD_MODULE_ModelingData=OFF \
    -D BUILD_MODULE_ModelingAlgorithms=OFF \
    -D BUILD_MODULE_Visualization=OFF \
    -D BUILD_MODULE_ApplicationFramework=OFF \
    -D BUILD_MODULE_DataExchange=OFF \
    -D BUILD_MODULE_DETools=OFF \
    -D BUILD_MODULE_Draw=OFF \
    -D "BUILD_ADDITIONAL_TOOLKITS=TKDESTEP;TKDEIGES;TKMesh" \
    -D BUILD_RELEASE_DISABLE_EXCEPTIONS=OFF \
    -D BUILD_DOC_Overview=OFF \
    -D USE_FREETYPE=OFF \
    -D USE_FREEIMAGE=OFF \
    -D USE_RAPIDJSON=OFF \
    -D USE_DRACO=OFF \
    -D USE_TBB=OFF \
    -D USE_TK=OFF \
    -D INSTALL_DIR="$WORK/install-$sdk" \
    -D INSTALL_DIR_INCLUDE=include \
    -D INSTALL_DIR_LIB=lib
  cmake --build "$WORK/$sdk" --parallel "$JOBS"
  cmake --install "$WORK/$sdk"
  mkdir -p "$OUT/$sdk"
  cp -R "$WORK/install-$sdk/lib" "$OUT/$sdk/"
  # The build folder takes a few GB; only the installed libraries are kept.
  rm -rf "$WORK/$sdk"
done

cp -R "$WORK/install-iphoneos/include" "$OUT/"
cp "$WORK/source/LICENSE_LGPL_21.txt" "$WORK/source/OCCT_LGPL_EXCEPTION.txt" "$OUT/"
ls -l "$OUT/iphoneos/lib" "$OUT/iphonesimulator/lib"
du -sh "$OUT"
