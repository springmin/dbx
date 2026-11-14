#!/bin/sh
# DBX for OpenHarmony - self-locating launcher for the release package.
#
# Usage: sh start.sh [port]
DIR=$(cd "$(dirname "$0")" && pwd)
PORT="${1:-4224}"
export DBX_DATA_DIR="${DBX_DATA_DIR:-$DIR/data}"
export DBX_STATIC_DIR="${DBX_STATIC_DIR:-$DIR/static}"
export DBX_DISABLE_PASSWORD="${DBX_DISABLE_PASSWORD:-true}"
export RUST_LOG="${RUST_LOG:-info}"
exec env DBX_PORT="$PORT" "$DIR/dbx-web"
