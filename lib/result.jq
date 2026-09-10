# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Builds result.json from the per requirement records (jq -s: the input is the array of all records).
# Arguments: $pack $repo $release $commit $producer $library $registry_ref.

# The one rollup, used per standard and at the top: any fail is a fail, then warn, then not-tested, then pass;
# not-applicable only when everything underneath is.
def rollup:
  map(.status) as $s
  | if   any($s[]; . == "fail") then "fail"
    elif any($s[]; . == "warn" or . == "manual-evidence-required") then "warn"
    elif any($s[]; . == "not-tested") then "not-tested"
    elif any($s[]; . == "pass") then "pass"
    else "not-applicable" end;

# the requirements of the pack, and the ControlPlane proposals (CP-*), kept apart
(map(select(.requirement | startswith("CP-") | not))) as $checks
| (map(select(.requirement | startswith("CP-")))) as $proposals

# one status per standard, the fitness page's view
| ($checks | group_by(.standard) | map({standard: .[0].standard, standard_version: "0.1.0", status: rollup})) as $standards

| {
    standard_pack: $pack,
    pack_checksum: null,
    registry_ref: (if $registry_ref == "" then null else $registry_ref end),
    repository: $repo,
    release: $release,
    commit: $commit,
    artifact_digest: null,
    library: (if $library == "" then null else $library end),
    producer: (if $producer == "" then null else $producer end),
    result: ($standards | rollup),
    signature: "see the GitHub artifact attestation on this file",
    standards: $standards,
    checks: $checks,
    proposals: $proposals
  }
