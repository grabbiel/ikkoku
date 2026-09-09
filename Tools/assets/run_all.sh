#!/bin/bash
# Rebuild every Ikkoku asset from the CC0 MakeHuman sources (deterministic, ~10 min).
#   Tools/assets/run_all.sh            # everything
#   Tools/assets/run_all.sh body       # only the bodies (+ textures + catalog)
#   STAGES="hair clothes" Tools/assets/run_all.sh
set -euo pipefail
cd "$(dirname "$0")"
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
PY=${PY:-/opt/homebrew/bin/python3}          # python3 with numpy + Pillow (the pyenv shim may resolve elsewhere)
mkdir -p out out/verify
bl() { "$BLENDER" -b --factory-startup --python "$1" -- "${@:2}"; }

STAGES=${STAGES:-${1:-"body textures hair clothes items catalog verify"}}
for stage in $STAGES; do
  echo "=================== stage: $stage"
  case $stage in
    body)
      bl build_body.py --sex f 2>&1 | tee out/build_body_f.log | grep -E "^\[ikkoku|Error|Traceback"
      bl build_body.py --sex m 2>&1 | tee out/build_body_m.log | grep -E "^\[ikkoku|Error|Traceback"
      ;;
    textures)
      "$PY" textures.py 2>&1 | tee out/textures.log | grep -E "^\[ikkoku|Error|Traceback"
      ;;
    hair)
      bl build_hair.py --sex f --only bob,long_straight,ponytail,twintails,mh_bob01,mh_bob02,mh_ponytail01,mh_long01,mh_afro01,mh_braid01,mh_short01,mh_short02,mh_short03,mh_short04 \
        2>&1 | tee out/build_hair.log | grep -E "^\[ikkoku|Error|Traceback"
      bl build_hair.py --sex m --only short_m,messy_m 2>&1 | tee -a out/build_hair.log | grep -E "^\[ikkoku|Error|Traceback"
      ;;
    clothes)
      bl build_clothes.py --sex f 2>&1 | tee out/build_clothes.log | grep -E "^\[ikkoku|Error|Traceback"
      bl build_clothes.py --sex m 2>&1 | tee -a out/build_clothes.log | grep -E "^\[ikkoku|Error|Traceback"
      ;;
    items)
      bl build_items.py 2>&1 | tee out/build_items.log | grep -E "^\[ikkoku|Error|Traceback"
      ;;
    catalog)
      "$PY" catalog.py
      ;;
    verify)
      bl verify.py body f 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      bl verify.py body m 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      bl verify.py hair 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      bl verify.py clothes 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      bl verify.py accessories 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      bl verify.py items 2>&1 | grep -E "^\[ikkoku|Error|Traceback"
      "$PY" verify.py sheet
      ;;
    *) echo "unknown stage $stage"; exit 1;;
  esac
done
echo "done. Verification renders: Tools/assets/out/verify/"
