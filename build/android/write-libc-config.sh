#!/bin/sh
set -eu

sysroot=$1
target_lib=$2
ndk_triple=$3
api_level=$4
output=$5

printf '%s\n' \
  "include_dir=$sysroot/usr/include" \
  "sys_include_dir=$sysroot/usr/include/$ndk_triple" \
  "cc_dir=$target_lib/$api_level" \
  "crt_dir=$target_lib/$api_level" \
  'msvc_lib_dir=' \
  'kernel32_lib_dir=' \
  'darwin_sdk_dir=' > "$output"
