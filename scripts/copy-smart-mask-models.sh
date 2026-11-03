#!/bin/sh
set -eu

# Only this build phase's named resources are replaced. Keep unrelated bundle files.
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
destination="$resources/SmartMaskModels"
/bin/mkdir -p "$destination"
/bin/cp "${SRCROOT}/Packages/SmartMaskRuntime/LICENSE" "$resources/SmartMaskRuntime-LICENSE.txt"
models="${SRCROOT}/build/smart-mask-validation/models"
for name in SAM2_1TinyImageEncoderFLOAT16.mlmodelc SAM2_1TinyPromptEncoderFLOAT16.mlmodelc SAM2_1TinyMaskDecoderFLOAT16.mlmodelc FaceParsing.mlmodelc selfie_multiclass_256x256.tflite; do
    /bin/rm -rf "$destination/$name"
done
/bin/rm -f "$destination/NOTICE.txt" "$destination/Apache-2.0.txt"
# Optional local research weights are never implicitly downloaded or shipped in Release.
[ "${CONFIGURATION}" = "Debug" ] || exit 0
objects=1
for name in SAM2_1TinyImageEncoderFLOAT16.mlmodelc SAM2_1TinyPromptEncoderFLOAT16.mlmodelc SAM2_1TinyMaskDecoderFLOAT16.mlmodelc; do
    [ -d "$models/$name" ] || objects=0
done
copied=0
if [ "$objects" = 1 ]; then
    for name in SAM2_1TinyImageEncoderFLOAT16.mlmodelc SAM2_1TinyPromptEncoderFLOAT16.mlmodelc SAM2_1TinyMaskDecoderFLOAT16.mlmodelc; do
        /usr/bin/ditto "$models/$name" "$destination/$name"
    done
    copied=1
fi
for name in FaceParsing.mlmodelc selfie_multiclass_256x256.tflite; do
    if [ "$name" = FaceParsing.mlmodelc ]; then
        [ -d "$models/$name" ] || continue
    else
        [ -f "$models/$name" ] || continue
    fi
    /usr/bin/ditto "$models/$name" "$destination/$name"
    copied=1
done
if [ "$copied" = 1 ]; then
    /bin/cp "${SRCROOT}/docs/references/smart-mask-research-NOTICE.txt" "$destination/NOTICE.txt"
    /bin/cp "${SRCROOT}/Packages/SmartMaskRuntime/LICENSE" "$destination/Apache-2.0.txt"
fi
