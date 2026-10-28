#!/bin/bash

#==========================================================
# SETTINGS — edit here
#==========================================================

ORCA="/path/to/orca/orca"

export PATH="/path/to/orca:$PATH"
export LD_LIBRARY_PATH="/path/to/orca/lib:${LD_LIBRARY_PATH:-}"

natom=8              		# atoms per structure
k=4                  		# max ORCA jobs at once
pause=5              		# seconds between launches
stop_grace=10        		# wait before force-kill
lines_A="8"          		# list of atoms in ghost monomer B 
lines_B="1 2 3 4 5 6 7"         # list of atoms in ghost monomer B 

head_file="H"
tail_file="T"

normal_text="ORCA TERMINATED NORMALLY"
remove_aux="yes"

# CPU NOTE:
# Check the parallel setting in H, e.g.:
#
#   %pal
#      nprocs 4
#   end
#
# Approx. maximum core use:
#
#   k × nprocs
#
# Ensure this does not exceed the cores allocated on the node.
# k limits the number of ORCA jobs, not the cores used by each job.
# Also check memory use when several ORCA jobs run together.


#==========================================================
# INPUT
# Usage: ./run_orca.sh FILE START END
#==========================================================

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 FILE START END" >&2
    exit 1
fi

file=$1
start=$2
end=$3


#==========================================================
# CHECKS
#==========================================================

is_integer()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

if [ ! -r "$file" ]; then
    echo "Error: cannot read $file" >&2
    exit 1
fi

if [ ! -r "$head_file" ] || [ ! -r "$tail_file" ]; then
    echo "Error: cannot read $head_file or $tail_file" >&2
    exit 1
fi

if [ ! -x "$ORCA" ]; then
    echo "Error: ORCA not executable: $ORCA" >&2
    exit 1
fi

if ! is_integer "$start" ||
   ! is_integer "$end" ||
   [ "$start" -lt 1 ] ||
   [ "$end" -lt "$start" ]; then
    echo "Error: require 1 <= START <= END" >&2
    exit 1
fi

if ! is_integer "$natom" || [ "$natom" -lt 1 ]; then
    echo "Error: natom must be >= 1" >&2
    exit 1
fi

if ! is_integer "$k" || [ "$k" -lt 1 ]; then
    echo "Error: k must be >= 1" >&2
    exit 1
fi

if ! is_integer "$pause"; then
    echo "Error: pause must be a non-negative integer" >&2
    exit 1
fi

if ! is_integer "$stop_grace" || [ "$stop_grace" -lt 1 ]; then
    echo "Error: stop_grace must be >= 1" >&2
    exit 1
fi


#==========================================================
# SEMAPHORE AND CLEANUP
#==========================================================

pids=()
all_waited=0

sem_dir=$(mktemp -d /tmp/orca_sem.XXXXXX) || exit 1
fifo="$sem_dir/fifo"
running_file="$sem_dir/running.pids"

stop_jobs()
{
    # Get only workers that are still running
    jobs -pr > "$running_file"

    if [ -s "$running_file" ]; then
        echo "Stopping running ORCA jobs..." >&2

        while IFS= read -r pid; do
            kill -TERM "$pid" 2>/dev/null || :
        done < "$running_file"
    fi

    # Reap all workers; ignore already-waited PIDs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || :
    done
}

cleanup()
{
    exit_status=$?

    # Avoid recursive traps
    trap - EXIT HUP INT TERM

    if [ "$all_waited" -eq 0 ]; then
        stop_jobs
    fi

    exec 3>&- 2>/dev/null
    rm -f "$fifo" "$running_file"
    rmdir "$sem_dir" 2>/dev/null

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkfifo "$fifo" || exit 1
exec 3<>"$fifo" || exit 1
rm -f "$fifo"

# Add k tokens
for ((j = 0; j < k; j++)); do
    printf '\n' >&3
done

> ignore.log

#==========================================================
# RUN
#==========================================================

block_size=$((natom + 2))

for ((i = start; i <= end; i++)); do

    echo "Preparing structure $i"

    # Extract natom coordinate lines
    if ! awk -v i="$i" -v b="$block_size" '
        NR >= (i*b)-(b-3) && NR <= (i*b) {
            print
            count++
        }

        END {
            if (count != b-2)
                exit 1
        }
    ' "$file" > "$i.tmp"; then
        echo "Error: structure $i is missing or incomplete" >&2
        rm -f "$i.tmp"
        exit 1
    fi

	# Create ORCA-Style Ghost Atoms tmp
	awk -v list="$lines_A" '
	BEGIN {
			n = split(list, a, " ")
			for (i = 1; i <= n; i++) ghost[a[i]] = 1
	}
    
	ghost[NR] && NF > 0 {
		sub(/^[ \t]*[^ \t]+/, "& :")
    }
	{ print }
	' "$i.tmp" > "${i}_a.tmp"
	
	awk -v list="$lines_B" '
	BEGIN {
			n = split(list, a, " ")
			for (i = 1; i <= n; i++) ghost[a[i]] = 1
	}
    
	ghost[NR] && NF > 0 {
		sub(/^[ \t]*[^ \t]+/, "& :")
    }
	{ print }
	' "$i.tmp" > "${i}_b.tmp"
	
    # Build ORCA input
    if ! cat "$head_file" "B1" "$i.tmp" "C1" "$i.tmp" "B2" "${i}_a.tmp" "C2" \
	    "${i}_a.tmp" "B3" "${i}_b.tmp" "C3" "${i}_b.tmp" "$tail_file" > "$i.inp"; then
        echo "Error: failed to create $i.inp" >&2
        rm -f "$i.tmp" "${i}_a.tmp" "${i}_b.tmp" "$i.inp" 
        exit 1
    fi

    rm -f "$i.tmp" 
    rm -f "${i}_a.tmp" "${i}_b.tmp"
    
    # Wait for a free token
    if ! read -r -u 3; then
        echo "Error: semaphore read failed" >&2
        exit 1
    fi

    (
        orca_pid=""

        stop_worker()
        {
            signal_status=$1

            trap - HUP INT TERM

            if [ -n "$orca_pid" ]; then
                kill -TERM "$orca_pid" 2>/dev/null || :

                # Grace period
                for ((second = 0; second < stop_grace; second++)); do
                    if ! kill -0 "$orca_pid" 2>/dev/null; then
                        break
                    fi

                    sleep 1
                done

                # Force-stop if needed
                if kill -0 "$orca_pid" 2>/dev/null; then
                    kill -KILL "$orca_pid" 2>/dev/null || :
                fi

                wait "$orca_pid" 2>/dev/null || :
            fi

            # Return token if parent is still running
            printf '\n' >&3 2>/dev/null || :

            exit "$signal_status"
        }

        trap 'stop_worker 129' HUP
        trap 'stop_worker 130' INT
        trap 'stop_worker 143' TERM

        echo "Starting structure $i"

        "$ORCA" "$i.inp" > "$i.out" 2> ignore.log &
        orca_pid=$!

        wait "$orca_pid"
        orca_status=$?
        orca_pid=""

        # Exit code alone is not enough
        if [ "$orca_status" -eq 0 ] &&
           grep -Fq "$normal_text" "$i.out"; then
            echo "Finished structure $i"
            job_status=0
        else
            echo "Failed structure $i — see $i.out" >&2
            job_status=1
        fi

        rm -f -- "$i"*bas* "$i"*bibtex "$i"*pound* "$i"*tmp 
	rm -f -- "$i"_*
	rm -f -- "$i"*gbw

        # Return token
        printf '\n' >&3

        exit "$job_status"
    ) &

    pids+=("$!")

    # Delay before next launch
    if [ "$i" -lt "$end" ]; then
        sleep "$pause"
    fi
done


#==========================================================
# WAIT
#==========================================================

result=0

for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        result=1
    fi
done

all_waited=1


#==========================================================
# FINAL CLEANUP
#==========================================================

if [ "$remove_aux" = "yes" ]; then
    rm -f -- ./*.bas* ./*.bibtex ./*pound*
fi

if [ "$result" -eq 0 ]; then
    echo "All calculations finished normally"
else
    echo "One or more calculations failed" >&2
fi

exit "$result"

