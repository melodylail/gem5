# profiling/mem/tests/tools/assert.sh
# Lightweight assertion helpers for bash integration tests.

assert_file_exists() {
    local file="$1" msg="${2:-expected file to exist: $1}"
    if [ ! -f "$file" ]; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: file exists: $file"
}

assert_file_not_empty() {
    local file="$1" msg="${2:-expected non-empty file: $1}"
    assert_file_exists "$file" "$msg"
    if [ ! -s "$file" ]; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: file not empty: $file"
}

assert_exit_code() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$actual" -ne "$expected" ]; then
        echo "FAIL: expected exit $expected, got $actual${msg:+: $msg}" >&2
        exit 1
    fi
    echo "  ok: exit code $expected"
}

assert_contains() {
    local pattern="$1" file="$2" msg="${3:-expected '$pattern' in $file}"
    if ! grep -q "$pattern" "$file"; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: contains '$pattern'"
}

assert_ge() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [ "$(echo "$actual >= $expected" | bc -l 2>/dev/null || echo 0)" != "1" ]; then
        echo "FAIL: expected >= $expected, got $actual${msg:+: $msg}" >&2
        exit 1
    fi
    echo "  ok: $actual >= $expected"
}

echo "assert.sh loaded"
