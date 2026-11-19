#!/bin/sh
set -eu

# Cloudflare writes .cloudflare/output under its working directory.
site_dir=$(pwd -P)
build_dir="$site_dir/../Temp/freedocx-cloudflare/build"
mkdir -p "$build_dir"
cp cloudflare.config.ts package.json "$build_dir/"
cd "$build_dir"

exec "$site_dir/node_modules/.bin/cf" deploy "$site_dir/public" "$@"
