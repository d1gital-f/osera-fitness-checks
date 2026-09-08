#!/usr/bin/env bash
# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Shared by every check action. The actions take no inputs: they read the job environment the fitness workflow sets
# once in its first step (OSERA_TAG, OSERA_REPOSITORY, OSERA_EXPECTED_ORG, OSERA_APPROVED_PRODUCERS, OSERA_ACTOR,
# OSERA_RESULTS_DIR, OSERA_PACK, OSERA_LIBRARY). Only OSERA_TAG and OSERA_REPOSITORY are required, the rest default here.
#
# A check reads like this:
#   check_is <standard> <requirement> <check id or empty>   names the check; one record per requirement
#   expect "<the rule in words, with the actual values in it>" what a pass needs
#   step "<what is being done>"                             named so that a crash reads as "could not run: <step> failed"
#   ev <command...>                                         runs the command, keeps the command line (quoted so it can be
#                                                           pasted into a shell), exit code and output as evidence, prints
#                                                           the output, returns the command's exit code
#   given <github context name> <value>                     keeps a value GitHub set in the run context as evidence
#   record <status> "<what was observed>"                   writes the record and returns failure when the status is fail
# Status values are the fitness page's: pass, warn, fail, not-tested, not-applicable, manual-evidence-required.
: "${OSERA_TAG:?OSERA_TAG is required}"; : "${OSERA_REPOSITORY:?OSERA_REPOSITORY is required}"
: "${OSERA_EXPECTED_ORG:=finos-osera}"; : "${OSERA_APPROVED_PRODUCERS:=.osera-fitness/approved-producers/approved_producers.yaml}"
: "${OSERA_ACTOR:=${GITHUB_ACTOR:-}}"; : "${OSERA_PACK:=OSERA-SP-0.1.0}"; : "${OSERA_LIBRARY:=}"
: "${OSERA_OWNER:=}"; : "${OSERA_OWNER_ID:=}"; : "${OSERA_IS_FORK:=}"   # from the run context when the caller is the repository under test, empty otherwise
: "${OSERA_RESULTS_DIR:=${RUNNER_TEMP:-.}/osera-results}"
export OSERA_EXPECTED_ORG OSERA_APPROVED_PRODUCERS OSERA_ACTOR OSERA_PACK OSERA_LIBRARY OSERA_RESULTS_DIR OSERA_OWNER OSERA_OWNER_ID OSERA_IS_FORK
mkdir -p "$OSERA_RESULTS_DIR"
VERSION="${OSERA_TAG#v}"; VERSION="${VERSION%%+*}"   # v2.14.2+osera-patch.001 -> 2.14.2
LINE="${VERSION%.*}.x"                               # 2.14.x, the maintained line form FORK-002 also allows
BASE="v${VERSION}+patch.baseline"                    # the baseline tag FORK-003 requires
export VERSION LINE BASE
EXPECTED=""; STEP=""
check_is() { CHECK_STD="$1"; CHECK_REQ="$2"; CHECK_ID="$3"; EVFILE="$OSERA_RESULTS_DIR/.$CHECK_REQ.evidence"; : > "$EVFILE"; }
expect() { EXPECTED="$1"; }
step() { STEP="$1"; }
quoted() { local a q="" s; for a in "$@"; do case "$a" in *[!A-Za-z0-9_./:@=+^{}-]*|"") s="$(printf '%s' "$a" | sed "s/'/'\\''/g")"; q="$q '$s'" ;; *) q="$q $a" ;; esac; done; printf '%s' "${q# }"; }
ev() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  jq -cn --arg command "$(quoted "$@")" --argjson exit "$rc" --arg output "$(printf '%s' "$out" | head -n 40 | head -c 4000)" \
     '{command: $command, exit: $exit, output: $output}' >> "$EVFILE"
  printf '%s\n' "$out"
  return "$rc"
}
given() { jq -cn --arg context "$1" --arg value "$2" '{context: $context, value: $value}' >> "$EVFILE"; }
record() {
  jq -n --arg standard "$CHECK_STD" --arg requirement "$CHECK_REQ" --arg check "$CHECK_ID" --arg status "$1" \
        --arg expected "$EXPECTED" --arg observed "$2" --slurpfile evidence "$EVFILE" \
        '{standard: $standard, standard_version: "0.1.0", requirement: $requirement,
          check: (if $check == "" then null else $check end), status: $status,
          expected: $expected, observed: $observed, evidence: $evidence}' > "$OSERA_RESULTS_DIR/$CHECK_REQ.json"
  echo "$CHECK_REQ $1: $2"
  [ "$1" != "fail" ]
}
# If the check dies before recording (a git failure, a missing file), the requirement is recorded as not-tested
# with the step that failed and the evidence gathered so far, so it never silently disappears from the result.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "${CHECK_REQ:-}" ] && [ ! -f "$OSERA_RESULTS_DIR/$CHECK_REQ.json" ]; then
    record not-tested "could not run: ${STEP:-the check} failed" || true
  fi
}
trap on_exit EXIT
