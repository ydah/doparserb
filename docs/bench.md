# Benchmarks

Measured on 2026-11-09 with CRuby 4.0.9, arm64 macOS, lrama master `263a3a4b99b0b4856b9993b682b563369d3b51ea`, and dopairb `da3303ccb7e1d75ee5da25fc86449a01b8a584a1`. Final integration measurements retain the earlier milestone samples for comparison.

## Generation event collection

Run `bundle exec ruby benchmark/generation.rb` with the project dependencies installed. The benchmark uses separate processes for plain lrama and observed generation, preventing installed observation hooks from contaminating the baseline. Each process warms up three times, then measures 15 batches of 10 generations. Reported times are medians of per-generation batch times. Ruby startup and drawing are excluded; generation, output writing, event creation, queueing, and aggregation are included. Garbage collection runs before each measured batch and remains enabled inside it.

| Grammar | Plain lrama | With collection | Overhead | Target |
| --- | ---: | ---: | ---: | ---: |
| Upstream `sample/parse.y` | 4.9805 ms | 5.1101 ms | +2.60% | ≤ +5% |
| Generated grammar with 512 terminal alternatives | 123.0196 ms | 124.3196 ms | +1.06% | ≤ +5% |

Both final measured cases meet the collector target. [Final raw measurements](bench-generation-final.json) retain every batch time; [M2 measurements](bench-generation.json) remain available and showed +2.54% and −1.92%, respectively. Negative differences are measurement variation, not claimed speedups. The synthetic grammar is generated deterministically by the script; it supplements the small upstream sample. Baseline and observed diagnostics are compared without suppressing upstream warnings. These measurements do not establish live-meter rendering overhead. The final measurement uses in-memory output statistics and does not reopen output files, pipes, or devices.

## C-parser performance

`bundle exec ruby benchmark/runtime.rb` builds the pinned lrama `sample/json.y` with Apple clang 21.0.0 and `-O2 -std=c99` on arm64 macOS. Each mode has one excluded warmup and ten measured runs. The mode order rotates each round, and other project tests and builds were paused during measurement. [Raw measurements](bench-runtime.json) retain every sample, compiler flags, generated-source hashes, dependency revisions, descriptor checks, and playback summaries. `bundle exec ruby benchmark/runtime.rb --self-test` checks the corpus construction, timing-marker validation, and median calculation.

The deterministic input is a flat array of 1,966,080 numbers, totaling 10,485,762 bytes. It repeats `0,1,-7,12,123,1024,-65536,987654321,3.14159,-0.125,42.5,1000000`. Numeric values avoid the upstream sample's per-string allocation leak. The corpus SHA-256 is `2b7cccee56e8d183db6354831675b22fa84388cda41b6e206c17ebf741eb11ab`.

A temporary grammar copy measures `CLOCK_MONOTONIC` immediately around `yyparse()` and checks its return value. The upstream sample's unconditional success exit would otherwise hide parser failure. All fifty measured parses returned zero and produced exactly `JSON parsed successfully!` followed by a newline. The parser duration includes runtime hooks and the standalone badge, while the separately measured whole-process duration also includes launch, Ruby startup, and the finishing replay.

| Mode | Median parse time | Difference from plain | Median whole process | Target |
| --- | ---: | ---: | ---: | --- |
| Plain lrama | 260.479 ms | Baseline | 278.685 ms | Baseline |
| `-DDOPA_RT_DISABLE` | 234.092 ms | −10.13% | 248.708 ms | Equivalent within measurement error |
| Runtime off, no terminal or event descriptor | 235.043 ms | −9.76% | 250.018 ms | ≤ +2% |
| Standalone badge on stderr PTY | 256.695 ms | −1.45% | 269.343 ms | ≤ +3% |
| Actual CLI batch playback | 257.662 ms | −1.08% | 1,406.946 ms | ≤ +30% |

The numeric median ratios meet their thresholds in this run, but measurement variation is larger than the narrow runtime-off and badge budgets. A separate rebuild with the same source hashes, compiler, and flags produced identical optimized assembly and identical executable text sections for plain and compile-time-disabled parsers. Their 10.13% timing difference therefore reflects measurement variation. These samples do not establish a speedup or resolve overhead as small as 2–3%. The assembly and text-section comparison is recorded separately in the raw result; no timing samples were replaced.

Batch playback uses the actual `Doparserb::CLI` with file stdin, file stdout, and a 24×120 stderr PTY. A marker verifies `DOPAPARSER_FLUSH=batch`. Sound, flash, profile persistence, and the intro are off; highlight replay and real rendering remain enabled, with duration set to 0.1. The benchmark verifies that presentation appeared and records an existing show summary after parsing without adding work to each event.

Playback received only 130–131 of the expected 3,932,162 shift events per run, approximately 0.0033% coverage. It received 130–132 reductions and no acceptance event in any of the ten runs, despite all parses succeeding. Every playback summary was approximate and reported 1,765–3,529 discarded events; this reported loss does not count events skipped after transport is disabled. This is consistent with the specified cutoff after 64 consecutive nonblocking send failures. The standalone badge counted all 3,932,162 shifts in every run. These timings measure playback under substantial event loss; full-stream playback performance remains unestablished. No runtime behavior was changed for this benchmark.

## Generation display

`bundle exec ruby benchmark/generation_show.rb` compares alternating runs on real PTYs, with motion disabled or the live meter enabled. Both collect events, disable the intro and badge, and use the same generated grammar with 2,048 terminal alternatives. The measured duration comes from the generation event, so the finishing reel and Ruby startup are excluded. Every meter run verifies that CHARGING appeared.

Seven final repetitions per mode produced median generation times of **1.717560 s without drawing** and **1.719861 s with the meter**, an increase of **0.134%**, within the +5% target. [Final raw measurements](bench-meter-final.json) contain all samples. The [M3 measurement](bench-meter.json), retained separately, showed +1.69%.

The PTY cancellation test verifies that a pending key is still available after the show and that cancellation completes within **50 ms**. The quick-mode PTY test verifies that the interval occupied by effects is at most **0.8 s**. These checks exercise the current machine; they are not universal timing guarantees.

## Playback relay

`bundle exec ruby benchmark/play_relay.rb` timestamps 100 child-output lines while the child sends bursts of eight datagrams, each containing 120 parser events. Timing ends when the outer PTY reader receives the output. It includes relay, scheduling, and terminal-test-driver costs. All 100 lines must survive, and the script verifies that presentation ran. With `SIDECARS=128`, it additionally scans large unrelated metadata files before finding the matching sidecar and checks that symbolic labels become available.

| Case | Median | p95 | Maximum | Maximum target |
| --- | ---: | ---: | ---: | ---: |
| Event bursts | 1.475 ms | 3.433 ms | 5.073 ms | 5 ms |
| Event bursts and 128 sidecars | 1.452 ms | 2.542 ms | 4.135 ms | 5 ms |

The final event-burst run exceeds the maximum target by 0.073 ms; the final sidecar run meets it. No output was lost. All samples are in [bench-relay-final.json](bench-relay-final.json) and [bench-relay-sidecars-final.json](bench-relay-sidecars-final.json). The earlier M5 runs remain in [bench-relay.json](bench-relay.json) and [bench-relay-sidecars.json](bench-relay-sidecars.json), with maxima of 4.781 ms and 5.757 ms. The latter exceeded the bound by 0.757 ms. These tail-latency observations remain reported deviations; scheduling and PTY-reader costs are included, and the measurements do not establish a universal 5 ms guarantee.

Bounding event work to one millisecond and checking child output between datagrams reduced the initial event-burst maximum from 9.139 ms. Sidecar lookup now runs asynchronously; a focused 128-file lookup submission measured 0.111 ms versus 119.994 ms when synchronous. A terminal-control bootstrap adds about 19.6 ms to median launch-to-exit time in a 20-run Ruby-child probe, preserving raw input, configured interrupt characters, and ordinary signal handling.
