#!/bin/bash

# Shared by the app and disk-image packagers; source this file before calling.
validate_release_version() {
    local version="$1" build_number="$2" identifier
    local pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
    if [[ ! "$version" =~ $pattern ]]; then
        echo "Expected a release version such as 0.1.0 or 0.2.0-beta.1, without a leading v." >&2
        return 2
    fi
    if [[ "$version" == *-* ]]; then
        local prerelease="${version#*-}"
        local identifiers=()
        IFS='.' read -r -a identifiers <<< "$prerelease"
        for identifier in "${identifiers[@]}"; do
            if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" =~ ^0[0-9]+$ ]]; then
                echo "Numeric prerelease identifiers must not contain leading zeroes." >&2
                return 2
            fi
        done
    fi
    if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        echo "The bundle build number must be a positive integer." >&2
        return 2
    fi
}
