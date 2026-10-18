#!/usr/bin/env bash
# check_tables.sh [repo-root] [--update] — the tables stage: the control-table rules R1-R6 over the repository's .def files,
# X-list macros and const tables (check_tables.py beside this script, run with python3 -I; its docstring is the reference).
# One line per problem, "<path>:<line>: <rule>: <text>", R6 lines marked (report), then "tables: clean" or "tables: N problems"
# (exit 1; KYR_TABLES_WARN=1 reports and exits 0). tables.allow at the root keeps a reviewed exemption; --update writes
# abi/tables.txt, the record of the append-only tables.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 > /dev/null || { printf 'check_tables: python3 not found\n' >&2; exit 2; }
ROOT="${ROOT_DIR:-$(pwd -P)}"
args=()
for a in "$@"; do if [[ "${a}" == --update ]]; then args+=("${a}"); else ROOT="${a}"; fi; done
exec python3 -I "${SCRIPT_DIR}/check_tables.py" "${ROOT}" "${args[@]}"
