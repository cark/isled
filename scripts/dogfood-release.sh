#!/usr/bin/env bash
set -euo pipefail

repository_root=$(jj root --no-pager --color=never 2>/dev/null) || {
    printf 'dogfood-release error: run this command inside the project Jujutsu repository\n' >&2
    exit 2
}
readonly repository_root
readonly dogfood_root=${ISLED_DOGFOOD_ROOT:-$repository_root/.dogfood}

staging_directory=
next_pointer=

cleanup() {
    if [[ -n $staging_directory ]]; then
        case $staging_directory in
            "$dogfood_root"/.staging.*) rm -rf -- "$staging_directory" ;;
            *) printf 'refusing to remove unexpected staging path: %s\n' "$staging_directory" >&2 ;;
        esac
    fi
    if [[ -n $next_pointer ]]; then
        case $next_pointer in
            "$dogfood_root"/.current.next.*|"$dogfood_root"/.previous.next.*)
                rm -f -- "$next_pointer"
                ;;
            *) printf 'refusing to remove unexpected pointer path: %s\n' "$next_pointer" >&2 ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

show_help() {
    cat >&2 <<'EOF'
usage: scripts/dogfood-release.sh COMMAND [ARGUMENTS]

Commands:
  validate EXACT_COMMIT [--check-nix]
                        Validate matching inputs and retain a verified artifact.
  promote EXACT_COMMIT   Install the validated artifact; never builds or tests.
  rollback              Swap the current and previous promoted releases.
  status                Print the current and previous release revisions.

Run validate inside the pinned development environment.
Routine validation skips Nix package validation. Add --check-nix for packaging,
dependency or toolchain changes, or a pre-push/periodic package check.
Set ISLED_DOGFOOD_ROOT only to exercise an isolated release store.
EOF
}

usage() {
    show_help
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'dogfood-release error: required command is unavailable: %s\n' "$1" >&2
        exit 2
    }
}

revision_for_pointer() {
    local name=$1
    local pointer=$dogfood_root/$name
    local target
    local revision

    if [[ ! -L $pointer ]]; then
        printf 'none\n'
        return
    fi

    target=$(readlink -- "$pointer")
    case $target in
        releases/*) ;;
        *)
            printf 'dogfood-release error: invalid %s pointer: %s\n' "$name" "$target" >&2
            exit 2
            ;;
    esac

    if [[ ! -r $dogfood_root/$target/revision ]]; then
        printf 'dogfood-release error: %s release metadata is missing\n' "$name" >&2
        exit 2
    fi
    IFS= read -r revision <"$dogfood_root/$target/revision"
    if [[ ! $revision =~ ^[0-9a-f]{40}$ ]]; then
        printf 'dogfood-release error: %s release revision is malformed\n' "$name" >&2
        exit 2
    fi
    printf '%s\n' "$revision"
}

set_pointer() {
    local name=$1
    local revision=$2

    next_pointer=$dogfood_root/.$name.next.$$
    if [[ -e $next_pointer || -L $next_pointer ]]; then
        printf 'dogfood-release error: temporary pointer already exists: %s\n' \
            "$next_pointer" >&2
        exit 2
    fi
    ln -s "releases/$revision" "$next_pointer"
    mv -Tf -- "$next_pointer" "$dogfood_root/$name"
    next_pointer=
}

verify_release() {
    local revision=$1
    local release=$dogfood_root/releases/$revision
    local recorded_revision

    [[ -x $release/bin/isled ]] || {
        printf 'dogfood-release error: release binary is missing: %s\n' "$release" >&2
        exit 2
    }
    [[ -r $release/revision ]] || {
        printf 'dogfood-release error: release metadata is missing: %s\n' "$release" >&2
        exit 2
    }
    IFS= read -r recorded_revision <"$release/revision"
    [[ $recorded_revision == "$revision" ]] || {
        printf 'dogfood-release error: release metadata does not match %s\n' "$revision" >&2
        exit 2
    }
    if [[ -f $release/validation.json ]]; then
        python3 -B "$repository_root/scripts/release_validation.py" verify \
            "$release" "$dogfood_root" "$revision" >/dev/null
    fi
    "$release/bin/isled" --help >/dev/null
}

validate() {
    [[ $# -eq 1 || ( $# -eq 2 && ${2:-} == --check-nix ) ]] || usage
    require_command python3
    python3 -B "$repository_root/scripts/release_validation.py" validate \
        "$repository_root" "$dogfood_root" "$@"
}

promote() {
    [[ $# -eq 1 ]] || usage
    local candidate_revision=$1
    local candidate_binary
    local release
    local current_revision
    require_command python3
    require_command flock
    candidate_binary=$(python3 -B "$repository_root/scripts/release_validation.py" artifact \
        "$repository_root" "$dogfood_root" "$candidate_revision")
    mkdir -p "$dogfood_root/releases"
    staging_directory=$(mktemp -d "$dogfood_root/.staging.XXXXXX")
    mkdir -p "$staging_directory/bin"
    install -m 0755 "$candidate_binary" \
        "$staging_directory/bin/isled"
    printf '%s\n' "$candidate_revision" >"$staging_directory/revision"
    cp "${candidate_binary%/bin/isled}/validation.json" "$staging_directory/validation.json"
    python3 -B "$repository_root/scripts/release_validation.py" verify \
        "$staging_directory" "$dogfood_root" "$candidate_revision" >/dev/null
    "$staging_directory/bin/isled" --help >/dev/null

    release=$dogfood_root/releases/$candidate_revision
    exec 9>"$dogfood_root/.lock"
    flock -x 9
    if [[ -e $release ]]; then
        verify_release "$candidate_revision"
        cmp "$release/bin/isled" "$candidate_binary" || {
            printf 'existing release has a different artifact; selection unchanged\n' >&2
            exit 2
        }
    else
        mv -- "$staging_directory" "$release"
        staging_directory=
    fi

    current_revision=$(revision_for_pointer current)
    if [[ $current_revision != none && $current_revision != "$candidate_revision" ]]; then
        set_pointer previous "$current_revision"
    fi
    set_pointer current "$candidate_revision"
    verify_release "$candidate_revision"
    printf 'promoted\t%s\n' "$candidate_revision"
}

rollback() {
    [[ $# -eq 0 ]] || usage
    local current_revision
    local previous_revision

    require_command flock
    mkdir -p "$dogfood_root/releases"
    exec 9>"$dogfood_root/.lock"
    flock -x 9
    current_revision=$(revision_for_pointer current)
    previous_revision=$(revision_for_pointer previous)
    if [[ $current_revision == none || $previous_revision == none ]]; then
        printf 'dogfood-release error: rollback requires current and previous releases\n' >&2
        exit 2
    fi
    verify_release "$previous_revision"
    set_pointer previous "$current_revision"
    set_pointer current "$previous_revision"
    verify_release "$previous_revision"
    printf 'rolled-back\t%s\n' "$previous_revision"
}

status() {
    [[ $# -eq 0 ]] || usage
    printf 'current\t%s\n' "$(revision_for_pointer current)"
    printf 'previous\t%s\n' "$(revision_for_pointer previous)"
}

[[ $# -ge 1 ]] || usage
command_name=$1
shift
case $command_name in
    validate) validate "$@" ;;
    promote) promote "$@" ;;
    rollback) rollback "$@" ;;
    status) status "$@" ;;
    -h|--help|help)
        [[ $# -eq 0 ]] || usage
        show_help
        ;;
    *) usage ;;
esac
