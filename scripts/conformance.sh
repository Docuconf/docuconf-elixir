#!/usr/bin/env bash
# Runs the shared conformance suite (docuconf-go conformance/cases.json), the
# shared export check (conformance/export/golden.cue, compared by
# `docuconf conformance export`), and the tests that `cue vet` exported
# contracts against the meta-schema (docuconf-go spec/cue). Not the full
# suite. Used by this repo's CI and by docuconf-go's downstream gate.
#
#   DOCUCONF_GO_DIR=/path/to/docuconf-go scripts/conformance.sh
#
# Needs Elixir/OTP and cue on PATH, and Go to build the docuconf CLI from
# DOCUCONF_GO_DIR unless DOCUCONF_CLI names one already built from it. Fails
# if any conformance case is skipped.
set -euo pipefail

: "${DOCUCONF_GO_DIR:?set DOCUCONF_GO_DIR to a docuconf-go checkout}"
DOCUCONF_GO_DIR=$(cd "$DOCUCONF_GO_DIR" && pwd)
export DOCUCONF_GO_DIR
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$DOCUCONF_GO_DIR/conformance/cases.json}"
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$DOCUCONF_GO_DIR/spec/cue}"
export DOCUCONF_REQUIRE_CONFORMANCE=1
export DOCUCONF_REQUIRE_VET=1
export MIX_ENV=test

if [ -z "${DOCUCONF_CLI:-}" ]; then
  cli_dir=$(mktemp -d)
  trap 'rm -rf "$cli_dir"' EXIT
  (cd "$DOCUCONF_GO_DIR/cmd/docuconf" && go build -o "$cli_dir/docuconf" .)
  DOCUCONF_CLI="$cli_dir/docuconf"
fi
export DOCUCONF_CLI

cd "$(dirname "$0")/.."
# The test environment has no Hex dependencies (ex_doc is dev only).
mix deps.get --only test
out=$(mktemp)
status=0
mix test test/conformance_test.exs test/conformance_export_test.exs test/export_test.exs \
  test/docs_test.exs 2>&1 | tee "$out" || status=$?
summary=$(grep -oE 'conformance: [0-9]+ cases, [0-9]+ skipped' "$out" || true)
rm -f "$out"
[ "$status" -eq 0 ] || exit "$status"
# The runner prints "conformance: N cases, M skipped"; anything but 0 fails.
case "$summary" in
  *", 0 skipped"*) echo "$summary" ;;
  *) echo "FAIL: expected every conformance case to run, got: ${summary:-no summary}" >&2; exit 1 ;;
esac
