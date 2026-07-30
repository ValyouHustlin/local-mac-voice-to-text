#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir="$repo_dir/Tests/Fixtures"
corpus_manifest="$fixture_dir/english-authority-corpus-v1.json"
report_dir=$(mktemp -d "${TMPDIR:-/tmp}/wordhand-authority-corpus.XXXXXX")
case_list="$report_dir/cases.tsv"
aggregate_report="$report_dir/corpus-report.json"
iterations=${1:-2}
default_authority_binary="$repo_dir/.build/debug/wordhand"

cleanup() {
    rm -rf -- "$report_dir"
}
trap cleanup EXIT HUP INT TERM

case "$iterations" in
    2|4|6|8|10) ;;
    *)
        echo "iterations must be one of 2, 4, 6, 8, or 10" >&2
        exit 64
        ;;
esac

if [ "${WORDHAND_AUTHORITY_BINARY+x}" != x ]; then
    (
        cd "$repo_dir"
        WORDHAND_SAFE=1 swift build --product wordhand >/dev/null
    )
    authority_binary="$default_authority_binary"
else
    authority_binary=$WORDHAND_AUTHORITY_BINARY
    if [ ! -x "$authority_binary" ]; then
        echo "WORDHAND_AUTHORITY_BINARY is not executable: $authority_binary" >&2
        exit 66
    fi
fi

jq -r '.fixtures[] | [.audio, .definition] | @tsv' \
    "$corpus_manifest" >"$case_list"
corpus_model=$(jq -r '.modelID' "$corpus_manifest")

corpus_passed=true
case_number=0
while IFS="$(printf '\t')" read -r audio_name definition_name; do
    case_number=$((case_number + 1))
    report_path="$report_dir/report-$case_number.json"
    if ! WORDHAND_SAFE=1 "$authority_binary" models authority-compare \
        "$fixture_dir/$audio_name" \
        --fixture "$fixture_dir/$definition_name" \
        --model "$corpus_model" \
        --iterations "$iterations" \
        --json >"$report_path"
    then
        corpus_passed=false
    fi
done <"$case_list"

jq -s \
    --arg corpus_id "$(jq -r '.id' "$corpus_manifest")" \
    '{
        corpusID: $corpus_id,
        fixtureCount: length,
        everyComparisonPassed: all(.[]; .everyComparisonPassed),
        fixtures: map({
            fixtureID,
            modelID,
            baselineImplementationID,
            candidateImplementationID,
            decoderConfigurationID,
            audioSHA256,
            fixtureSHA256,
            sampleCount,
            audioDurationSeconds,
            iterations,
            baselineMedianStopToFinalSeconds,
            baselineP95StopToFinalSeconds,
            candidateMedianStopToFinalSeconds,
            candidateP95StopToFinalSeconds,
            everyComparisonPassed,
            rejectionReasons: [.runs[].comparison.rejectionReasons],
            baselineTranscripts: [.runs[].baseline.transcript] | unique,
            candidateTranscripts: [.runs[].candidate.transcript] | unique,
            protectedResults: .runs[0].comparison.candidateProtected,
            provenance: [.runs[] | {
                iteration,
                baseline: .baseline.provenance,
                candidate: .candidate.provenance
            }]
        })
    }' "$report_dir"/report-*.json >"$aggregate_report"

expected_fixture_count=$(jq '.fixtures | length' "$corpus_manifest")
expected_fixture_ids=""
while IFS="$(printf '\t')" read -r _ definition_name; do
    fixture_id=$(jq -r '.id' "$fixture_dir/$definition_name")
    expected_fixture_ids="${expected_fixture_ids}${fixture_id}
"
done <"$case_list"
expected_fixture_ids=$(printf '%s' "$expected_fixture_ids" | sort)
actual_fixture_ids=$(jq -r '.fixtures[].fixtureID' "$aggregate_report" | sort)
baseline_implementation=$(jq -r '.baselineImplementationID' "$corpus_manifest")
candidate_implementation=$(jq -r '.candidateImplementationID' "$corpus_manifest")
require_long_pre_release=$(jq -r '.requireLongPreReleaseDecodes' "$corpus_manifest")
require_composed_long=$(jq -r '.requireComposedLongCandidate' "$corpus_manifest")
require_long_latency=$(jq -r '.requireLongMedianLatencyImprovement' "$corpus_manifest")

if ! jq -e \
    --argjson expected_count "$expected_fixture_count" \
    --arg baseline "$baseline_implementation" \
    --arg candidate "$candidate_implementation" \
    --arg model "$corpus_model" \
    --argjson require_long_pre_release "$require_long_pre_release" \
    --argjson require_composed_long "$require_composed_long" \
    --argjson require_long_latency "$require_long_latency" \
    '
        .fixtureCount == $expected_count
        and .everyComparisonPassed
        and all(.fixtures[];
            .baselineImplementationID == $baseline
            and .candidateImplementationID == $candidate
            and .modelID == $model
            and (
                ($require_long_pre_release | not)
                or .audioDurationSeconds < 30
                or all(.provenance[];
                    .candidate.preReleaseDecodeCount > 0
                )
            )
        )
        and (
            ($require_composed_long | not)
            or any(.fixtures[];
                .audioDurationSeconds >= 30
                and all(.provenance[];
                    .candidate.authorityPath == "composed"
                    and .candidate.reusedSampleCount > 0
                )
                and (
                    ($require_long_latency | not)
                    or .candidateMedianStopToFinalSeconds
                        < .baselineMedianStopToFinalSeconds
                )
            )
        )
        and (
            ($require_long_latency | not)
            or any(.fixtures[];
                .audioDurationSeconds >= 30
                and .candidateMedianStopToFinalSeconds
                    < .baselineMedianStopToFinalSeconds
            )
        )
    ' "$aggregate_report" >/dev/null
then
    corpus_passed=false
fi

if [ "$actual_fixture_ids" != "$expected_fixture_ids" ]; then
    echo "aggregate fixture membership does not match corpus manifest" >&2
    corpus_passed=false
fi

cat "$aggregate_report"

if [ "$corpus_passed" != true ]; then
    exit 1
fi
