#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if ! command -v erl >/dev/null 2>&1; then
	echo "[ERROR] erl not found in PATH."
	exit 1
fi

if ! command -v rebar3 >/dev/null 2>&1; then
	echo "[ERROR] rebar3 not found in PATH."
	exit 1
fi

echo "[1/3] Compiling project modules..."
rebar3 compile

echo "[2/3] Compiling test profile modules..."
rebar3 as test compile

echo "[3/3] Starting Erlang shell with src and test code paths..."
echo
echo "Available examples after startup:"
echo "  field_diff_bench:run().                 # baseline + actual eCas diffDirtyMask"
echo "  field_diff_bench:run_ecas().            # actual eCas diffDirtyMask only"
echo "  field_diff_bench:run(#{iterations => 100000, change_count => 4})."
echo "  field_diff_bench:run(#{sizes => [32,64,128], iterations => 50000})."
echo "  eCas_bench:run()."
echo "  eCas_bench:run(#{iterations => 1000, flush_rows => 500})."
echo "  tcCas:tcall(false).                     # txn lock perf: 2~128 keys, 2~512 procs"
echo "  tcCas:tlock().                          # single-process lock sweep"
echo "  tcCas:tlock(256).                        # 256-process concurrency"
echo "  eCas:start()."
echo

ERL_PA_ARGS=()

for d in "$ROOT"/_build/default/lib/*/ebin; do
	[ -d "$d" ] && ERL_PA_ARGS+=("-pa" "$d")
done

for d in "$ROOT"/_build/test/lib/*/ebin; do
	[ -d "$d" ] && ERL_PA_ARGS+=("-pa" "$d")
done

if [ -d "$ROOT/_build/test/lib/eCas/test" ]; then
	ERL_PA_ARGS+=("-pa" "$ROOT/_build/test/lib/eCas/test")
fi

if [ -d "$ROOT/test" ]; then
	ERL_PA_ARGS+=("-pa" "$ROOT/test")
fi

exec erl "${ERL_PA_ARGS[@]}" "$@"
