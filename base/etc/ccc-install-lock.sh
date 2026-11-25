#!/bin/bash
set -e
# Run as the home owner. The marker is a lease, not a filesystem lock.
marker=$1
shift
max_age=${CCC_INSTALL_LOCK_TIMEOUT:-3600}
if [[ ! $max_age =~ ^[1-9][0-9]{0,11}$ ]]; then
    echo 'CCC_INSTALL_LOCK_TIMEOUT must be a positive integer (seconds).' >&2
    exit 64
fi

read_marker() {
    [[ ! -L $marker && -f $marker ]] || return 1
    # Include inode and sub-second times, but not the client-local device ID.
    observed=$(LC_ALL=C TZ=UTC0 stat -c '%i:%y:%z|%Y' -- "$marker" 2>/dev/null) || return 1
    record=
    IFS= read -r record 2>/dev/null < "$marker" || :
    [[ $(LC_ALL=C TZ=UTC0 stat -c '%i:%y:%z|%Y' -- "$marker" 2>/dev/null) == "$observed" ]]
}

# Release and stale recovery both delete a known generation. Elect one
# remover for that generation with atomic mkdir, not advisory locking. If the
# remover is killed, a later contender can claim the next slot after expiry.
remove_observed_marker() {
    local expected=$observed expected_record=$record key gate slot ticket stamp now
    # Use the UUID for new markers, falling back to shared metadata for legacy ones.
    if [[ $expected_record =~ ^[0-9]+\ ([a-f0-9-]{36})$ ]]; then
        key=${BASH_REMATCH[1]}
    else
        key=$(printf '%s\n' "$expected" "$expected_record" | sha256sum) || return 1
    fi
    gate="$marker.remove-${key%% *}"
    (umask 077; mkdir -- "$gate") 2>/dev/null || [[ -d $gate && ! -L $gate ]] || return 1
    for ((slot=0; ; slot++)); do
        ticket="$gate/$slot"
        if (umask 077; mkdir -- "$ticket") 2>/dev/null; then
            break
        fi
        [[ -d $ticket && ! -L $ticket ]] || return 1
        stamp=$(stat -c %Y -- "$ticket" 2>/dev/null) || return 1
        now=$(date +%s) || return 1
        (( now - stamp >= max_age )) || return 1
    done

    if read_marker && [[ $observed == "$expected" && $record == "$expected_record" ]]; then
        # Never act on an election ticket that itself expired while paused.
        stamp=$(stat -c %Y -- "$ticket" 2>/dev/null) || return 1
        now=$(date +%s) || return 1
        (( now - stamp < max_age )) || return 1
        rm -f -- "$marker" || return 1
        rm -rf -- "$gate" || :
        return 0
    fi
    # This gate names the obsolete marker, never its replacement.
    rm -rf -- "$gate" || :
    return 1
}

cleanup() {
    local now
    [[ -n ${claimed_record:-} ]] || return 0
    now=$(date +%s) || return 0
    # Once our lease has expired, a successor may already be taking over.
    if (( now - claimed_at < max_age )) && read_marker && [[ $record == "$claimed_record" ]]; then
        remove_observed_marker || :
    fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

create_failures=0
while :; do
    if [[ -L $marker || ( -e $marker && ! -f $marker ) ]]; then
        echo "Invalid CCC installation marker: $marker (expected a regular file)" >&2
        exit 1
    fi
    if [[ ! -e $marker ]]; then
        claimed_at=$(date +%s)
        # The ID distinguishes successive owners even in the same second.
        IFS= read -r owner < /proc/sys/kernel/random/uuid
        candidate="$claimed_at $owner"
        # noclobber creates the name exclusively; it does not use advisory locks.
        # Readers seeing the file before printf completes use its fresh mtime.
        if (umask 077; set -o noclobber; printf '%s\n' "$candidate" > "$marker") 2>/dev/null; then
            claimed_record=$candidate
            break
        fi
        if [[ ! -e $marker && ! -L $marker ]]; then
            # A holder may have removed the marker after our create lost the
            # race. Retry, but don't hang on a persistently unwritable home.
            create_failures=$((create_failures + 1))
            if (( create_failures >= 3 )); then
                echo "Cannot create CCC installation marker: $marker" >&2
                exit 1
            fi
        else
            create_failures=0
        fi
    elif read_marker; then
        create_failures=0
        now=$(date +%s)
        if [[ $record =~ ^([0-9]{1,12})([[:blank:]]+[^[:blank:]]+)?$ ]]; then
            stamp=$((10#${BASH_REMATCH[1]}))
        else
            stamp=${observed##*|}  # Legacy touch-only or incomplete marker.
        fi
        if (( now - stamp >= max_age )); then
            if remove_observed_marker; then
                echo "Replacing expired CCC installation marker: $marker" >&2
                continue
            fi
        fi
    fi
    sleep 2
done

"$@"
