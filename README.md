# csv-benchmarks

A standalone benchmark suite for comparing CSV parsing approaches in Ruby.
Designed to be parser-agnostic, extensible, and **equivalence-first**: RSpec
tests verify that each adapter produces output semantically identical to
SmarterCSV's default output before any timing numbers are trusted.

## Goals

1. **Pluggable adapters** — each CSV mechanism lives in one file; adding a new
   parser means adding one file, nothing else changes.
2. **Equivalence-first** — specs prove identical output before benchmarks run.
3. **Multi-version SmarterCSV** — side-by-side comparison across gem versions
   to track regressions and improvements.
4. **Reproducible results** — benchmark output written to timestamped Markdown
   + JSON so results can be compared across runs and machines.
5. **Self-contained CSV files** — all benchmark CSV files are tracked in
   `csv_files.zip`; unzip once with `rake install` and you're ready to go.

---

## Quick Start

```bash
git clone https://github.com/your-org/csv-benchmarks
cd csv-benchmarks
bundle install

# Unzip the benchmark CSV files
rake install

# Run equivalence specs (must pass before benchmarking)
bundle exec rspec

# One run of the full benchmark suite (all configured versions in random order)
rake bench

# Multiple runs + apples-to-apples comparison + report (preferred for release decisions)
bin/run_bench 3 p10 1.16.4 1.17.0.pre9

# Just compute a comparison from existing runs (any stats method + subset of versions)
rake compare_versions p10 1.14.4 1.16.4 1.17.0.pre9
rake compare_versions median 1.16.4 1.17.0.pre9    # try a different stats method

# Format any result/comparison JSON as Markdown
rake report                                          # latest run
rake report results/<file>.comparison.json          # specific file
rake report results/<file>.json 1.16.4 1.17.0.pre9  # filter to specific versions

# Generate SVG charts
rake chart_versions
rake chart_adapters
```

---

## CSV Benchmark Files

All benchmark CSV files are stored in `csv_files.zip` and are **not** checked
in as raw `.csv` files. To install them:

```bash
rake install       # unzips csv_files.zip → csv_files/
rake unzip_csv     # same thing, explicit name
```

The zip contains two subdirectories:

- `csv_files/actual/` — real-world files (anonymized, no PII)
- `csv_files/synthetic/` — generated stress-test files targeting specific
  parser features (quoting, embedded newlines, wide columns, unicode, etc.)

### Contributing CSV files

If you want to add CSV files to the test suite:

- **Do not commit `.csv` files directly** — they are gitignored.
- Remove all PII (Personally Identifiable Information) and HSI (Health/Sensitive
  Information) before adding any file.
- If the file is under an open license, append the license details to
  `csv_files/actual/LICENSE.md`.
- After adding your files, update the zip with:

```bash
rake zip_csv
```

Then commit the updated `csv_files.zip`.

---

## Adapters

### Fair-comparison group

All four return `Array<Hash>` with Symbol keys and numeric conversion — equivalent output.

| Adapter | Mechanism | File |
|---|---|---|
| `CSV.table` | `CSV.table(file).map(&:to_h)` | `adapters/ruby_csv/csv_table.rb` |
| `SmarterCSV` (C) | `SmarterCSV.process(file)` | `adapters/smarter_csv/default.rb` |
| `SmarterCSV` (Ruby) | `SmarterCSV.process(file, acceleration: false)` | `adapters/smarter_csv/ruby_path.rb` |
| `ZSV + wrapper` | ZSV raw + post-processing | `adapters/zsv/zsv_wrapped.rb` |

### Raw reference (not in equivalence tests)

| Adapter | Mechanism | Output |
|---|---|---|
| `CSV.read` | `CSV.read(file)` | `Array<Array<String>>` |
| `CSV.read (hashes)` | `CSV.read(file, headers: true).map(&:to_h)` | `Array<Hash>`, string keys |
| `ZSV raw` | `ZSV.read(file)` | `Array<Array<String>>` |

---

## Equivalence Definition

SmarterCSV with default options is the **reference output**. Equivalent means:

- Same number of rows
- Same keys (Symbols, downcased, whitespace-stripped)
- Same values after type coercion:
  - Integers: `"42"` → `42`
  - Floats: `"3.14"` → `3.14`
  - Whitespace stripped from string values
  - `nil`/empty values removed (key absent from hash)
  - All-empty rows removed
- Duplicate headers suffixed: `name`, `name2`, `name3`, …
- Blank headers named: `column_1`, `column_2`, …

**Known acceptable differences:**
- Scientific notation (`1.5e10`) and `+42`-style values: wrappers use simpler
  regex (`/\A-?\d+\z/`, `/\A-?\d+\.\d+\z/`) that doesn't match these. The
  benchmark files contain only plain integers and simple floats, so output is
  identical in practice.
- ZSV results have GC disabled during calls (zsv-ruby 1.3.1 GC bug on Ruby
  3.4.x) — gives ZSV a slight speed advantage; noted in all output.

---

## ZSV Setup (optional)

ZSV adapters are opt-in. If `require "zsv"` fails, `available?` returns
`false` and both ZSV adapters are silently skipped with a notice.

```bash
# Build zsv-ruby from source
git clone https://github.com/liquidaty/zsv-ruby ~/GitHub/zsv-ruby
cd ~/GitHub/zsv-ruby && bundle install && rake compile

# The benchmarks/specs automatically add ~/GitHub/zsv-ruby/lib to $LOAD_PATH
```

---

## Adding a New Adapter

1. Create `adapters/<parser_name>/<mechanism>.rb` inheriting `Adapters::Base`.
2. Implement `name`, `call(filepath)`, and optionally `available?` and
   `output_type` (default: `:equivalent`).
3. Add the adapter key to `BenchmarkConfig::ADAPTERS` in `config/benchmark.rb`
   and add a corresponding entry to `ADAPTER_REGISTRY` in `benchmarks/run_all.rb`.
4. If `:equivalent`, add a spec file in `spec/adapters/` using the
   `"equivalent to SmarterCSV"` shared example.

Minimal example:

```ruby
# adapters/my_parser/my_parser.rb
require_relative "../base"

module Adapters
  module MyParser
    class Default < Base
      def name = "MyParser.parse (smarter_csv-equivalent)"

      def available?
        require "my_gem"
        true
      rescue LoadError
        false
      end

      def call(filepath)
        # Must return Array<Hash> with Symbol keys, numeric conversion, etc.
        MyGem.parse(filepath)
      end
    end
  end
end
```

---

## Statistics Pipeline

Benchmarks are designed for apples-to-apples comparison across runs and
machines. The pipeline has three tiers of JSON output:

### Tier 1 — Raw per-run JSONs

Written by `rake bench`. Each cell stores the full sample array (one per
ITERATION) for each `(version, file, c|rb)`:

```
results/2026-05-10_1431_ruby3.4.7.raw.json
  - "c_samples": [40 floats], "rb_samples": [40 floats] per cell
  - "cached_versions": [...]      ← versions loaded from canonical cache
  - "bench_seed": 1234567890       ← reproduce with BENCH_SEED=1234567890
  - "version_run_order": [...]     ← actual order each version ran in
```

Raw JSONs carry no statistics — they're immutable measurement data.

### Tier 2 — Comparison JSONs (apples-to-apples)

Written by `rake compare_versions <stats_method> <version1> [<version2>...]`.
Aggregates the most recent fresh raw runs that contain ALL requested versions:

- Within-run: applies the chosen stats method (`p10` default) to each 40-sample array
- Across-runs: median for 3+ runs, mean for 2, identity for 1
- Records `same_session: true/false` so cross-session bias is visible

```
results/2026-05-10_1530_ruby3.4.7_p10.comparison.json
```

This is what charts and reports consume for cross-version analysis.

### Tier 3 — Canonical per-version cache files

Written by `rake merge_results <version1> [<version2>...]`. Stores per-run
sample arrays with full provenance:

```json
"uscities.csv": {
  "runs": [
    { "source": "2026-05-10_1431_…raw.json", "timestamp": "…", "warmup": 2,
      "c_samples": [40 floats], "rb_samples": [40 floats] },
    …
  ]
}
```

Canonicals serve as the speed cache for future `rake bench` runs (versions
listed in a canonical are skipped during measurement). Any stats method can
be re-derived from canonicals without re-merging.

### Stats methods (tunable)

`STATS_METHOD` env var, default `:p10`. Supported: `min`, `p5`, `p10`,
`median`, `best_window5`. The pipeline is robust to changing it — same
samples, different stat:

```bash
rake compare_versions p10 1.14.4 1.16.4 1.17.0.pre9                  # default
STATS_METHOD=median rake report results/<file>.comparison.json       # re-render
```

`p10` of 40 samples = 4th-lowest — robust to a few timer flukes while still
rewarding fast-path execution.

### Version ordering (reduces ordering bias)

`BENCH_ORDER` env var, default `random`. Within a single `rake bench` run,
versions are measured in random order so thermal/cache state doesn't
systematically advantage some versions:

```bash
rake bench                              # random shuffle (default)
BENCH_ORDER=fixed rake bench            # config order
BENCH_ORDER=reverse rake bench          # reversed config order
BENCH_SEED=42 rake bench                # reproducible random shuffle
```

Across multiple runs in `bin/run_bench 3 …`, each run uses a different seed —
median across runs cancels out ordering bias.

---

## Multi-Version SmarterCSV Comparison

Compare specific installed gem versions side-by-side:

```bash
# Install the versions you want to compare
gem install smarter_csv -v 1.14.4
gem install smarter_csv -v 1.15.2

# Configure SMARTER_CSV_VERSIONS in config/benchmark.rb, then:
bin/run_bench 3 p10 1.14.4 1.15.2 1.16.4 1.17.0.pre9
```

Each version runs in an isolated subprocess so multiple gem versions can be
activated without conflict.

### Canonical per-version timing files

Once you have good benchmark runs for a released version, condense them into
a canonical file (Tier 3 above):

```bash
rake merge_results 1.14.4 1.15.2
```

Canonicals preserve per-run sample arrays with provenance — downstream
readers can apply any stats method without re-merging. On subsequent
`rake bench` runs, if `results/smarter_csv_<version>.json` exists, that
version is loaded from cache instead of re-measured. Cached versions are
tagged in the output via `cached_versions: [...]` so merge tooling never
double-counts.

To force a re-run:

```bash
RECOMPUTE_VERSIONS=1.14.4 rake bench        # recompute one version
RECOMPUTE_VERSIONS=all    rake bench        # recompute all versions
```

For legacy JSONs that predate the `cached_versions` marker, run:

```bash
rake backfill_cached_versions
```

This scans `results/*.raw.json` chronologically and detects which versions
were loaded from cache (identical timings appearing across runs), then
writes back the marker without modifying file mtimes.

---

## SVG Charts

Two chart types are available, configured in `config/chart.rb`:

```bash
rake chart_versions results/smarter_csv_1.15.2.json   # version speedup chart
rake chart_adapters results/2026-03-05_1430_ruby3.4.7.json  # adapter comparison chart
```

Both produce an SVG file alongside the input JSON (e.g. `*_versions_chart.svg`).
SVG renders natively on GitHub and in browsers; convert to PNG with
`rsvg-convert` for publishing elsewhere.

### config/chart.rb

Chart configuration is separate from benchmark configuration:

```ruby
"versions" => {
  title:    "SmarterCSV version improvements (C accelerated)",
  type:     :versions,
  paths:    [:c],          # :c, :rb, or [:c, :rb] for both
  versions: %w[1.14.4 1.15.2],
},

"adapters" => {
  title:            "Parser comparison vs SmarterCSV",
  type:             :adapters,
  baseline_version: "1.15.2",
  baseline_path:    :c,
  adapters: [ ... ],
},
```

---

## Configuration

All benchmark parameters live in `config/benchmark.rb`:

| Constant               | Default          | Effect                                                                          |
|------------------------|------------------|---------------------------------------------------------------------------------|
| `WARMUP`               | `2`              | Discarded warm-up runs before measurement                                       |
| `ITERATIONS`           | `40`             | Measured runs; all samples stored, reported value computed via `STATS_METHOD`   |
| `ADAPTERS`             | `[]`             | Comment in/out keys to enable/disable adapters                                  |
| `FILE_OPTIONS`         | tab/multi-char   | Per-file options (e.g., `col_sep`)                                              |
| `SMARTER_CSV_VERSIONS` | list of versions | Versions compared in `rake bench`                                               |

### Environment variable reference

| Env var              | Used by                       | Default      | Effect                                                                            |
|----------------------|-------------------------------|--------------|-----------------------------------------------------------------------------------|
| `VERSIONS`           | `rake bench`, `rake versions` | from config  | Comma-separated version list override                                             |
| `ADAPTERS`           | `rake bench`                  | from config  | Comma-separated adapter list override                                             |
| `STATS_METHOD`       | report/compare/merge/charts   | `p10`        | Within-run statistic: `min`, `p5`, `p10`, `median`, `best_window5`                |
| `BENCH_ORDER`        | `rake bench`                  | `random`     | Version measurement order: `random`, `fixed`, `reverse`                           |
| `BENCH_SEED`         | `rake bench`                  | new each run | Integer seed for reproducible random shuffle                                      |
| `BENCH_SHUFFLE`      | `rake bench`                  | unset        | `0` = synonym for `BENCH_ORDER=fixed` (backward compat)                           |
| `RECOMPUTE_VERSIONS` | `rake bench`                  | unset        | `all` or comma-separated versions to force re-measurement (skip canonical cache)  |
| `NO_MD`              | `rake report`                 | unset        | `1` suppresses writing the `.md` file (stdout output unchanged)                   |
| `N`                  | `rake compare_versions`       | all matching | Cap on the number of most recent fresh runs used per version                      |
| `ANY_RUBY`           | `rake merge_results`          | unset        | `1` includes raw runs from any Ruby version, not just the newest                  |
| `DRY`                | `rake backfill_cached_versions` | unset      | `1` previews classifications without writing files                                |

To skip an adapter, comment out its line:

```ruby
ADAPTERS = %w[
  ruby_csv/csv_read
  # ruby_csv/csv_hashes   # skip this one
  ...
].freeze
```

---

## Benchmark Methodology

- **Warmup:** 2 discarded runs before measurement. C extensions benefit
  disproportionately from warmup (cold I-cache, branch predictors, Ruby object
  caches). Without warmup, C extension times are inflated 1.6×–7.2× versus
  warmed numbers — skipping warmup understates C extension performance.
- **Within-run statistic (`STATS_METHOD`):** default `p10` (4th-lowest of 40
  samples). Robust to a few timer flukes while still rewarding fast-path
  execution. Configurable: `min`, `p5`, `p10`, `median`, `best_window5`.
- **Across-runs aggregation:** when `rake compare_versions` (or `rake
  merge_results`) combines multiple runs, it uses median for 3+ runs, mean
  for 2 runs, identity for 1 — dropping the luckiest and unluckiest sessions.
- **Random version order:** within each `rake bench`, version measurement
  order is shuffled (`BENCH_ORDER=random`) so thermal/cache state doesn't
  systematically advantage particular versions. The seed and resolved order
  are recorded in the JSON for traceability.
- **Between iterations:** `GC.start` (and `GC.compact` where supported) to
  level the playing field across adapters.
- **Provenance:** every Tier 1/2/3 JSON records `cached_versions` (which
  versions came from cache), `version_run_order` (the order each version
  was actually measured), and `bench_seed` (so shuffles are reproducible).

---

## Running Specs Only

```bash
bundle exec rspec                                        # all specs
bundle exec rspec spec/adapters/ruby_csv_table_spec.rb  # one adapter
bundle exec rspec --format documentation                # verbose
```

---

## Available Rake Tasks

```
rake install                           # Unzip CSV benchmark files (alias for unzip_csv)
rake unzip_csv                         # Unzip csv_files.zip → csv_files/
rake zip_csv                           # Zip csv_files/ → csv_files.zip
rake spec                              # Run equivalence specs

rake bench                             # Full benchmark suite → results/<timestamp>_ruby<X.Y.Z>.raw.json
rake compare_versions <stats> <v1> ... # Apples-to-apples cross-version comparison JSON
rake report [f.json] [v1 v2 ...]       # Format results/comparison as Markdown (NO_MD=1 to skip writing .md)

rake compare                           # Legacy: cross-parser fair-group comparison (benchmarks/compare_parsers.rb)
rake versions                          # Legacy: standalone multi-version harness (benchmarks/smarter_csv_versions.rb)

rake chart_versions [f]                # SVG version-speedup chart
rake chart_adapters [f]                # SVG adapter-comparison chart
rake chart_speedup [f]                 # SVG speedup bar chart (SmarterCSV/C vs CSV.read)

rake merge_results <v1> [v2 ...]       # Refresh canonical per-version cache files (Tier 3)
rake backfill_cached_versions          # Retroactively add cached_versions marker to legacy raw JSONs (DRY=1 to preview)

rake profile[f]                        # Profile a single CSV file with tools/csv_profile.rb
```

Helper script:
```
bin/run_bench <N>                                                    # Run rake bench N times (no comparison)
bin/run_bench <N> <stats_method> <version1> [<version2>...]          # bench × N + compare_versions + report
```

---

## Project Structure

```
csv-benchmarks/
├── adapters/                         # One file per CSV mechanism
│   ├── base.rb
│   ├── ruby_csv/                     # Ruby stdlib CSV adapters
│   ├── smarter_csv/                  # SmarterCSV adapters
│   └── zsv/                          # ZSV adapters (opt-in)
├── spec/
│   ├── spec_helper.rb
│   ├── support/equivalence_helper.rb
│   ├── adapters/                     # One spec per :equivalent adapter
│   └── fixtures/                     # Small hand-crafted CSVs for specs
├── config/
│   ├── benchmark.rb                  # Adapters, versions, warmup/iterations, per-file options
│   └── chart.rb                      # Chart types, versions, adapter lists, colors
├── benchmarks/
│   ├── run_all.rb                    # All adapters × all csv_files/ → *.raw.json
│   ├── progress.rb                   # Shared per-file progress display
│   ├── eta.rb                        # Runtime estimator (per-version source lookup)
│   ├── compare_parsers.rb            # Legacy: fair-group comparison
│   ├── smarter_csv_versions.rb       # Legacy: standalone multi-version harness
│   ├── chart_versions.rb             # SVG generator (versions + adapters)
│   ├── chart_speedup.rb              # SVG generator (speedup vs Ruby CSV)
│   └── format_results.rb             # JSON → Markdown tables (handles all 3 tiers)
├── tools/
│   ├── csv_profile.rb                # ~30-metric CSV profiler
│   ├── generate_csv.rb               # Synthetic CSV generator
│   ├── merge_helpers.rb              # Shared logic: cell_value, within_run_stat, aggregate, collect_runs
│   ├── merge_results.rb              # Refresh canonical *.json (Tier 3, Option B with provenance)
│   ├── compare_versions.rb           # Apples-to-apples cross-version comparison JSON
│   └── backfill_cached_versions.rb   # Retroactively add cached_versions marker to legacy JSONs
├── bin/
│   └── run_bench                     # Convenience script: bench × N + compare + report
├── csv_files/                        # Gitignored — populated by rake install
│   ├── actual/                       # Real-world files (anonymized, no PII)
│   ├── synthetic/                    # Stress-test files (60k/40k/100k row variants)
│   └── not_used/                     # Older 20k variants kept for reference
├── csv_files.zip                     # Committed binary — source of truth for csv_files/
└── results/
    ├── <timestamp>_ruby<X.Y.Z>.raw.json                       # Tier 1: raw samples
    ├── <timestamp>_ruby<X.Y.Z>_<stats>.comparison.json        # Tier 2: aggregated comparison
    ├── smarter_csv_<version>.json                             # Tier 3: per-version canonical
    └── old/                                                   # Pre-Option-A historical data
```
