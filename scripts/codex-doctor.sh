#!/usr/bin/env bash
# codex-doctor.sh - self-check for a Codex CLI custom model provider
# (~/.codex/config.toml, [model_providers.<id>], base_url, env_key, wire_api).
#
#   bash scripts/codex-doctor.sh                 # offline checks only
#   bash scripts/codex-doctor.sh --profile work  # base config + ~/.codex/work.config.toml
#   bash scripts/codex-doctor.sh --live          # also GET /models and a streamed POST /responses
#
# Runs on the bash 3.2 that ships with macOS. Uses python3 + tomllib (or tomli)
# to parse TOML when available and falls back to a line parser (awk) otherwise.
# Nothing is sent over the network unless you pass --live.
#
# Key handling: the API key is read only from the environment variable named by
# env_key. Only its length is printed. With --live the key reaches curl through
# stdin (curl -K -), so it does not appear in the process list, and every line
# printed from a response is scrubbed of the key.
#
# Exit status: the number of FAIL rows (0 = nothing failed). 64 = bad usage.
#
# Part of codex-custom-provider. MIT License.

set -u
set +x

DOCTOR_VERSION="2.0.0"
RESERVED_IDS="openai ollama lmstudio"
BUILTIN_IDS="openai ollama lmstudio amazon-bedrock amazon-bedrock-runtime"
# Top-level-only keys that commonly end up under a [table] by mistake.
TOPLEVEL_KEYS="model model_provider model_reasoning_effort model_reasoning_summary model_verbosity model_context_window approval_policy sandbox_mode openai_base_url profile"
# Fields of [model_providers.<id>] (codex-rs/model-provider-info, ModelProviderInfo).
PROVIDER_KEYS="name base_url model_catalog_url env_key env_key_instructions experimental_bearer_token auth gateway_oauth aws wire_api query_params http_headers env_http_headers request_max_retries stream_max_retries stream_idle_timeout_ms websocket_connect_timeout_ms requires_openai_auth supports_websockets supports_standalone_web_search"
# Keys Codex ignores in a project-local .codex/config.toml (provider/profile related).
PROJECT_IGNORED="model_provider model_providers openai_base_url chatgpt_base_url profile profiles"

usage() {
  cat <<'EOF'
Usage: codex-doctor.sh [options]

Checks a Codex CLI custom provider setup and prints a PASS/WARN/FAIL table.

Options:
  --config FILE    check this file instead of $CODEX_HOME/config.toml or ~/.codex/config.toml
  --profile NAME   also load <config dir>/NAME.config.toml on top (like `codex --profile NAME`)
  --project DIR    where to look for project-level .codex/config.toml (default: current dir)
  --live           send GET <base_url>/models and one small streamed POST <base_url>/responses
                   (the POST is a real, billed request)
  --model ID       model for --live (default: `model` from the config)
  --no-color       plain output (also honoured: NO_COLOR=1)
  -h, --help       show this help

Environment:
  CODEX_HOME               Codex home directory (default ~/.codex)
  CODEX_DOCTOR_TIMEOUT     seconds per --live request (default 60)
  CODEX_DOCTOR_PYTHON      python interpreter to use for TOML parsing (default: python3)
  CODEX_DOCTOR_PARSER      auto | python | fallback  (default auto)
  CODEX_DOCTOR_CODEX_BIN   codex executable to query for its version (default: codex)

Exit status: number of FAIL rows; 64 on bad usage.
EOF
}

usage_error() { printf 'codex-doctor: %s\nTry --help.\n' "$1" >&2; exit 64; }

CONFIG_ARG=""
PROFILE=""
PROJECT_DIR=""
LIVE=0
MODEL_ARG=""
COLOR="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || usage_error "--config needs a file"; CONFIG_ARG="$2"; shift 2 ;;
    --config=*) CONFIG_ARG="${1#*=}"; shift ;;
    --profile) [ $# -ge 2 ] || usage_error "--profile needs a name"; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --project) [ $# -ge 2 ] || usage_error "--project needs a directory"; PROJECT_DIR="$2"; shift 2 ;;
    --project=*) PROJECT_DIR="${1#*=}"; shift ;;
    --live) LIVE=1; shift ;;
    --model) [ $# -ge 2 ] || usage_error "--model needs an ID"; MODEL_ARG="$2"; shift 2 ;;
    --model=*) MODEL_ARG="${1#*=}"; shift ;;
    --no-color) COLOR="never"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

if [ -n "$PROFILE" ]; then
  case "$PROFILE" in
    *[!A-Za-z0-9_-]*) usage_error "profile names may only contain letters, digits, - and _" ;;
  esac
fi

TIMEOUT="${CODEX_DOCTOR_TIMEOUT:-60}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=60 ;; esac
PARSER_PREF="${CODEX_DOCTOR_PARSER:-auto}"
CODEX_BIN="${CODEX_DOCTOR_CODEX_BIN:-codex}"

if [ "$COLOR" = "auto" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_PASS=$(printf '\033[32m'); C_WARN=$(printf '\033[33m'); C_FAIL=$(printf '\033[31m')
  C_SKIP=$(printf '\033[90m'); C_OFF=$(printf '\033[0m')
else
  C_PASS=""; C_WARN=""; C_FAIL=""; C_SKIP=""; C_OFF=""
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t codexdoctor)"
chmod 700 "$TMP" 2>/dev/null
trap 'rm -rf "$TMP"' EXIT
FACTS="$TMP/facts.tsv"
: > "$FACTS"

SECRET=""
host=""
MODEL=""
N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0

redact() {
  local s="$1"
  if [ -n "$SECRET" ]; then s="${s//"$SECRET"/[REDACTED]}"; fi
  printf '%s' "$s"
}

one_line() { # squeeze to one short line: one_line TEXT [MAXLEN]
  printf '%s' "$1" | tr '\r\n\t' '   ' | cut -c1-"${2:-220}"
}

add() { # add ID STATUS CHECK DETAIL [HINT]
  local id="$1" st="$2" name="$3" detail hint color
  detail="$(redact "$4")"
  hint="$(redact "${5:-}")"
  case "$st" in
    PASS) N_PASS=$((N_PASS + 1)); color="$C_PASS" ;;
    WARN) N_WARN=$((N_WARN + 1)); color="$C_WARN" ;;
    FAIL) N_FAIL=$((N_FAIL + 1)); color="$C_FAIL" ;;
    *)    N_SKIP=$((N_SKIP + 1)); color="$C_SKIP" ;;
  esac
  printf ' %-4s %s%-4s%s  %-16s %s\n' "$id" "$color" "$st" "$C_OFF" "$name" "$detail"
  if [ -n "$hint" ]; then printf '                             fix: %s\n' "$hint"; fi
}

in_list() { # in_list WORD "LIST OF WORDS"
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

abs_path() { # absolute, symlink-resolved path of an existing file (empty if missing)
  local d b
  [ -e "$1" ] || return 1
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename "$1")"
  printf '%s/%s' "$d" "$b"
}

fact() { # fact KEY -> last value recorded for KEY; status 1 if absent
  awk -F '\t' -v k="$1" '$1 == k { v = $2; f = 1 } END { if (f) { print v; exit 0 } exit 1 }' "$FACTS"
}

has_fact() { fact "$1" >/dev/null; }

# --------------------------------------------------------------------------
# TOML helpers
# --------------------------------------------------------------------------

BOM="$(printf '\357\273\277')"

# Line scanner used for key order checks (always) and as the fallback parser.
# Output records (tab separated):
#   H  line  table                 a [table] header
#   L  line  table  key            a key assignment inside `table` ("" = top level)
#   F  path  value                 a fact (same format as the python dumper)
scan_toml() {
  LC_ALL=C awk -v bom="$BOM" \
    -v safe_top="model model_provider profile openai_base_url chatgpt_base_url model_reasoning_effort" \
    -v safe_prov="name base_url wire_api env_key requires_openai_auth stream_idle_timeout_ms stream_max_retries request_max_retries supports_websockets" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function norm_key(k,    n, i, parts, out, seg, q1, q2) {
  n = split(k, parts, ".")
  out = ""
  for (i = 1; i <= n; i++) {
    seg = trim(parts[i])
    q1 = substr(seg, 1, 1); q2 = substr(seg, length(seg), 1)
    if (length(seg) >= 2 && q1 == q2 && (q1 == "\"" || q1 == "\047")) seg = substr(seg, 2, length(seg) - 2)
    out = (i == 1) ? seg : out "." seg
  }
  return out
}
function lower(s) { return tolower(s) }
# Index of the first "=" that is not inside a quoted key.
function eq_pos(s,    i, c, q) {
  q = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; continue }
    if (c == "\"" || c == "\047") { q = c; continue }
    if (c == "=") return i
  }
  return 0
}
# Parse a basic string starting at s[1] == "\"" ; returns contents (escapes simplified).
function basic_str(s,    i, c, out) {
  out = ""; unterminated = 1
  for (i = 2; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; c = substr(s, i, 1); if (c == "t") c = " "; else if (c == "n") c = " "; out = out c; continue }
    if (c == "\"") { unterminated = 0; return out }
    out = out c
  }
  return out
}
# Bracket depth change of an array value, ignoring brackets inside strings.
function bracket_delta(s,    i, c, q, d) {
  q = ""; d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == "\\" && q == "\"") { i++; continue } if (c == q) q = ""; continue }
    if (c == "#") break
    if (c == "\"" || c == "\047") { q = c; continue }
    if (c == "[") d++
    else if (c == "]") d--
  }
  return d
}
function emit(path, val,    n, parts, pk, pid) {
  n = split(path, parts, ".")
  if (parts[1] == "model_providers") {
    print "F\tmodel_providers\t<table>"
    if (n >= 2) print "F\tmodel_providers." parts[2] "\t<table>"
    if (n == 3) {
      pk = parts[3]; pid = parts[2]
      if (index(" " safe_prov " ", " " pk " ") > 0 && val !~ /^<(array|table|multiline)>$/) {
        if (pk == "env_key" && val !~ /^[A-Za-z_][A-Za-z0-9_]*$/) val = "<invalid-name:" length(val) ">"
        print "F\t" path "\t" val
      } else if (pk == "http_headers") {
        print "F\t" path "\t<table>"
        if (lower(rawval) ~ /authorization/) print "F\tmodel_providers." pid ".http_headers.authorization\t<set>"
      } else if (val == "<table>") {
        print "F\t" path "\t<table>"
      } else {
        print "F\t" path "\t<set>"
      }
    } else if (n == 4 && parts[3] == "http_headers") {
      print "F\tmodel_providers." parts[2] ".http_headers." lower(parts[4]) "\t<set>"
    } else if (n > 3) {
      print "F\tmodel_providers." parts[2] "." parts[3] "\t<table>"
    }
    return
  }
  if (parts[1] == "profiles") {
    print "F\tprofiles\t<table>"
    if (n >= 2) print "F\tprofiles." parts[2] "\t<table>"
    return
  }
  if (n == 1) {
    if (index(" " safe_top " ", " " path " ") > 0 && val !~ /^<(array|table|multiline)>$/) print "F\t" path "\t" val
    else if (val == "<table>") print "F\t" path "\t<table>"
    else print "F\t" path "\t<set>"
  } else {
    print "F\t" parts[1] "\t<table>"
  }
}
BEGIN { table = ""; ktable = ""; ml = ""; depth = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  if (NR == 1 && substr(line, 1, 3) == bom) line = substr(line, 4)

  if (ml != "") { if (index(line, ml) > 0) ml = ""; next }
  if (depth > 0) { depth += bracket_delta(line); if (depth < 0) depth = 0; next }

  s = trim(line)
  if (s == "" || substr(s, 1, 1) == "#") next

  if (substr(s, 1, 1) == "[") {
    if (s !~ /\][ \t]*(#.*)?$/) { print "E\t" NR "\tunterminated table header"; next }
    h = s
    aot = (substr(h, 1, 2) == "[[")
    sub(/^\[\[?/, "", h)
    sub(/\]\]?[ \t]*(#.*)?$/, "", h)
    table = norm_key(h)
    rawval = ""
    print "H\t" NR "\t" table
    if (!aot && hdr[table]++) print "E\t" NR "\tduplicate table [" table "]"
    ktable = aot ? table SUBSEP NR : table
    if (!aot) emit(table, "<table>")
    next
  }

  p = eq_pos(s)
  if (p == 0) { print "E\t" NR "\texpected key = value"; next }
  key = norm_key(substr(s, 1, p - 1))
  if (seenkey[ktable SUBSEP key]++) print "E\t" NR "\tduplicate key " key (table == "" ? "" : " in [" table "]")
  v = trim(substr(s, p + 1))
  rawval = v
  print "L\t" NR "\t" table "\t" key

  if (substr(v, 1, 3) == "\"\"\"" || substr(v, 1, 3) == "\047\047\047") {
    delim = substr(v, 1, 3)
    rest = substr(v, 4)
    if (index(rest, delim) > 0) val = substr(rest, 1, index(rest, delim) - 1)
    else { ml = delim; val = "<multiline>" }
  } else if (substr(v, 1, 1) == "\"") {
    val = basic_str(v)
    if (unterminated) print "E\t" NR "\tunterminated string"
  } else if (substr(v, 1, 1) == "\047") {
    val = substr(v, 2)
    if (index(val, "\047") > 0) val = substr(val, 1, index(val, "\047") - 1)
    else print "E\t" NR "\tunterminated string"
  } else if (substr(v, 1, 1) == "[") {
    depth = bracket_delta(v); if (depth < 0) depth = 0
    val = "<array>"
  } else if (substr(v, 1, 1) == "{") {
    val = "<table>"
  } else {
    sub(/[ \t]*#.*$/, "", v)
    val = trim(v)
  }
  path = (table == "") ? key : table "." key
  emit(path, val)
}
' "$1"
}

PYTHON=""
PY_LABEL=""
find_python() {
  local cand
  for cand in ${CODEX_DOCTOR_PYTHON:-} python3 python; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys
try:
    import tomllib
except ImportError:
    import tomli
sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      PYTHON="$cand"
      PY_LABEL="$("$cand" -c 'import sys
try:
    import tomllib; m = "tomllib"
except ImportError:
    m = "tomli"
print("%s, Python %d.%d" % (m, sys.version_info[0], sys.version_info[1]))' 2>/dev/null)"
      return 0
    fi
  done
  return 1
}

# Writes facts for FILE to stdout. Exit 3 + "__error__<TAB>message" on a TOML syntax error.
py_dump() {
  "$PYTHON" - "$1" <<'PY'
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11 with the tomli backport installed
    import tomli as tomllib

SAFE_TOP = {"model", "model_provider", "profile", "openai_base_url", "chatgpt_base_url", "model_reasoning_effort"}
SAFE_PROV = {"name", "base_url", "wire_api", "env_key", "requires_openai_auth", "stream_idle_timeout_ms",
             "stream_max_retries", "request_max_retries", "supports_websockets"}
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def clean(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return v.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    if isinstance(v, list):
        return "<array>"
    if isinstance(v, dict):
        return "<table>"
    return "<set>"


def out(k, v):
    sys.stdout.write("%s\t%s\n" % (k, v))


try:
    with open(sys.argv[1], "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    data = tomllib.loads(raw.decode("utf-8"))
except Exception as exc:  # TOMLDecodeError, UnicodeDecodeError, OSError
    out("__error__", str(exc).replace("\n", " "))
    sys.exit(3)

for key, value in data.items():
    if key == "model_providers" and isinstance(value, dict):
        out("model_providers", "<table>")
        for pid, prov in value.items():
            out("model_providers." + pid, "<table>")
            if not isinstance(prov, dict):
                continue
            for pk, pv in prov.items():
                path = "model_providers.%s.%s" % (pid, pk)
                if pk in SAFE_PROV and not isinstance(pv, (dict, list)):
                    val = clean(pv)
                    if pk == "env_key" and not NAME_RE.match(val):
                        val = "<invalid-name:%d>" % len(val)
                    out(path, val)
                elif pk == "http_headers" and isinstance(pv, dict):
                    out(path, "<table>")
                    for hk in pv:
                        out("%s.%s" % (path, str(hk).lower()), "<set>")
                elif isinstance(pv, dict):
                    out(path, "<table>")
                else:
                    out(path, "<set>")
    elif key == "profiles" and isinstance(value, dict):
        out("profiles", "<table>")
        for name in value:
            out("profiles." + name, "<table>")
    elif isinstance(value, dict):
        out(key, "<table>")
    elif key in SAFE_TOP and not isinstance(value, list):
        out(key, clean(value))
    else:
        out(key, "<set>")
PY
}

version_ge() { # version_ge A B  -> true if A >= B (dotted numeric)
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$2
EOF
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}; b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -ge "$b3" ]
}

# --------------------------------------------------------------------------
# Header
# --------------------------------------------------------------------------

USE_PYTHON=0
case "$PARSER_PREF" in
  fallback) USE_PYTHON=0 ;;
  python) find_python && USE_PYTHON=1 ;;
  *) find_python && USE_PYTHON=1 ;;
esac

printf 'codex-doctor %s (bash %s)\n' "$DOCTOR_VERSION" "${BASH_VERSION%%(*}"

# --------------------------------------------------------------------------
# 1. codex CLI
# --------------------------------------------------------------------------
if command -v "$CODEX_BIN" >/dev/null 2>&1; then
  ver_line="$("$CODEX_BIN" --version 2>/dev/null | head -n 1)"
  ver="$(printf '%s' "$ver_line" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
  if [ -z "$ver" ]; then
    add 1 WARN "codex CLI" "found $(command -v "$CODEX_BIN") but could not read a version from: $(one_line "$ver_line" 80)"
  elif version_ge "$ver" "0.134.0"; then
    add 1 PASS "codex CLI" "$(one_line "$ver_line" 80)"
  else
    add 1 WARN "codex CLI" "$ver is older than 0.134.0: profile files (<name>.config.toml) and some checks here assume a newer Codex" \
      "update Codex (curl -fsSL https://chatgpt.com/codex/install.sh | sh, or npm install -g @openai/codex)"
  fi
else
  add 1 WARN "codex CLI" "'$CODEX_BIN' not found in PATH; the config can still be checked" \
    "install: curl -fsSL https://chatgpt.com/codex/install.sh | sh  (or npm install -g @openai/codex)"
fi

# --------------------------------------------------------------------------
# 2. config file
# --------------------------------------------------------------------------
CONFIG=""
PROFILE_FILE=""
CONFIG_OK=0
if [ -n "$CONFIG_ARG" ]; then
  CONFIG="$CONFIG_ARG"; CONFIG_FROM="--config"
elif [ -n "${CODEX_HOME:-}" ]; then
  CONFIG_FROM="\$CODEX_HOME"
  if [ -d "$CODEX_HOME" ]; then CONFIG="$CODEX_HOME/config.toml"; else CONFIG=""; fi
else
  CONFIG="${HOME:-}/.codex/config.toml"; CONFIG_FROM="default"
fi

if [ -n "${CODEX_HOME:-}" ] && [ -z "$CONFIG_ARG" ] && [ ! -d "$CODEX_HOME" ]; then
  add 2 FAIL "config file" "CODEX_HOME points to \"$CODEX_HOME\", but that path does not exist or is not a directory" \
    "create the directory or unset CODEX_HOME (Codex refuses to start in this state)"
elif [ ! -f "$CONFIG" ]; then
  if [ -f "$CONFIG.txt" ]; then
    add 2 FAIL "config file" "$CONFIG not found, but $CONFIG.txt exists" \
      "rename it to config.toml (Windows Explorer hides the .txt extension)"
  else
    add 2 FAIL "config file" "$CONFIG not found ($CONFIG_FROM)" \
      "create it from config/config.toml.example; provider settings only work in the user-level file"
  fi
elif [ ! -r "$CONFIG" ]; then
  add 2 FAIL "config file" "$CONFIG is not readable"
else
  CONFIG_OK=1
  if [ -n "$PROFILE" ]; then
    PROFILE_FILE="$(dirname "$CONFIG")/$PROFILE.config.toml"
    if [ -f "$PROFILE_FILE" ]; then
      add 2 PASS "config file" "$CONFIG + profile $PROFILE_FILE"
    else
      add 2 FAIL "config file" "profile file $PROFILE_FILE not found (needed for --profile $PROFILE)" \
        "Codex 0.134+ reads profiles from <CODEX_HOME>/<name>.config.toml, not from [profiles.<name>]"
      PROFILE_FILE=""
      CONFIG_OK=0
    fi
  else
    add 2 PASS "config file" "$CONFIG ($CONFIG_FROM)"
  fi
fi

# --------------------------------------------------------------------------
# 3. TOML parse
# --------------------------------------------------------------------------
PARSE_OK=0
SCAN_BASE="$TMP/scan-base.tsv"
SCAN_PROFILE="$TMP/scan-profile.tsv"
: > "$SCAN_BASE"; : > "$SCAN_PROFILE"
if [ "$CONFIG_OK" -ne 1 ]; then
  add 3 SKIP "TOML parse" "no config file to parse"
elif [ "$PARSER_PREF" = "python" ] && [ "$USE_PYTHON" -ne 1 ]; then
  add 3 FAIL "TOML parse" "CODEX_DOCTOR_PARSER=python but no Python with tomllib/tomli was found"
else
  scan_toml "$CONFIG" > "$SCAN_BASE"
  [ -n "$PROFILE_FILE" ] && scan_toml "$PROFILE_FILE" > "$SCAN_PROFILE"
  if [ "$USE_PYTHON" -eq 1 ]; then
    perr=""
    dump_one() { # dump_one FILE -> appends facts, sets perr on error
      if ! py_dump "$1" > "$TMP/py.tsv" 2>"$TMP/py.err"; then
        msg="$(awk -F '\t' '$1 == "__error__" { print $2 }' "$TMP/py.tsv")"
        [ -n "$msg" ] || msg="$(one_line "$(cat "$TMP/py.err")")"
        perr="$1: $msg"
        return 1
      fi
      cat "$TMP/py.tsv" >> "$FACTS"
    }
    if dump_one "$CONFIG" && [ -n "$PROFILE_FILE" ]; then dump_one "$PROFILE_FILE"; fi
    if [ -n "$perr" ]; then
      add 3 FAIL "TOML parse" "$(one_line "$perr" 240)" "fix the TOML syntax at the reported line (Codex will not start)"
    else
      PARSE_OK=1
      add 3 PASS "TOML parse" "valid TOML ($PY_LABEL)"
    fi
  else
    ferr="$(awk -F '\t' -v f="$CONFIG" '$1 == "E" { print f ": line " $2 ": " $3; exit }' "$SCAN_BASE")"
    if [ -z "$ferr" ] && [ -n "$PROFILE_FILE" ]; then
      ferr="$(awk -F '\t' -v f="$PROFILE_FILE" '$1 == "E" { print f ": line " $2 ": " $3; exit }' "$SCAN_PROFILE")"
    fi
    if [ -n "$ferr" ]; then
      add 3 FAIL "TOML parse" "$(one_line "$ferr" 240)" "fix the TOML syntax at the reported line (Codex will not start)"
    else
      awk -F '\t' '$1 == "F" { print $2 "\t" $3 }' "$SCAN_BASE" >> "$FACTS"
      [ -n "$PROFILE_FILE" ] && awk -F '\t' '$1 == "F" { print $2 "\t" $3 }' "$SCAN_PROFILE" >> "$FACTS"
      PARSE_OK=1
      add 3 PASS "TOML parse" "read with the fallback line parser (basic syntax checks only; Python 3.11+ enables strict parsing)"
    fi
  fi
fi

# --------------------------------------------------------------------------
# 4. key order: top-level keys must come before the first [table]
# --------------------------------------------------------------------------
misplaced_in() { # misplaced_in SCANFILE LABEL
  awk -F '\t' -v tops="$TOPLEVEL_KEYS" -v label="$2" '
    BEGIN { n = split(tops, a, " "); for (i = 1; i <= n; i++) top[a[i]] = 1 }
    $1 == "L" {
      t = $3; k = $4
      if (t == "" || t ~ /^profiles(\.|$)/) next
      if (k == "model_provider" || (t ~ /^model_providers\.[^.]+$/ && (k in top)))
        printf "%s:%s %s is inside [%s]; ", label, $2, k, t
    }' "$1"
}
if [ "$PARSE_OK" -ne 1 ]; then
  add 4 SKIP "key order" "config was not parsed"
else
  mis="$(misplaced_in "$SCAN_BASE" "$(basename "$CONFIG")")"
  [ -n "$PROFILE_FILE" ] && mis="$mis$(misplaced_in "$SCAN_PROFILE" "$(basename "$PROFILE_FILE")")"
  if [ -n "$mis" ]; then
    add 4 FAIL "key order" "$(one_line "${mis%; }" 240)" \
      "move model / model_provider above the first [table]; in TOML every key after [x] belongs to x"
  else
    first_tbl="$(awk -F '\t' '$1 == "H" { print $2; exit }' "$SCAN_BASE")"
    add 4 PASS "key order" "top-level keys come before the first table${first_tbl:+ (line $first_tbl)}"
  fi
fi

# --------------------------------------------------------------------------
# 5. model + model_provider
# --------------------------------------------------------------------------
PID=""
CUSTOM=0
if [ "$PARSE_OK" -ne 1 ]; then
  add 5 SKIP "model_provider" "config was not parsed"
else
  reserved_tables=""
  for rid in $RESERVED_IDS; do
    has_fact "model_providers.$rid" && reserved_tables="$reserved_tables \`$rid\`"
  done
  PID="$(fact model_provider)"
  MODEL="$(fact model)"
  if [ -n "$reserved_tables" ]; then
    add 5 FAIL "model_provider" "model_providers contains reserved built-in provider IDs:$reserved_tables. Built-in providers cannot be overridden." \
      "rename the table and model_provider to your own ID, e.g. [model_providers.my-gateway]"
  elif [ -z "$PID" ]; then
    obu="$(fact openai_base_url)"
    if [ -n "$obu" ]; then
      add 5 WARN "model_provider" "not set; using the built-in openai provider with openai_base_url = $obu (checks 6-9 cover custom providers only)"
    else
      add 5 FAIL "model_provider" "not set at the top level, so Codex uses the built-in \`openai\` provider" \
        "add model_provider = \"<id>\" above the first [table]"
    fi
  elif [ "$PID" = "ollama-chat" ]; then
    add 5 FAIL "model_provider" "\`ollama-chat\` is no longer supported" "replace \`ollama-chat\` with \`ollama\`"
  elif in_list "$PID" "$BUILTIN_IDS"; then
    add 5 WARN "model_provider" "\`$PID\` is a built-in provider, not a custom one (checks 6-9 cover custom providers only)"
  elif [ -z "$MODEL" ] && [ -z "$MODEL_ARG" ]; then
    CUSTOM=1
    add 5 WARN "model_provider" "model_provider = $PID, but \`model\` is not set: Codex will ask the gateway for its own default model ID" \
      "set model = \"<an ID from GET <base_url>/models>\""
  else
    CUSTOM=1
    add 5 PASS "model_provider" "model_provider = $PID, model = ${MODEL:-$MODEL_ARG}"
  fi
fi

# --------------------------------------------------------------------------
# 6. [model_providers.<id>] table
# --------------------------------------------------------------------------
unknown_keys() { # unknown_keys SCANFILE PID
  awk -F '\t' -v pid="$2" -v keys="$PROVIDER_KEYS" -v tops="$TOPLEVEL_KEYS" '
    BEGIN { n = split(keys, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1
            n = split(tops, b, " "); for (i = 1; i <= n; i++) top[b[i]] = 1 }
    $1 == "L" && $3 == "model_providers." pid {
      split($4, seg, "."); k = seg[1]
      if (!(k in ok) && !(k in top)) printf "%s ", k
    }' "$1"
}
if [ "$CUSTOM" -ne 1 ]; then
  add 6 SKIP "provider table" "no custom model_provider selected"
elif ! has_fact "model_providers.$PID"; then
  add 6 FAIL "provider table" "Model provider \`$PID\` not found: there is no [model_providers.$PID] table" \
    "model_provider must match the table name exactly: model_provider = \"$PID\" <-> [model_providers.$PID]"
else
  pname="$(fact "model_providers.$PID.name")"
  unk="$(unknown_keys "$SCAN_BASE" "$PID")$( [ -n "$PROFILE_FILE" ] && unknown_keys "$SCAN_PROFILE" "$PID")"
  unk="$(printf '%s' "$unk" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  unk="${unk% }"
  if [ -z "$pname" ] || [ -z "$(printf '%s' "$pname" | tr -d ' \t')" ]; then
    add 6 FAIL "provider table" "model_providers.$PID: provider name must not be empty" "add name = \"<display name>\""
  elif [ -n "$unk" ]; then
    hint="Codex ignores unknown provider keys"
    case " $unk " in *" api_key "*|*" key "*|*" token "*|*" api-key "*) hint="Codex has no api_key field: delete it (it is a plaintext secret) and use env_key = \"<ENV_VAR_NAME>\"" ;; esac
    add 6 WARN "provider table" "[model_providers.$PID] has keys Codex does not know: $unk" "$hint"
  else
    add 6 PASS "provider table" "[model_providers.$PID] name = \"$pname\""
  fi
fi

# --------------------------------------------------------------------------
# 7. base_url
# --------------------------------------------------------------------------
BASE=""
if [ "$CUSTOM" -ne 1 ] || ! has_fact "model_providers.$PID"; then
  add 7 SKIP "base_url" "no custom provider table to check"
else
  BASE="$(fact "model_providers.$PID.base_url")"
  b="$BASE"
  while [ "${b%/}" != "$b" ]; do b="${b%/}"; done
  lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  host="$(printf '%s' "$lb" | sed -n 's#^[a-z][a-z]*://\([^/:?]*\).*#\1#p')"
  if [ -z "$BASE" ]; then
    add 7 FAIL "base_url" "missing: Codex would send this provider's requests to https://api.openai.com/v1" \
      "base_url = \"https://<your-gateway>/v1\""
  else
    case "$lb" in
      *[[:space:]]*)
        add 7 FAIL "base_url" "\"$BASE\" contains whitespace" ;;
      http://*|https://*)
        case "$lb" in
          *\?*)
            add 7 FAIL "base_url" "\"$BASE\" contains a query string; Codex appends /responses after it" \
              "move query parameters to query_params = { key = \"value\" }" ;;
          */v1/v1|*/v1/v1/*)
            add 7 FAIL "base_url" "\"$BASE\" repeats /v1; requests would go to $b/responses" \
              "keep exactly one /v1 at the end" ;;
          */responses|*/completions)
            add 7 FAIL "base_url" "\"$BASE\" already ends with an endpoint; Codex appends /responses itself -> $b/responses" \
              "cut base_url back to the API root, usually .../v1" ;;
          */v1)
            if [ "${lb#http://}" != "$lb" ] && ! in_list "$host" "localhost 127.0.0.1 [::1] ::1 ["; then
              add 7 WARN "base_url" "plain http to $host: the API key travels unencrypted (requests go to $b/responses)" \
                "use https:// unless this is a trusted local network"
            else
              add 7 PASS "base_url" "requests go to $b/responses"
            fi ;;
          *)
            add 7 WARN "base_url" "does not end with /v1; Codex will call $b/responses" \
              "most OpenAI-compatible gateways expect https://<host>/v1 - check your gateway's docs" ;;
        esac ;;
      *)
        add 7 FAIL "base_url" "\"$BASE\" must start with http:// or https://" ;;
    esac
  fi
fi

# --------------------------------------------------------------------------
# 8. wire_api
# --------------------------------------------------------------------------
if [ "$CUSTOM" -ne 1 ] || ! has_fact "model_providers.$PID"; then
  add 8 SKIP "wire_api" "no custom provider table to check"
else
  wa="$(fact "model_providers.$PID.wire_api")"
  if ! has_fact "model_providers.$PID.wire_api"; then
    add 8 PASS "wire_api" "not set (defaults to \"responses\")"
  elif [ "$wa" = "responses" ]; then
    add 8 PASS "wire_api" "\"responses\" (the gateway must implement POST /v1/responses)"
  elif [ "$wa" = "chat" ]; then
    add 8 FAIL "wire_api" "\`wire_api = \"chat\"\` is no longer supported" \
      "set wire_api = \"responses\"; a gateway that only has /chat/completions cannot serve Codex"
  else
    add 8 FAIL "wire_api" "unknown variant \`$wa\`, expected \`responses\`" "set wire_api = \"responses\""
  fi
fi

# --------------------------------------------------------------------------
# 9. credentials
# --------------------------------------------------------------------------
if [ "$CUSTOM" -ne 1 ] || ! has_fact "model_providers.$PID"; then
  add 9 SKIP "credentials" "no custom provider table to check"
else
  EK="$(fact "model_providers.$PID.env_key")"
  has_auth=0; has_fact "model_providers.$PID.auth" && has_auth=1
  if has_fact "model_providers.$PID.env_key" && [ "$has_auth" -eq 1 ]; then
    add 9 FAIL "credentials" "provider auth cannot be combined with env_key" "keep either env_key or [model_providers.$PID.auth]"
  elif has_fact "model_providers.$PID.env_key"; then
    case "$EK" in
      "<invalid-name:"*)
        len="${EK#<invalid-name:}"; len="${len%>}"
        add 9 FAIL "credentials" "env_key is not a valid environment variable name (value hidden, length $len) - is the key itself pasted there?" \
          "env_key must be the NAME of a variable, e.g. env_key = \"MY_GATEWAY_API_KEY\"; put the key in that variable" ;;
      *)
        ek_set=""; ek_val=""
        eval "ek_set=\${$EK+x}"
        eval "ek_val=\${$EK-}"
        ek_trim="$(printf '%s' "$ek_val" | tr -d ' \t\r\n')"
        if [ -z "$ek_set" ] || [ -z "$ek_trim" ]; then
          add 9 FAIL "credentials" "Missing environment variable: \`$EK\`." \
            "export $EK=... in the shell (or IDE) that starts Codex; see docs/macos-linux.md or docs/windows.md"
        else
          SECRET="$ek_val"
          klen=${#ek_val}
          case "$ek_val" in
            \"*|*\"|\'*|*\')
              add 9 WARN "credentials" "\$$EK is set (length $klen) but starts or ends with a quote character" \
                "remove the extra quotes around the key" ;;
            *[[:space:]]*)
              add 9 WARN "credentials" "\$$EK is set (length $klen) but contains whitespace" \
                "re-copy the key without spaces or line breaks" ;;
            *)
              add 9 PASS "credentials" "\$$EK is set (length $klen)" ;;
          esac
        fi ;;
    esac
  elif [ "$has_auth" -eq 1 ]; then
    add 9 PASS "credentials" "command-backed token ([model_providers.$PID.auth])"
  elif has_fact "model_providers.$PID.experimental_bearer_token"; then
    add 9 WARN "credentials" "experimental_bearer_token stores the key in the config file" \
      "prefer env_key = \"<ENV_VAR_NAME>\" (the official docs discourage experimental_bearer_token)"
  elif [ "$(fact "model_providers.$PID.requires_openai_auth")" = "true" ]; then
    add 9 WARN "credentials" "requires_openai_auth = true: the key comes from Codex login (auth.json / keyring), not from env_key" \
      "for a third-party gateway prefer env_key; see docs/errors.md#401"
  elif has_fact "model_providers.$PID.http_headers.authorization"; then
    add 9 WARN "credentials" "an Authorization header is hard-coded in http_headers (plaintext key in the config)" \
      "use env_key, or env_http_headers to read the header from a variable"
  else
    case "$host" in
      localhost|127.0.0.1|::1|\[::1\]|\[)
        add 9 WARN "credentials" "no env_key / auth configured (fine for an unauthenticated local server)" ;;
      *)
        add 9 FAIL "credentials" "no API key configured for [model_providers.$PID]" \
          "add env_key = \"<ENV_VAR_NAME>\" and export that variable" ;;
    esac
  fi
fi

# --------------------------------------------------------------------------
# 10. keys Codex ignores or rejects: project-level provider keys, legacy profiles
# --------------------------------------------------------------------------
project_keys() { # project_keys FILE -> provider-related keys found in a project config
  scan_toml "$1" | awk -F '\t' -v ign="$PROJECT_IGNORED" '
    BEGIN { n = split(ign, a, " "); for (i = 1; i <= n; i++) bad[a[i]] = 1 }
    $1 == "L" {
      t = $3; k = $4
      split((t == "" ? k : t), seg, ".")
      root = seg[1]
      if (t == "" && (k in bad)) { if (!seen[k]++) printf "%s ", k }
      else if (root in bad) { if (!seen[root]++) printf "%s ", root }
    }'
}
ten_status="PASS"; ten_detail=""; ten_hint=""
note10() { # note10 STATUS TEXT HINT
  if [ "$1" = "FAIL" ] || { [ "$1" = "WARN" ] && [ "$ten_status" = "PASS" ]; }; then ten_status="$1"; fi
  ten_detail="${ten_detail:+$ten_detail; }$2"
  [ -n "$3" ] && ten_hint="${ten_hint:+$ten_hint; }$3"
}
if [ "$PARSE_OK" -eq 1 ]; then
  lp="$(awk -F '\t' '$1 == "F" && $2 == "profile" { v = $3 } END { print v }' "$SCAN_BASE")"
  if [ -n "$lp" ]; then
    note10 FAIL "legacy \`profile = \"$lp\"\` config is no longer supported" \
      "delete it and run codex --profile $lp with $lp.config.toml"
  fi
  legacy_names="$(awk -F '\t' '$1 == "F" && $2 ~ /^profiles\./ { sub(/^profiles\./, "", $2); if (!s[$2]++) printf "%s ", $2 }' "$SCAN_BASE")"
  legacy_names="${legacy_names% }"
  if [ -n "$legacy_names" ]; then
    if [ -n "$PROFILE" ] && in_list "$PROFILE" "$legacy_names"; then
      note10 FAIL "--profile $PROFILE cannot be used while config.toml contains [profiles.$PROFILE]" \
        "move that table's keys into $PROFILE.config.toml as top-level keys and delete [profiles.$PROFILE]"
    else
      note10 WARN "legacy [profiles.*] tables are ignored by Codex 0.134+: $legacy_names" \
        "move each into <CODEX_HOME>/<name>.config.toml (see config/profiles/)"
    fi
  fi
fi
start_dir="${PROJECT_DIR:-$PWD}"
cfg_abs="$( [ -f "$CONFIG" ] && abs_path "$CONFIG" )"
prof_abs="$( [ -n "$PROFILE_FILE" ] && abs_path "$PROFILE_FILE" )"
d="$(cd "$start_dir" 2>/dev/null && pwd -P)"
while [ -n "$d" ]; do
  pf="$d/.codex/config.toml"
  if [ -f "$pf" ]; then
    pf_abs="$(abs_path "$pf")"
    if [ "$pf_abs" != "$cfg_abs" ] && [ "$pf_abs" != "$prof_abs" ]; then
      pk="$(project_keys "$pf")"; pk="${pk% }"
      if [ -n "$pk" ]; then
        note10 WARN "project config $pf sets $pk - Codex ignores these there" \
          "move provider settings to the user-level config ($CONFIG)"
      fi
    fi
  fi
  [ -e "$d/.git" ] && break
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
if [ -z "$ten_detail" ]; then
  add 10 PASS "ignored keys" "no project-level provider keys, no legacy profiles (searched from $start_dir)"
else
  add 10 "$ten_status" "ignored keys" "$ten_detail" "$ten_hint"
fi

# --------------------------------------------------------------------------
# 11. live checks (only with --live)
# --------------------------------------------------------------------------
http_call() { # http_call METHOD URL BODYFILE OUTFILE -> prints HTTP status ("000" = no response)
  local method="$1" url="$2" body="$3" out="$4" k code
  k="${SECRET//\\/\\\\}"; k="${k//\"/\\\"}"
  if [ -n "$body" ]; then
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$k" | curl -sS -N -K - -o "$out" -w '%{http_code}' \
      --max-time "$TIMEOUT" -X "$method" -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
      --data-binary "@$body" "$url" 2>"$TMP/curl.err")" || true
  else
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$k" | curl -sS -K - -o "$out" -w '%{http_code}' \
      --max-time "$TIMEOUT" -X "$method" "$url" 2>"$TMP/curl.err")" || true
  fi
  printf '%s' "${code:-000}"
}

json_string() { # minimal JSON string escaping for the model ID
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

any_python() {
  local c
  for c in ${CODEX_DOCTOR_PYTHON:-} python3 python; do
    [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

LIVE_MODEL="${MODEL_ARG:-${MODEL:-}}"
live_ready=1
if [ "$LIVE" -ne 1 ]; then
  add 11a SKIP "live /models" "not run (add --live)"
  add 11b SKIP "live /responses" "not run (add --live; sends one small billed request)"
  live_ready=0
elif ! command -v curl >/dev/null 2>&1; then
  add 11a FAIL "live /models" "curl not found"
  add 11b SKIP "live /responses" "curl not found"
  live_ready=0
elif [ "$CUSTOM" -ne 1 ] || [ -z "$BASE" ]; then
  add 11a SKIP "live /models" "no custom provider with a base_url"
  add 11b SKIP "live /responses" "no custom provider with a base_url"
  live_ready=0
fi

if [ "$live_ready" -eq 1 ]; then
  API="${BASE%/}"
  while [ "${API%/}" != "$API" ]; do API="${API%/}"; done
  PYX="$(any_python || true)"

  # 11a GET /models
  code="$(http_call GET "$API/models" "" "$TMP/models.json")"
  if [ "$code" = "200" ]; then
    summary=""
    if [ -n "$PYX" ]; then
      summary="$("$PYX" - "$TMP/models.json" "$LIVE_MODEL" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    ids = [m.get("id") for m in data.get("data", []) if isinstance(m, dict)]
except Exception:
    print("badjson\t0\t")
    sys.exit(0)
want = sys.argv[2]
print("%s\t%d\t%s" % ("listed" if want and want in ids else "missing", len(ids), ", ".join(str(i) for i in ids[:12])))
PY
)"
    elif command -v jq >/dev/null 2>&1; then
      summary="$(jq -r --arg m "$LIVE_MODEL" '[.data[]?.id] as $ids | "\(if ($ids | index($m)) then "listed" else "missing" end)\t\($ids | length)\t\($ids[0:12] | join(", "))"' "$TMP/models.json" 2>/dev/null || printf 'badjson\t0\t')"
    else
      if grep -q "\"$LIVE_MODEL\"" "$TMP/models.json"; then summary="$(printf 'listed\t?\t')"; else summary="$(printf 'missing\t?\t')"; fi
    fi
    st="${summary%%	*}"; rest="${summary#*	}"; cnt="${rest%%	*}"; ids="${rest#*	}"
    if [ "$st" = "badjson" ]; then
      add 11a FAIL "live /models" "HTTP 200 but the body is not an OpenAI-style model list" "check base_url: $API/models"
    elif [ -z "$LIVE_MODEL" ]; then
      add 11a PASS "live /models" "HTTP 200, $cnt models: $(one_line "$ids" 160)"
    elif [ "$st" = "listed" ]; then
      add 11a PASS "live /models" "HTTP 200, $cnt models, $LIVE_MODEL is listed"
    else
      add 11a WARN "live /models" "HTTP 200, $cnt models, but $LIVE_MODEL is not listed: $(one_line "$ids" 160)" \
        "set model to one of the listed IDs (IDs differ between gateways and key groups)"
    fi
  else
    bodytxt="$(one_line "$(cat "$TMP/models.json" 2>/dev/null)$(cat "$TMP/curl.err" 2>/dev/null)" 200)"
    case "$code" in
      401|403) add 11a FAIL "live /models" "HTTP $code: key rejected: $bodytxt" "check the key value and that it belongs to this gateway (docs/errors.md#401)" ;;
      404)     add 11a FAIL "live /models" "HTTP 404 for $API/models: $bodytxt" "base_url is probably wrong (docs/errors.md#404-v1-v1)" ;;
      000)     add 11a FAIL "live /models" "no HTTP response: $bodytxt" "check DNS / proxy / firewall for $host" ;;
      *)       add 11a FAIL "live /models" "HTTP $code: $bodytxt" ;;
    esac
  fi

  # 11b POST /responses (stream: true, like Codex)
  if [ -z "$LIVE_MODEL" ]; then
    add 11b FAIL "live /responses" "no model to test: set model in the config or pass --model ID"
  else
    printf '{"model":"%s","input":"Reply with the single word: pong","stream":true}' "$(json_string "$LIVE_MODEL")" > "$TMP/req.json"
    code="$(http_call POST "$API/responses" "$TMP/req.json" "$TMP/resp.sse")"
    if [ "$code" = "200" ]; then
      verdict=""
      if [ -n "$PYX" ]; then
        verdict="$("$PYX" - "$TMP/resp.sse" <<'PY' 2>/dev/null
import json, sys
events, last, detail = 0, None, ""
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = line[5:].strip()
    try:
        ev = json.loads(payload)
    except ValueError:
        continue
    if not isinstance(ev, dict):
        continue
    events += 1
    kind = ev.get("type", "")
    if kind in ("response.completed", "response.incomplete", "response.failed", "error"):
        last = ev
if events == 0:
    body = raw.strip()
    if body.startswith("{"):
        print("nosse\t0\tbody is plain JSON, not an SSE stream")
    else:
        print("nosse\t0\tno data: events in the body")
    sys.exit(0)
if last is None:
    print("nocompleted\t%d\tstream ended without response.completed" % events)
    sys.exit(0)
kind = last.get("type")
resp = last.get("response") if isinstance(last.get("response"), dict) else {}
if kind == "response.completed":
    rid = resp.get("id")
    usage = resp.get("usage")
    if not isinstance(rid, str):
        print("badcompleted\t%d\tresponse.completed has no response.id" % events)
    elif usage is not None and not all(isinstance((usage or {}).get(k), int) for k in ("input_tokens", "output_tokens", "total_tokens")):
        print("badcompleted\t%d\tusage lacks integer input_tokens/output_tokens/total_tokens" % events)
    else:
        u = usage or {}
        print("ok\t%d\tusage in=%s out=%s total=%s" % (events, u.get("input_tokens", "-"), u.get("output_tokens", "-"), u.get("total_tokens", "-")))
elif kind == "response.incomplete":
    reason = ((resp.get("incomplete_details") or {}).get("reason")) or "unknown"
    print("incomplete\t%d\tIncomplete response returned, reason: %s" % (events, reason))
else:
    err = resp.get("error") or last.get("error") or last.get("message") or last
    print("failed\t%d\t%s" % (events, json.dumps(err, ensure_ascii=False)[:160]))
PY
)"
      else
        if grep -q '"type" *: *"response.completed"' "$TMP/resp.sse"; then
          verdict="$(printf 'ok\t?\tresponse.completed seen (install python3 for a stricter check)')"
        elif grep -q '^data:' "$TMP/resp.sse"; then
          verdict="$(printf 'nocompleted\t?\tstream ended without response.completed')"
        else
          verdict="$(printf 'nosse\t0\tno data: events in the body')"
        fi
      fi
      vs="${verdict%%	*}"; vrest="${verdict#*	}"; vn="${vrest%%	*}"; vd="${vrest#*	}"
      case "$vs" in
        ok) add 11b PASS "live /responses" "HTTP 200, $vn SSE events, ends with response.completed, $vd" ;;
        nosse) add 11b FAIL "live /responses" "HTTP 200 but $vd" "Codex needs an SSE stream for stream=true (docs/check-responses-support.md)" ;;
        nocompleted) add 11b FAIL "live /responses" "$vd after $vn events - Codex reports: stream disconnected before completion: stream closed before response.completed" \
          "the gateway (or a proxy in front of it) must forward the final response.completed event" ;;
        badcompleted) add 11b FAIL "live /responses" "$vd" "Codex cannot parse this response.completed event" ;;
        incomplete) add 11b FAIL "live /responses" "$vd" ;;
        failed) add 11b FAIL "live /responses" "response.failed / error event: $vd" ;;
        *) add 11b FAIL "live /responses" "HTTP 200 but the stream could not be analysed" ;;
      esac
    else
      bodytxt="$(one_line "$(cat "$TMP/resp.sse" 2>/dev/null)$(cat "$TMP/curl.err" 2>/dev/null)" 200)"
      case "$code" in
        401|403) add 11b FAIL "live /responses" "HTTP $code: key rejected: $bodytxt" "docs/errors.md#401" ;;
        404|405) add 11b FAIL "live /responses" "HTTP $code for $API/responses: $bodytxt" \
          "this gateway does not serve the Responses API at this path; Codex cannot use it (docs/errors.md#responses-404)" ;;
        400|422) add 11b FAIL "live /responses" "HTTP $code: $bodytxt" "often an unknown model ID - compare with GET /models (docs/errors.md#model-not-found)" ;;
        000) add 11b FAIL "live /responses" "no HTTP response: $bodytxt" "check network / proxy; raise CODEX_DOCTOR_TIMEOUT for slow models" ;;
        *) add 11b FAIL "live /responses" "HTTP $code: $bodytxt" ;;
      esac
    fi
  fi
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
printf '\nSummary: %d PASS, %d WARN, %d FAIL, %d SKIP\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP"
if [ "$N_FAIL" -gt 0 ]; then
  printf 'Each check number is explained in docs/errors.md. Exit code = number of FAIL rows.\n'
elif [ "$LIVE" -ne 1 ]; then
  printf 'Offline checks passed. Next: --live (one small billed request), then: codex exec "Reply with the single word: ready"\n'
else
  printf 'All checks passed. Next: codex exec "Reply with the single word: ready"\n'
fi
exit "$N_FAIL"
