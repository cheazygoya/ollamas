#!/usr/bin/env bash
#
# scripts/build-local.sh
#
# Quick, reproducible local development build for BOTH the Go API layer
# (the ollama binary / server / gRPC+REST adapters) AND the native
# llama-server runner payload (with Metal on Apple Silicon).
#
# This is the recommended workflow for fast iteration on this branch
# (especially gRPC work, adapters, converters, clients, scheduling, etc.).
#
# Usage:
#   ./scripts/build-local.sh                 # full configure + ollama-local (Go + runner)
#   ./scripts/build-local.sh --go-only       # fast Go-only rebuild (once native payload exists)
#   ./scripts/build-local.sh configure       # just cmake -B build
#   ./scripts/build-local.sh build           # build the default target
#   ./scripts/build-local.sh clean           # remove build/
#   ./scripts/build-local.sh --help
#
# After a successful run the script will:
#   - Produce ./ollama (gitignored) and build/lib/ollama/llama-server (payload)
#   - Copy the binary + payload to ~/bin so `ollama` works from any terminal
#     (no leading ./ required, and ~/bin should be in your PATH)
#   - Safely stop any previous dev server instance started by this script
#   - Start the fresh build serving BOTH REST (port 11434) and gRPC (port 11435)
#
# The installed binary discovers the payload from ~/bin/lib/ollama/ (supported
# by llm/llama_binary.go for dev layouts).
#
# These artifacts are gitignored where appropriate.
#
# See also: docs/development.md and docs/grpc-phased-reliable-approach.md
#
# After a successful build you can immediately use the globally installed `ollama`
# (no ./ prefix). The dev server will already be running with both REST and gRPC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<'EOF'
scripts/build-local.sh - local dev build (Go API + llama-server payload)

After a successful build the script will automatically:
  - Install ./ollama + the llama-server payload into ~/bin
  - Make `ollama` available globally (add ~/bin to your PATH if not already)
  - Stop any previous dev server started by this script
  - Start the new build serving REST (127.0.0.1:11434) + gRPC (127.0.0.1:11435)

Modes / flags:
  (default)          Full configure (if needed) + build ollama-local target
                     (then auto-install + restart dev server with gRPC)
  configure          Only run cmake -B build . (idempotent)
  build              Build the default target (ollama-local or ollama-go)
                     (then auto-install + restart dev server with gRPC)
  clean              Remove the build/ directory
  --go-only          Build only the Go layer (ollama-go target). Much faster
                     once the native payload has been built at least once.
                     (then auto-install + restart dev server with gRPC)
  --target <t>       Build a specific cmake target (advanced)
  --preset <name>    Use a specific configure preset from CMakePresets.json
  -j, --parallel N   Override parallelism (default: auto-detect)
  -h, --help         Show this help

Environment variables honored:
  OLLAMA_MLX_BACKENDS   (e.g. "metal_v3;metal_v4" or empty to disable MLX)
  CMAKE_BUILD_TYPE      (default Release via presets / local.cmake)
  Any other vars passed through to cmake.

Examples:
  ./scripts/build-local.sh
  ./scripts/build-local.sh --go-only
  ./scripts/build-local.sh clean
  OLLAMA_MLX_BACKENDS= ./scripts/build-local.sh   # lighter, no MLX

After running, simply use the global command:
  ollama serve          # (already running with REST + gRPC after build)
  ollama --version
  grpcurl --plaintext localhost:11435 ollama.api.v1.ChatService/ChatStream ...
EOF
}

MODE="all"
GO_ONLY=false
TARGET=""
PRESET=""
PARALLEL=""
EXTRA_CMAKE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --go-only) GO_ONLY=true; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --preset) PRESET="$2"; shift 2 ;;
    -j|--parallel) PARALLEL="$2"; shift 2 ;;
    configure|build|clean|all)
      MODE="$1"; shift ;;
    *)
      # Pass anything else through to the initial cmake configure
      EXTRA_CMAKE_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$PARALLEL" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    PARALLEL=$(nproc)
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    PARALLEL=$(sysctl -n hw.ncpu)
  else
    PARALLEL=4
  fi
fi

# Basic prereq checks (non-fatal for configure step; cmake will give better errors)
check_prereqs() {
  if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found in PATH. Install with: brew install cmake" >&2
    exit 1
  fi
  if command -v ninja >/dev/null 2>&1; then
    echo ">>> ninja detected (recommended, will be used if generator prefers it)"
  fi
}

detect_darwin_metal() {
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    echo ">>> macOS arm64 detected — default build enables Metal (via OLLAMA_MLX_BACKENDS)."
    echo "    If this is the first build you may need the Metal toolchain:"
    echo "      xcodebuild -downloadComponent MetalToolchain"
    echo "    (cmake will fail with a clear message if it is missing.)"
  fi
}

do_configure() {
  check_prereqs
  detect_darwin_metal

  local configure_cmd=(cmake -B build)
  if [[ -n "$PRESET" ]]; then
    configure_cmd+=(--preset "$PRESET")
  fi
  # Safe expansion under set -u for possibly empty array (common bash gotcha)
  configure_cmd+=(${EXTRA_CMAKE_ARGS[@]+"${EXTRA_CMAKE_ARGS[@]}"})

  echo ">>> Configuring: ${configure_cmd[*]}"
  "${configure_cmd[@]}"
}

do_build() {
  local build_target="ollama-local"
  if [[ -n "$TARGET" ]]; then
    build_target="$TARGET"
  elif [[ "$GO_ONLY" == true ]]; then
    build_target="ollama-go"
  fi

  echo ">>> Building target: ${build_target} (parallel=${PARALLEL})"
  cmake --build build --target "${build_target}" --parallel "${PARALLEL}"
}

do_clean() {
  echo ">>> Cleaning build/ directory (root ./ollama and integration/ollama are gitignored)"
  rm -rf build
  # We intentionally do NOT rm -f ./ollama here — the user may have other copies
  # or want to keep a working one while cleaning the cmake tree.
}

# do_install_and_serve: After a successful build, install the ollama binary + payload
# to ~/bin so it is available as a normal `ollama` command from any shell (no ./ needed).
# Then safely replace any previous dev server instance and start the new one
# listening on standard dev ports with both REST (11434) and gRPC (11435) enabled.
do_install_and_serve() {
  echo
  echo ">>> Installing ollama to ~/bin for global access (no ./ prefix required)..."
  mkdir -p "$HOME/bin"
  mkdir -p "$HOME/bin/lib/ollama"

  cp -f "./ollama" "$HOME/bin/ollama"
  cp -f "build/lib/ollama/llama-server" "$HOME/bin/lib/ollama/llama-server" 2>/dev/null || true

  chmod +x "$HOME/bin/ollama" "$HOME/bin/lib/ollama/llama-server" 2>/dev/null || true

  echo "    Binary : $HOME/bin/ollama"
  echo "    Payload: $HOME/bin/lib/ollama/llama-server"
  echo
  echo ">>> Make sure ~/bin is in your PATH (add to ~/.zshrc or ~/.bash_profile if needed):"
  echo "    export PATH=\"\$HOME/bin:\$PATH\""
  echo

  echo ">>> Stopping any previous dev ollama instance (replacing with new build)..."
  local pid_file="$HOME/.ollama-dev.pid"
  if [ -f "$pid_file" ]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "    Stopping previous dev server (PID $old_pid)..."
      kill -TERM "$old_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  # Belt-and-suspenders: also try to stop any other ollama serve that might be using the user bin
  # (safe because we use exact path match where possible)
  pkill -f "$HOME/bin/ollama serve" 2>/dev/null || true
  sleep 0.5

  echo ">>> Starting new ollama dev server (REST on 11434 + gRPC on 11435)..."
  local log_file="$HOME/.ollama-dev.log"
  OLLAMA_HOST=127.0.0.1:11434 \
  OLLAMA_GRPC_HOST=127.0.0.1:11435 \
    nohup "$HOME/bin/ollama" serve > "$log_file" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$pid_file"

  echo "    PID    : $new_pid"
  echo "    Log    : $log_file"
  echo "    To stop: kill \$(cat $pid_file)"
  echo "    To tail: tail -f $log_file"
  echo
  echo ">>> Server is now running with both REST and gRPC enabled."
  echo "    REST : http://127.0.0.1:11434"
  echo "    gRPC : http://127.0.0.1:11435  (use OLLAMA_GRPC_HOST in clients/tests)"
  echo
  echo "    Quick checks:"
  echo "      curl -s http://127.0.0.1:11434/api/version | cat"
  echo "      grpcurl --plaintext localhost:11435 ollama.api.v1.ChatService/ChatStream   # (example)"
  echo
  echo "Tip: Subsequent ./scripts/build-local.sh --go-only will rebuild and automatically"
  echo "     replace the running dev server with the fresh binary + payload."
}

case "$MODE" in
  clean)
    do_clean
    exit 0
    ;;
  configure)
    do_configure
    exit 0
    ;;
  build)
    do_build
    ;;
  all|*)
    if [[ ! -d build || ! -f build/CMakeCache.txt ]]; then
      do_configure
    else
      echo ">>> build/ already configured — skipping full configure (use 'clean' to force)"
    fi
    do_build
    ;;
esac

echo
echo ">>> Build complete."
echo "    Go binary     : $(ls -l ./ollama 2>/dev/null || echo 'not present')"
echo "    llama-server  : $(ls -l build/lib/ollama/llama-server 2>/dev/null || echo 'not present under build/lib/ollama/')"

# Automatically install to user bin and (re)start the dev server with both REST + gRPC.
# This fulfills the request to have a globally available `ollama` and a running
# instance serving the updated code on the standard dev ports after every build.
do_install_and_serve
