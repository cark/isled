#!/usr/bin/env bash
set -euo pipefail

repository_root=$(jj root --no-pager --color=never)
readonly repository_root
readonly dogfood_script=$repository_root/scripts/dogfood-release.sh
readonly test_prefix=${TMPDIR:-/tmp}/isled-dogfood-test.
test_root=$(mktemp -d "$test_prefix"XXXXXX)
readonly test_root

cleanup() {
    case $test_root in
        "$test_prefix"*) rm -rf -- "$test_root" ;;
        *) printf 'refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

readonly first_revision=1111111111111111111111111111111111111111
readonly second_revision=2222222222222222222222222222222222222222

make_release() {
    local revision=$1
    local release=$test_root/releases/$revision

    mkdir -p "$release/bin"
    printf '%s\n' "$revision" >"$release/revision"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$release/bin/isled"
    chmod 0755 "$release/bin/isled"
}

make_release "$first_revision"
make_release "$second_revision"
ln -s "releases/$first_revision" "$test_root/current"
ln -s "releases/$second_revision" "$test_root/previous"

status_output=$(ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" status)
expected_status=$(printf 'current\t%s\nprevious\t%s' \
    "$first_revision" "$second_revision")
[[ $status_output == "$expected_status" ]]

rollback_output=$(ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" rollback)
[[ $rollback_output == "rolled-back"$'\t'"$second_revision" ]]
[[ $(readlink -- "$test_root/current") == "releases/$second_revision" ]]
[[ $(readlink -- "$test_root/previous") == "releases/$first_revision" ]]

rm -f -- "$test_root/previous"
if ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" rollback \
    >"$test_root/unexpected-stdout" 2>"$test_root/expected-stderr"; then
    printf 'rollback unexpectedly succeeded without a previous release\n' >&2
    exit 1
fi
[[ $(readlink -- "$test_root/current") == "releases/$second_revision" ]]
grep -F 'rollback requires current and previous releases' \
    "$test_root/expected-stderr" >/dev/null

# Promotion consumes a receipt without invoking validators or builds.
if ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" promote "$first_revision" \
    >"$test_root/promotion.stdout" 2>"$test_root/promotion.stderr"; then
    printf 'promotion accepted an unvalidated candidate\n' >&2
    exit 1
fi
python3 - "$test_root" "$first_revision" <<'PYTEST'
from pathlib import Path
import hashlib, json, sys
root, revision = Path(sys.argv[1]), sys.argv[2]
folder = root / "validated" / revision
(folder / "bin").mkdir(parents=True)
source = root / "releases" / revision / "bin/isled"
(folder / "bin/isled").write_bytes(source.read_bytes())
(folder / "bin/isled").chmod(0o755)
(folder / "validation.json").write_text(json.dumps(dict(schema=1, success=True,
    revision=revision, artifact_sha256=hashlib.sha256(source.read_bytes()).hexdigest())))
PYTEST
ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" promote "$first_revision" >"$test_root/promotion.stdout"
[[ $(readlink "$test_root/current") == "releases/$first_revision" ]]
printf '# corrupt\n' >>"$test_root/validated/$first_revision/bin/isled"
if ISLED_DOGFOOD_ROOT=$test_root "$dogfood_script" promote "$first_revision" \
    >"$test_root/promotion.stdout" 2>"$test_root/promotion.stderr"; then
    printf 'promotion accepted a corrupted artifact\n' >&2
    exit 1
fi
[[ $(readlink "$test_root/current") == "releases/$first_revision" ]]
printf 'dogfood-release tests passed\n'
