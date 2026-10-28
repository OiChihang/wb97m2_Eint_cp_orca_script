#!/usr/bin/env bash

# Extract ORCA energies from *.out and geometry from matching *.inp files.
# Input files are processed in natural order: 1.out, 2.out, 10.out, ...

set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# USER CONFIGURATION
# These defaults can also be overridden with the command-line options below.
#
# Results are read backwards from EOF until the LAST summary block is found.
# HEAD_LINES controls how far into each companion input the geometry is sought.
# ============================================================================
HEAD_LINES=120
SUMMARY_KEY="BSSE COUNTERPOISE CORRECTION SUMMARY"
DIMER_KEY="Dimer energy"
INTERACTION_KEY="Interaction energy"
INPUT_EXTENSION=".inp"

usage() {
    cat <<'USAGE'
Usage: orcacatcher.sh [options]

Process *.out files in natural numerical order, pairing each one with an input
of the same basename (for example, 1.out with 1.inp). By default, values are
read backwards from EOF to the final BSSE COUNTERPOISE CORRECTION SUMMARY.
The scan stops at that heading, so no line-range adjustment is needed and the
earlier calculation output is not read. The first token after ':' is extracted,
so units such as Eh and cm**-1 are not included. 

Outputs:
  PREFIX_dimer_energy_list.dat
  PREFIX_interaction_energy_list.dat
  PREFIX_energies.tsv
  PREFIX_dimer_energy.xyz
  PREFIX_interaction_energy.xyz

Options:
  -p, --prefix NAME          Base name for outputs (default: orca_results)
  -d, --input-dir DIR       Directory containing inputs (default: .)
  -g, --glob PATTERN        Input filename pattern (default: *.out)
  -H, --head-lines NUMBER   Input lines searched for geometry (default: 120)
      --summary-key TEXT    Summary-block heading
      --dimer-key TEXT      Dimer label (default: Dimer energy)
      --interaction-key TEXT
                            Interaction label (default: Interaction energy)
      --input-extension EXT Companion input extension (default: .inp)
      --dimer-list FILE     Dimer-energy list output
      --interaction-list FILE
                            Interaction-energy list output
      --energy-table FILE   Two-energy TSV output
      --dimer-xyz FILE      XYZ frames labelled with dimer energy
      --interaction-xyz FILE
                            XYZ frames labelled with interaction energy
      --skip-invalid        Warn and skip incomplete/malformed files
      --delete-inputs       Delete successfully merged companion input files
                            after all outputs are written successfully
  -h, --help                Show this help

Numeric strings retain their original precision. Only whitespace is added to
align decimal points. Relative output paths are resolved from the directory
where the script is run.

Example:
  ./orcacatcher.sh -p sf6ar_orca -d . --delete-inputs
USAGE
}

prefix="orca_results"
input_dir="."
input_glob="*.out"
head_lines=$HEAD_LINES
summary_key=$SUMMARY_KEY
dimer_key=$DIMER_KEY
interaction_key=$INTERACTION_KEY
input_extension=$INPUT_EXTENSION
skip_invalid=false
delete_inputs=false
dimer_list=""
interaction_list=""
energy_table=""
dimer_xyz=""
interaction_xyz=""

while (($# > 0)); do
    case "$1" in
        -p|--prefix)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            prefix=$2
            shift 2
            ;;
        -d|--input-dir)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            input_dir=$2
            shift 2
            ;;
        -g|--glob)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            input_glob=$2
            shift 2
            ;;
        -H|--head-lines)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            head_lines=$2
            shift 2
            ;;
        --summary-key)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            summary_key=$2
            shift 2
            ;;
        --dimer-key)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            dimer_key=$2
            shift 2
            ;;
        --interaction-key)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            interaction_key=$2
            shift 2
            ;;
        --input-extension)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            input_extension=$2
            shift 2
            ;;
        --dimer-list)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            dimer_list=$2
            shift 2
            ;;
        --interaction-list)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            interaction_list=$2
            shift 2
            ;;
        --energy-table)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            energy_table=$2
            shift 2
            ;;
        --dimer-xyz)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            dimer_xyz=$2
            shift 2
            ;;
        --interaction-xyz)
            (($# >= 2)) || { echo "Error: $1 requires a value" >&2; exit 2; }
            interaction_xyz=$2
            shift 2
            ;;
        --skip-invalid)
            skip_invalid=true
            shift
            ;;
        --delete-inputs)
            delete_inputs=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -d "$input_dir" ]] || { echo "Error: input directory not found: $input_dir" >&2; exit 2; }
for number in "$head_lines"; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || {
        echo "Error: --head-lines must be a positive integer" >&2
        exit 2
    }
done
[[ -n "$summary_key" && -n "$dimer_key" && -n "$interaction_key" ]] || {
    echo "Error: parameter names cannot be empty" >&2
    exit 2
}
[[ -n "$input_extension" ]] || { echo "Error: input extension cannot be empty" >&2; exit 2; }
[[ "$input_extension" == .* ]] || input_extension=".$input_extension"

dimer_list=${dimer_list:-"${prefix}_dimer_energy_list.dat"}
interaction_list=${interaction_list:-"${prefix}_interaction_energy_list.dat"}
energy_table=${energy_table:-"${prefix}_energies.tsv"}
dimer_xyz=${dimer_xyz:-"${prefix}_dimer_energy.xyz"}
interaction_xyz=${interaction_xyz:-"${prefix}_interaction_energy.xyz"}

outputs=("$dimer_list" "$interaction_list" "$energy_table" "$dimer_xyz" "$interaction_xyz")
for output in "${outputs[@]}"; do
    parent=$(dirname -- "$output")
    [[ -d "$parent" ]] || { echo "Error: output directory not found: $parent" >&2; exit 2; }
done
for ((i = 0; i < ${#outputs[@]}; i++)); do
    for ((j = i + 1; j < ${#outputs[@]}; j++)); do
        [[ "${outputs[i]}" != "${outputs[j]}" ]] || {
            echo "Error: output paths must be distinct: ${outputs[i]}" >&2
            exit 2
        }
    done
done

for program in awk tac find sort mktemp; do
    command -v "$program" >/dev/null || {
        echo "Error: '$program' is required" >&2
        exit 2
    }
done
if ! sort -V </dev/null >/dev/null 2>&1; then
    echo "Error: this script requires a version of sort that supports -V" >&2
    exit 2
fi

# The read loop works with older Bash releases that lack `mapfile -d`.
files=()
while IFS= read -r -d '' file; do
    files[${#files[@]}]=$file
done < <(
    find "$input_dir" -maxdepth 1 -type f -name "$input_glob" -print0 | sort -zV
)

((${#files[@]} > 0)) || {
    echo "Error: no files matching '$input_glob' in '$input_dir'" >&2
    exit 1
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/orca_extract.XXXXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

raw_dimer_list="$tmp_dir/dimer.list"
raw_interaction_list="$tmp_dir/interaction.list"
raw_energy_table="$tmp_dir/energies.tsv"
raw_dimer_xyz="$tmp_dir/dimer.xyz"
raw_interaction_xyz="$tmp_dir/interaction.xyz"

: >"$raw_dimer_list"
: >"$raw_interaction_list"
: >"$raw_dimer_xyz"
: >"$raw_interaction_xyz"
printf 'file\t%s\t%s\n' "$dimer_key" "$interaction_key" >"$raw_energy_table"

# tac supplies lines from EOF backwards. Bash collects the two exact labels and
# stops at the first summary heading it encounters, which is the final summary
# in the original file. Earlier calculation output is never read by the loop.
extract_energy_pair() {
    local file=$1
    local line label value_text value
    local dimer_value=""
    local interaction_value=""

    while IFS= read -r line; do
        line=${line%$'\r'}

        if [[ "$line" == *"$summary_key"* ]]; then
            [[ -n "$dimer_value" && -n "$interaction_value" ]] || return 1
            printf '%s\t%s\n' "$dimer_value" "$interaction_value"
            return 0
        fi

        [[ "$line" == *:* ]] || continue
        label=${line%%:*}
        label=${label#"${label%%[![:space:]]*}"}
        label=${label%"${label##*[![:space:]]}"}

        if [[ "$label" == "$dimer_key" || "$label" == "$interaction_key" ]]; then
            value_text=${line#*:}
            value_text=${value_text#"${value_text%%[![:space:]]*}"}
            value=${value_text%%[[:space:]]*}
            if [[ "$label" == "$dimer_key" ]]; then
                dimer_value=$value
            else
                interaction_value=$value
            fi
        fi
    done < <(tac -- "$file")

    return 1
}

# ORCA normally echoes the input as "|  n> * xyz charge multiplicity" followed
# by the coordinates. Companion *.inp files normally contain plain "* xyz".
# Both forms are supported.
extract_geometry() {
    local file=$1
    awk -v max_lines="$head_lines" '
        function is_number(value) {
            return value ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([EeDd][+-]?[0-9]+)?$/
        }
        function clean(raw, cleaned) {
            cleaned = raw
            sub(/\r$/, "", cleaned)
            sub(/^[[:space:]]*\|[[:space:]]*[0-9]+>[[:space:]]*/, "", cleaned)
            return cleaned
        }
        NR > max_lines { exit }
        {
            line = clean($0)
            lower = tolower(line)
        }
        !in_geometry && lower ~ /^[[:space:]]*\*[[:space:]]*xyz[[:space:]]/ {
            in_geometry = 1
            next
        }
        in_geometry {
            trimmed = line
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
            if (trimmed == "") next
            if (trimmed ~ /^\*/) {
                finished = 1
                exit
            }
            fields = split(trimmed, part, /[[:space:]]+/)
            if (fields < 4 || part[1] !~ /^[[:alpha:]][[:alpha:]]?$/ ||
                !is_number(part[2]) || !is_number(part[3]) || !is_number(part[4])) {
                malformed = 1
                exit
            }
            print part[1], part[2], part[3], part[4]
            atoms++
        }
        END {
            if (!finished || atoms == 0 || malformed) exit 1
        }
    ' "$file"
}

# These formatters add spaces only; numeric strings are never converted or
# rounded, so all digits from the ORCA output and geometry remain unchanged.
align_number_file() {
    local source_file=$1
    local destination_file=$2
    awk '
        function left_width(value, point) {
            point = index(value, ".")
            return point ? point - 1 : length(value)
        }
        {
            value[NR] = $0
            width[NR] = left_width($0)
            if (width[NR] > maximum) maximum = width[NR]
        }
        END {
            for (line = 1; line <= NR; line++)
                printf "%*s%s\n", maximum - width[line], "", value[line]
        }
    ' "$source_file" >"$destination_file"
}

align_table_file() {
    local source_file=$1
    local destination_file=$2
    awk -F '\t' '
        function measure(value, column, point, left, right) {
            point = index(value, ".")
            left = point ? point - 1 : length(value)
            right = point ? length(value) - point : 0
            cell_left[row, column] = left
            cell_right[row, column] = right
            if (left > max_left[column]) max_left[column] = left
            if (right > max_right[column]) max_right[column] = right
        }
        NR == 1 { header = $0; columns = NF; next }
        {
            row++
            for (column = 1; column <= NF; column++) cell[row, column] = $column
            for (column = 2; column <= NF; column++) measure($column, column)
        }
        END {
            print header
            for (record = 1; record <= row; record++) {
                printf "%s", cell[record, 1]
                for (column = 2; column <= columns; column++) {
                    printf "\t%*s%s%*s", \
                        max_left[column] - cell_left[record, column], "", \
                        cell[record, column], \
                        max_right[column] - cell_right[record, column], ""
                }
                printf "\n"
            }
        }
    ' "$source_file" >"$destination_file"
}

align_xyz_file() {
    local source_file=$1
    local destination_file=$2
    awk '
        function measure(value, column, line_number, point, left, right) {
            point = index(value, ".")
            left = point ? point - 1 : length(value)
            right = point ? length(value) - point : 0
            number_left[line_number, column] = left
            number_right[line_number, column] = right
            if (left > max_left[column]) max_left[column] = left
            if (right > max_right[column]) max_right[column] = right
        }
        remaining == 0 {
            kind[NR] = "count"
            text[NR] = $1
            remaining = $1 + 0
            expecting_comment = 1
            next
        }
        expecting_comment {
            kind[NR] = "comment"
            text[NR] = $1
            measure($1, 0, NR)
            expecting_comment = 0
            next
        }
        remaining > 0 {
            kind[NR] = "atom"
            atom[NR] = $1
            if (length($1) > atom_width) atom_width = length($1)
            for (column = 1; column <= 3; column++) {
                number[NR, column] = $(column + 1)
                measure($(column + 1), column, NR)
            }
            remaining--
        }
        END {
            for (line_number = 1; line_number <= NR; line_number++) {
                if (kind[line_number] == "count") {
                    print text[line_number]
                } else if (kind[line_number] == "comment") {
                    printf "%*s%s\n", \
                        max_left[0] - number_left[line_number, 0], "", text[line_number]
                } else if (kind[line_number] == "atom") {
                    printf "%-*s", atom_width, atom[line_number]
                    for (column = 1; column <= 3; column++) {
                        printf "  %*s%s%*s", \
                            max_left[column] - number_left[line_number, column], "", \
                            number[line_number, column], \
                            max_right[column] - number_right[line_number, column], ""
                    }
                    printf "\n"
                }
            }
        }
    ' "$source_file" >"$destination_file"
}

numeric_pattern='^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([EeDd][+-]?[0-9]+)?$'
processed=0
skipped=0
processed_inputs=()

for file in "${files[@]}"; do
    file_name=$(basename -- "$file")
    input_file="${file%.*}${input_extension}"
    energy_pair=""
    energies_ok=true
    if ! energy_pair=$(extract_energy_pair "$file"); then
        energies_ok=false
    fi
    dimer_value=""
    interaction_value=""
    if [[ "$energies_ok" == true ]]; then
        IFS=$'\t' read -r dimer_value interaction_value <<<"$energy_pair"
    fi

    coordinates=""
    geometry_ok=true
    if [[ ! -f "$input_file" ]] || ! coordinates=$(extract_geometry "$input_file"); then
        geometry_ok=false
    fi

    if [[ "$energies_ok" != true ||
          ! "$dimer_value" =~ $numeric_pattern ||
          ! "$interaction_value" =~ $numeric_pattern ||
          "$geometry_ok" != true ]]; then
        message="Invalid data in '$file_name': expected exact labels '$dimer_key' and '$interaction_key' in the final '$summary_key' block, plus a valid geometry in companion input '$input_file'"
        if [[ "$skip_invalid" == true ]]; then
            echo "Warning: $message; skipped" >&2
            ((skipped += 1))
            continue
        fi
        echo "Error: $message" >&2
        echo "No output files were replaced. Use --skip-invalid to omit incomplete calculations." >&2
        exit 1
    fi

    atom_count=$(printf '%s\n' "$coordinates" | awk 'NF { count++ } END { print count + 0 }')
    ((atom_count > 0)) || {
        echo "Error: no atoms extracted from '$file_name'" >&2
        exit 1
    }

    printf '%s\n' "$dimer_value" >>"$raw_dimer_list"
    printf '%s\n' "$interaction_value" >>"$raw_interaction_list"
    printf '%s\t%s\t%s\n' "$file_name" "$dimer_value" "$interaction_value" >>"$raw_energy_table"
    printf '%s\n%s\n%s\n' "$atom_count" "$dimer_value" "$coordinates" >>"$raw_dimer_xyz"
    printf '%s\n%s\n%s\n' "$atom_count" "$interaction_value" "$coordinates" >>"$raw_interaction_xyz"
#    printf '%s\n' "$file"
    processed_inputs[${#processed_inputs[@]}]=$input_file
    ((processed += 1))
done

((processed > 0)) || {
    echo "Error: no valid files were processed; no output files were replaced" >&2
    exit 1
}

aligned_dimer_list="$tmp_dir/dimer.aligned.list"
aligned_interaction_list="$tmp_dir/interaction.aligned.list"
aligned_energy_table="$tmp_dir/energies.aligned.tsv"
aligned_dimer_xyz="$tmp_dir/dimer.aligned.xyz"
aligned_interaction_xyz="$tmp_dir/interaction.aligned.xyz"

align_number_file "$raw_dimer_list" "$aligned_dimer_list"
align_number_file "$raw_interaction_list" "$aligned_interaction_list"
align_table_file "$raw_energy_table" "$aligned_energy_table"
align_xyz_file "$raw_dimer_xyz" "$aligned_dimer_xyz"
align_xyz_file "$raw_interaction_xyz" "$aligned_interaction_xyz"

mv -f -- "$aligned_dimer_list" "$dimer_list"
mv -f -- "$aligned_interaction_list" "$interaction_list"
mv -f -- "$aligned_energy_table" "$energy_table"
mv -f -- "$aligned_dimer_xyz" "$dimer_xyz"
mv -f -- "$aligned_interaction_xyz" "$interaction_xyz"

echo "Processed $processed file(s) in natural order; skipped $skipped." >&2
printf 'Created:\n  %s\n  %s\n  %s\n  %s\n  %s\n' \
    "$dimer_list" "$interaction_list" "$energy_table" \
    "$dimer_xyz" "$interaction_xyz"

if [[ "$delete_inputs" == true ]]; then
    deleted_inputs=0
    for input_file in "${processed_inputs[@]}"; do
        if [[ -f "$input_file" ]]; then
            rm -f -- "$input_file"
            ((deleted_inputs += 1))
        fi
    done
    echo "Deleted $deleted_inputs successfully merged companion input file(s); output files were kept." >&2
fi
