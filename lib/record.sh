#!/usr/bin/env bash
# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Shared by every check action. The actions take no inputs: they read the job environment the fitness workflow sets
# once in its first step (OSERA_TAG, OSERA_REPOSITORY, OSERA_EXPECTED_ORG, OSERA_APPROVED_PRODUCERS, OSERA_ACTOR,
# OSERA_RESULTS_DIR, OSERA_PACK, OSERA_LIBRARY, OSERA_OWNER, OSERA_OWNER_ID, OSERA_IS_FORK).
# Only OSERA_TAG and OSERA_REPOSITORY are required, the rest default here.
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

: "${OSERA_TAG:?OSERA_TAG is required}"
: "${OSERA_REPOSITORY:?OSERA_REPOSITORY is required}"
: "${OSERA_EXPECTED_ORG:=finos-osera}"
: "${OSERA_APPROVED_PRODUCERS:=.osera-fitness/approved-producers/approved_producers.yaml}"
: "${OSERA_ACTOR:=${GITHUB_ACTOR:-}}"
: "${OSERA_PACK:=OSERA-SP-0.1.0}"
: "${OSERA_LIBRARY:=}"
: "${OSERA_RESULTS_DIR:=${RUNNER_TEMP:-.}/osera-results}"
: "${OSERA_OWNER:=}"     # from the run context when the caller is the repository under test, empty otherwise
: "${OSERA_OWNER_ID:=}"
: "${OSERA_IS_FORK:=}"
export OSERA_EXPECTED_ORG OSERA_APPROVED_PRODUCERS OSERA_ACTOR OSERA_PACK OSERA_LIBRARY OSERA_RESULTS_DIR
export OSERA_OWNER OSERA_OWNER_ID OSERA_IS_FORK
mkdir -p "$OSERA_RESULTS_DIR"

# derived from the release tag, two forms (OSERA-SP-0.1.0):
#   generic  v2.14.2+osera-patch.001      -> 2.14.2,      2.14.x, v2.14.2+patch.baseline
#   Java     v5.3.39.1-osera-00001        -> 5.3.39,      5.3.x,  v5.3.39+patch.baseline   (REL-003-JAVA, numeric base)
#   Java     v5.6.15.Final-osera-00001    -> 5.6.15.Final, 5.6.x, v5.6.15.Final+patch.baseline (qualified base)
upstream_version_of() {
  local tag="$1"
  local version
  # 1. drop the v prefix
  version="${tag#v}"
  # 2. generic form: everything before the + is the upstream version
  if [[ "$version" == *+osera-patch.* ]]; then
    version="${version%%+*}"
    printf '%s\n' "$version"
    return 0
  fi
  # 3. Java form: drop the -osera-NNNNN suffix
  if [[ "$version" == *-osera-[0-9]* ]]; then
    version="${version%-osera-*}"
    # 4. numeric base: a fourth numeric component is the OSGi qualifier added by the patch, drop it
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      version="${version%.*}"
    fi
    printf '%s\n' "$version"
    return 0
  fi
  # 5. neither form: the tag as it is, the checks report the mismatch
  printf '%s\n' "$version"
}
VERSION="$(upstream_version_of "$OSERA_TAG")"
LINE="$(printf '%s' "$VERSION" | cut -d. -f1,2).x"
BASE="v${VERSION}+patch.baseline"
export VERSION LINE BASE

EXPECTED=""
STEP=""

check_is() {
  CHECK_STD="$1"
  CHECK_REQ="$2"
  CHECK_ID="$3"
  EVFILE="$OSERA_RESULTS_DIR/.$CHECK_REQ.evidence"
  : > "$EVFILE"
}

expect() {
  EXPECTED="$1"
}

step() {
  STEP="$1"
}

# the command line as it can be pasted into a shell: arguments with special characters in single quotes
quoted() {
  local a q="" s
  for a in "$@"; do
    case "$a" in
      *[!A-Za-z0-9_./:@=+^{}-]*|"")
        s="$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"
        q="$q '$s'"
        ;;
      *)
        q="$q $a"
        ;;
    esac
  done
  printf '%s' "${q# }"
}

ev() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  jq -cn --arg command "$(quoted "$@")" --argjson exit "$rc" \
         --arg output "$(printf '%s' "$out" | head -n 40 | head -c 4000)" \
         '{command: $command, exit: $exit, output: $output}' >> "$EVFILE"
  printf '%s\n' "$out"
  return "$rc"
}

given() {
  jq -cn --arg context "$1" --arg value "$2" '{context: $context, value: $value}' >> "$EVFILE"
}

record() {
  local status="$1" observed="$2"
  jq -n --arg standard "$CHECK_STD" --arg requirement "$CHECK_REQ" --arg check "$CHECK_ID" --arg status "$status" \
        --arg expected "$EXPECTED" --arg observed "$observed" --slurpfile evidence "$EVFILE" \
        '{standard: $standard, standard_version: "0.1.0", requirement: $requirement,
          check: (if $check == "" then null else $check end), status: $status,
          expected: $expected, observed: $observed, evidence: $evidence}' > "$OSERA_RESULTS_DIR/$CHECK_REQ.json"
  echo "$CHECK_REQ $status: $observed"
  [ "$status" != "fail" ]
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
