#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RULES_FILE="$TMP_DIR/conflicts.json"
PREFS_FILE="$TMP_DIR/preferences.json"

cat > "$RULES_FILE" <<'JSON'
{
  "conflicts": [
    {
      "packages": ["docker.io", "podman"],
      "reason": "Both packages manage the default container runtime socket.",
      "options": ["docker.io", "podman"]
    }
  ]
}
JSON

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

set +e
OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$RULES_FILE" \
    --preferences "$PREFS_FILE" \
    docker.io podman 2>&1)"
STATUS=$?
set -e

if [[ "$STATUS" -ne 1 ]]; then
    echo "Expected conflict status 1, got $STATUS" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

assert_contains "$OUTPUT" "Package conflicts found"
assert_contains "$OUTPUT" "docker.io vs podman"
assert_contains "$OUTPUT" "keep docker.io"
assert_contains "$OUTPUT" "keep podman"

python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$RULES_FILE" \
    --preferences "$PREFS_FILE" \
    --choice podman \
    docker.io podman >/dev/null || true

SAVED="$(cat "$PREFS_FILE")"
assert_contains "$SAVED" "\"docker.io|podman\": \"podman\""

JSON_OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$RULES_FILE" \
    --preferences "$PREFS_FILE" \
    --json \
    docker.io podman || true)"
assert_contains "$JSON_OUTPUT" "\"saved_choice\": \"podman\""

python3 -c "import importlib.util, sys; spec = importlib.util.spec_from_file_location('resolver', '$ROOT_DIR/apt/scripts/resolve-conflicts.py'); mod = importlib.util.module_from_spec(spec); sys.modules['resolver'] = mod; spec.loader.exec_module(mod); assert mod.parse_relation_names('pkg-a | pkg-a-compat (>= 1), pkg-b') == {'pkg-a', 'pkg-a-compat', 'pkg-b'}"

BROKEN_OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$TMP_DIR/broken.json" \
    --preferences "$PREFS_FILE" \
    nginx curl 2>&1)"
assert_contains "$BROKEN_OUTPUT" "No package conflicts found."

printf '{broken json' > "$TMP_DIR/broken.json"
MALFORMED_OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$TMP_DIR/broken.json" \
    --preferences "$PREFS_FILE" \
    nginx curl 2>&1)"
assert_contains "$MALFORMED_OUTPUT" "Warning: could not read rules file"
assert_contains "$MALFORMED_OUTPUT" "No package conflicts found."

cat > "$TMP_DIR/bad-schema.json" <<'JSON'
{
  "conflicts": [
    42,
    {"packages": "nginx"},
    {"packages": ["nginx", "curl"], "options": "nginx"}
  ]
}
JSON
BAD_SCHEMA_OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$TMP_DIR/bad-schema.json" \
    --preferences "$PREFS_FILE" \
    nginx curl 2>&1 || true)"
assert_contains "$BAD_SCHEMA_OUTPUT" "Package conflicts found"
assert_contains "$BAD_SCHEMA_OUTPUT" "curl vs nginx"

INTERACTIVE_OUTPUT="$(printf '1\n' | python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$RULES_FILE" \
    --preferences "$PREFS_FILE" \
    --interactive \
    docker.io podman || true)"
assert_contains "$INTERACTIVE_OUTPUT" "Select option"
assert_contains "$INTERACTIVE_OUTPUT" "Saved preference: keep docker.io"

NO_CONFLICT_OUTPUT="$(python3 "$ROOT_DIR/apt/scripts/resolve-conflicts.py" \
    --rules "$RULES_FILE" \
    --preferences "$PREFS_FILE" \
    nginx curl)"
assert_contains "$NO_CONFLICT_OUTPUT" "No package conflicts found."

echo "resolve-conflicts tests passed"
