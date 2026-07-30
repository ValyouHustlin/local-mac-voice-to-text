# Rejected exact-inference-cache candidate — 2026-07-30

## Decision

The exact inference-cache candidate is rejected for daily runtime. It preserved
the full-buffer transcript and produced deterministic reuse, but it did not
clear the predeclared 15% median latency improvement on both long fixtures.
The public/default strategy remains `fullBufferControl`.

This closes the current safe work-during-speech lane. A future attempt requires
a decoder-native incremental API or a new architecture with a stronger
predeclared oracle; the product roadmap advances to suggestion-only local
self-learning.

## Architecture

Pinned WhisperKit exposes replaceable `featureExtractor` and `audioEncoder`
components but no supported decoder/KV continuation for changed audio. The
probe therefore memoizes only exact Core ML inference:

- feature entries are keyed by the input tensor's complete data type, shape,
  strides, and storage bytes;
- encoder entries use the same identity rule on the exact mel tensor;
- caches are bounded to 12 entries, enabled only for one offline authority
  session, and cleared when the session ends;
- a miss calls the original model normally;
- normal full-buffer VAD chunking, decoding, vocabulary prompt, ordered result
  assembly, independent final-20-second audit, integrity selection, and
  prompt-free full retry are unchanged.

Pre-release cumulative decodes can populate entries for a VAD chunk that is
already byte-identical to the release-time chunk. Primary and prompt-free
integrity passes also reuse identical feature/encoder work. No timestamp,
partial transcript, word boundary, or textual splice authorizes reuse.

## Oracle-first automated evidence

The focused cache test was observed failing to compile before the cache types
existed. After implementation:

```sh
WORDHAND_SAFE=1 swift test \
  --filter 'ExactInferenceCacheTests|CumulativeTranscriptSnapshotTrackerTests'
```

Thirteen tests across two suites passed. The cache tests prove exact identical
input hits, one-value mutations miss, eviction is bounded, reset revokes every
entry and claim, and the disabled/default path is transparent.

## Retained corpus replay

Command:

```sh
WORDHAND_SAFE=1 ./scripts/test-transcription-authority-corpus.sh 2
```

The aggregate JSON reported `everyComparisonPassed: true`, then the promotion
script intentionally exited 1 because one long fixture missed the locked
latency threshold.

| Fixture | Baseline median | Candidate median | Change |
| --- | ---: | ---: | ---: |
| 12.572 s lexical | 1.427 s | 1.410 s | 1.2% faster |
| 49.260 s boundary | 6.315 s | 4.851 s | 23.2% faster |
| 53.714 s ambiguity | 4.734 s | 4.281 s | 9.6% faster |

Every measured candidate run reported
`authorityPath=full_buffer_exact_inference_cache`. Both long fixtures produced
exact feature and encoder hits on every run. The boundary runs had three
feature plus three encoder hits after release; primary decode fell to
1.94 seconds and the prompt-free full retry to 1.69 seconds while the mandatory
tail audit remained 1.22–1.26 seconds. The ambiguity primary fell to
2.86 seconds while its mandatory tail audit remained 1.43–1.44 seconds.

All beginnings, endings, numbers, negations, technical terms, dictionary
spellings, repeated anchors, WER, CER, and integrity outcomes matched the
paired authoritative baseline. Short median stayed within the locked 100 ms
regression ceiling.

## Why it is not promoted

The promotion gate required:

- every paired transcript and protected check to pass;
- every run of both long fixtures to use the exact-cache authority path and
  report a real cache hit;
- at least 15% lower median stop-to-final on each long fixture; and
- no short-fixture regression above 100 ms.

Only the ambiguity latency threshold failed. Lowering the threshold after
observing 9.6% would invalidate the oracle. Pre-release work also consumed
roughly 8–12 seconds of inference during each long recording, so the smaller
benefit does not yet justify daily battery, thermal, and memory cost.

## Runtime boundary

No microphone, playback, clipboard, event tap, insertion target, natural
dictation, installed build, or application UI was exercised. The experiment is
selected only by the offline authority command and cannot change daily
transcription.
