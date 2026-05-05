#!/usr/bin/env bash
# Summarize all CSVs in results/ into results/summary.txt.
# First CSV (alphabetical) is the baseline; override with BASELINE=<label>.
# Other rows show percent change in mean CPU vs baseline.
# stdout is colored when it's a TTY (unless NO_COLOR is set); summary.txt is
# always plain text so it stays grep/diff-friendly.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd awk

mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/summary.txt"

shopt -s nullglob
csvs=( "$RESULTS_DIR"/*.csv )
if [[ ${#csvs[@]} -eq 0 ]]; then
  die "no CSV files in $RESULTS_DIR"
fi

# Color helpers. https://no-color.org and non-TTY both disable.
COLOR=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then COLOR=1; fi
ansi() {
  local code="$1"; shift
  if (( COLOR )); then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}
red()    { ansi 31 "$@"; }
green()  { ansi 32 "$@"; }
yellow() { ansi 33 "$@"; }
dim()    { ansi 2  "$@"; }
bold()   { ansi 1  "$@"; }

# Determine baseline label. Default: first sorted CSV. Override: BASELINE env var.
labels=()
for csv in "${csvs[@]}"; do
  labels+=( "$(basename "$csv" .csv)" )
done
BASELINE_LABEL="${BASELINE:-${labels[0]}}"

found=0
for l in "${labels[@]}"; do
  if [[ "$l" == "$BASELINE_LABEL" ]]; then found=1; break; fi
done
(( found )) || die "BASELINE='$BASELINE_LABEL' does not match any CSV in $RESULTS_DIR (have: ${labels[*]})"

# Compute n / mean / p50 / p95 / max for one CSV. Prints "n mean p50 p95 max".
compute_stats() {
  local csv="$1"
  tail -n +2 "$csv" \
    | cut -d, -f2 \
    | sort -n \
    | awk '
        { vals[NR] = $1 + 0; sum += $1 + 0 }
        END {
          n = NR
          if (n == 0) { print "0 0 0 0 0"; exit }
          mean = sum / n
          p50_idx = int((n + 1) * 0.50); if (p50_idx < 1) p50_idx = 1; if (p50_idx > n) p50_idx = n
          p95_idx = int((n + 1) * 0.95); if (p95_idx < 1) p95_idx = 1; if (p95_idx > n) p95_idx = n
          printf "%d %.1f %d %d %d\n", n, mean, vals[p50_idx], vals[p95_idx], vals[n]
        }'
}

header_plain=$(printf '%-20s  %6s  %8s  %8s  %8s  %8s  %9s' \
  "label" "n" "mean_m" "p50_m" "p95_m" "max_m" "delta%")
sep_plain=$(printf '%-20s  %6s  %8s  %8s  %8s  %8s  %9s' \
  "--------------------" "------" "--------" "--------" "--------" "--------" "---------")

{
  printf '%s\n' "$header_plain"
  printf '%s\n' "$sep_plain"
} > "$OUT"
printf '%s\n' "$(bold "$header_plain")"
printf '%s\n' "$sep_plain"

# Find the baseline CSV path and compute its stats first.
base_csv=""
for csv in "${csvs[@]}"; do
  if [[ "$(basename "$csv" .csv)" == "$BASELINE_LABEL" ]]; then
    base_csv="$csv"
    break
  fi
done
read -r base_n base_mean base_p50 base_p95 base_max < <(compute_stats "$base_csv")

emit_row() {
  local label="$1" n="$2" mean="$3" p50="$4" p95="$5" maxv="$6" delta_str="$7" color_fn="$8"
  # File: plain text, padded with %9s for the delta cell.
  printf '%-20s  %6d  %8s  %8d  %8d  %8d  %9s\n' \
    "$label" "$n" "$mean" "$p50" "$p95" "$maxv" "$delta_str" >> "$OUT"
  # Stdout: pad delta to 9 chars *before* wrapping with ANSI escapes — printf
  # width specifiers count bytes, so a colored cell would otherwise misalign.
  local delta_padded delta_colored
  delta_padded=$(printf '%9s' "$delta_str")
  delta_colored=$("$color_fn" "$delta_padded")
  printf '%-20s  %6d  %8s  %8d  %8d  %8d  %s\n' \
    "$label" "$n" "$mean" "$p50" "$p95" "$maxv" "$delta_colored"
}

# Parallel arrays collected during the table loop, used by the graphical
# panels below. Same row order as the printed table.
g_labels=()
g_means=()
g_maxes=()
g_color_fns=()
g_csvs=()

# Baseline row first.
emit_row "$BASELINE_LABEL" "$base_n" "$base_mean" "$base_p50" "$base_p95" "$base_max" "baseline" dim
g_labels+=( "$BASELINE_LABEL" )
g_means+=( "$base_mean" )
g_maxes+=( "$base_max" )
g_color_fns+=( dim )
g_csvs+=( "$base_csv" )

# Remaining rows in sorted order (skip the baseline).
for csv in "${csvs[@]}"; do
  label=$(basename "$csv" .csv)
  [[ "$label" == "$BASELINE_LABEL" ]] && continue

  read -r n mean p50 p95 maxv < <(compute_stats "$csv")

  # Avoid divide-by-zero. mean is %.1f-formatted; awk parses it natively.
  if awk "BEGIN { exit !($base_mean == 0) }"; then
    delta_str="n/a"
    color_fn=yellow
  else
    delta_num=$(awk "BEGIN { printf \"%+.0f\", ($mean - $base_mean) / $base_mean * 100 }")
    delta_str="${delta_num}%"
    abs=$(awk "BEGIN { x = $delta_num; if (x<0) x=-x; print x }")
    if awk "BEGIN { exit !($abs < 2) }"; then
      color_fn=yellow      # noise band: between -2% and +2%
    elif awk "BEGIN { exit !($delta_num > 0) }"; then
      color_fn=red         # CPU went up — regression
    else
      color_fn=green       # CPU went down — improvement
    fi
  fi
  emit_row "$label" "$n" "$mean" "$p50" "$p95" "$maxv" "$delta_str" "$color_fn"
  g_labels+=( "$label" )
  g_means+=( "$mean" )
  g_maxes+=( "$maxv" )
  g_color_fns+=( "$color_fn" )
  g_csvs+=( "$csv" )
done

# ===== graphical summary =====
# Block glyphs (▁▂▃▄▅▆▇█) are 1 display column each; we never feed them through
# printf width specifiers (which count bytes), so display alignment is preserved.
# Padding to fixed widths is composed of plain spaces, computed in pure bash.

# Aggregates that drive scaling.
max_mean=$(printf '%s\n' "${g_means[@]}" | sort -nr | head -1)
global_max=$(printf '%s\n' "${g_maxes[@]}" | sort -nr | head -1)

# --- bar chart: mean CPU per version (bars proportional to max_mean) ---
bar_header="mean CPU (mCPU):"
{ printf '\n'; printf '%s\n' "$bar_header"; } >> "$OUT"
printf '\n'
printf '%s\n' "$(bold "$bar_header")"

bar_w_max=50
for i in "${!g_labels[@]}"; do
  bar_n=$(awk -v m="${g_means[i]}" -v mx="$max_mean" -v w="$bar_w_max" \
        'BEGIN { print (mx>0) ? int(m/mx*w) : 0 }')
  bar=""; for ((j=0;     j<bar_n;     j++)); do bar+="█"; done
  pad=""; for ((j=bar_n; j<bar_w_max; j++)); do pad+=" "; done

  printf '  %-20s  %s%s  %5.1f\n' "${g_labels[i]}" "$bar" "$pad" "${g_means[i]}" >> "$OUT"
  colored_bar=$("${g_color_fns[i]}" "$bar")
  printf '  %-20s  %s%s  %5.1f\n' "${g_labels[i]}" "$colored_bar" "$pad" "${g_means[i]}"
done

# --- sparkline: cpu over time per version, shared y-scale anchored at 0 ---
# The CSV stream must stay in capture order (no sort) so sparkline shape is
# meaningful — that's why we don't reuse compute_stats.
sparkline() {
  local csv="$1" gmax="$2" w="${3:-60}"
  tail -n +2 "$csv" | cut -d, -f2 | awk -v gmax="$gmax" -v MAX_W="$w" '
      BEGIN {
        b[1]="▁"; b[2]="▂"; b[3]="▃"; b[4]="▄"
        b[5]="▅"; b[6]="▆"; b[7]="▇"; b[8]="█"
      }
      { vals[NR] = $1 + 0 }
      END {
        n = NR
        if (n == 0) { for (k = 0; k < MAX_W; k++) printf " "; exit }
        bw = (n > MAX_W) ? n / MAX_W : 1
        cols = (n > MAX_W) ? MAX_W : n
        for (c = 0; c < cols; c++) {
          if (n > MAX_W) {
            lo = int(c * bw) + 1
            hi = int((c + 1) * bw); if (hi < lo) hi = lo; if (hi > n) hi = n
            sum = 0; cnt = 0
            for (i = lo; i <= hi; i++) { sum += vals[i]; cnt++ }
            v = (cnt > 0) ? sum / cnt : 0
          } else {
            v = vals[c + 1]
          }
          if (gmax > 0) {
            level = int(v / gmax * 7) + 1
            if (level < 1) level = 1; if (level > 8) level = 8
          } else level = 1
          printf "%s", b[level]
        }
        # Pad short sparklines so all rows are identical width.
        for (k = cols; k < MAX_W; k++) printf " "
      }'
}

spark_header="cpu over time (cadence=15s, max=${global_max} mCPU):"
{ printf '\n'; printf '%s\n' "$spark_header"; } >> "$OUT"
printf '\n'
printf '%s\n' "$(bold "$spark_header")"

for i in "${!g_labels[@]}"; do
  spark=$(sparkline "${g_csvs[i]}" "$global_max" 60)
  printf '  %-20s  %s\n' "${g_labels[i]}" "$spark" >> "$OUT"
  colored_spark=$("${g_color_fns[i]}" "$spark")
  printf '  %-20s  %s\n' "${g_labels[i]}" "$colored_spark"
done
