#!/usr/bin/env bash
# Checks that no tracked, non-binary file of this repository names either of the two retired
# machines, in any letter case. It reports the offending file names and never the matched text.
# Both names are assembled from fragments below, so this file does not contain either of them.
#
# Usage: bash scripts/no-host-names.test.sh              check the repository this file lives in
#        bash scripts/no-host-names.test.sh --tree DIR   check another repository (used by the
#                                                        self-check below)
set -euo pipefail

NAME_ONE="nez""opt"
NAME_TWO="pi""-home"
PATTERN="${NAME_ONE}|${NAME_TWO}"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="${HERE}/$(basename -- "${BASH_SOURCE[0]}")"
REAL_ROOT="$(cd -- "${HERE}/.." && pwd)"
GIT_ID_NAME="no-host-names self-check"
GIT_ID_EMAIL="no-host-names@invalid"

# scan <root>: exit 0 with the matching file names on stdout, exit 1 when nothing matches, exit 2
# when there was nothing to scan. Tracked files only, and -I skips binary ones.
scan() {
  local root="$1"
  local -a tracked=()
  mapfile -d '' -t tracked < <(git -C "${root}" ls-files -z)
  if (( ${#tracked[@]} == 0 )); then
    return 2
  fi
  git -C "${root}" grep -I -i -l -E "${PATTERN}" -- "${tracked[@]}"
}

if [[ "${1:-}" == "--tree" ]]; then
  root="${2:-}"
  if [[ -z "${root}" ]]; then
    echo "usage: ${SELF} --tree DIR" >&2
    exit 2
  fi
  out=""
  if out="$(scan "${root}")"; then
    printf '%s\n' "${out}"
    exit 1
  else
    rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      exit 0
    fi
    echo "no-host-names: ${root} could not be scanned (rc ${rc})" >&2
    exit 2
  fi
fi

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tracked_count=0
mapfile -d '' -t all_tracked < <(git -C "${REAL_ROOT}" ls-files -z)
tracked_count=${#all_tracked[@]}

out=""
if out="$(scan "${REAL_ROOT}")"; then
  fail=1
  echo "FAIL: tracked files naming a retired machine:"
  while IFS= read -r file; do
    if [[ -n "${file}" ]]; then
      echo "  ${file}"
    fi
  done <<< "${out}"
else
  rc=$?
  if [[ "${rc}" -eq 1 ]]; then
    ok "no tracked file names a retired machine (${tracked_count} files checked)"
  else
    bad "the repository could not be scanned (rc ${rc})"
    fail=1
  fi
fi

# Self-check: a copy of the tree in a temporary directory, made a repository of its own, with one
# extra tracked file carrying each name. The scan must fail on it and pass again once it is removed,
# which shows the check above is not simply passing because it looked at nothing.
TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/no-host-names-selfcheck.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
COPY="${TMP}/copy"
mkdir -p "${COPY}"
git -C "${REAL_ROOT}" archive HEAD | tar -x -C "${COPY}"

copy_git() {
  GIT_CONFIG_COUNT=0 git -C "${COPY}" -c user.name="${GIT_ID_NAME}" -c user.email="${GIT_ID_EMAIL}" "$@"
}
copy_git init -q
copy_git add -A
copy_git commit -q -m "copy of the tracked files"

last_out=""
last_rc=0
run_on_copy() {
  last_rc=0
  last_out="$(bash "${SELF}" --tree "${COPY}")" || last_rc=$?
}

run_on_copy
if [[ "${last_rc}" -eq 0 ]]; then
  ok "self-check: the scan passes on a copy of the tree"
else
  bad "self-check: the scan of the copy returned ${last_rc} instead of 0: ${last_out}"
fi

for name in "${NAME_ONE}" "${NAME_TWO}"; do
  printf 'this tracked file mentions %s on purpose\n' "${name}" > "${COPY}/poison.txt"
  copy_git add -A
  copy_git commit -q -m "a tracked file naming a machine"
  run_on_copy
  if [[ "${last_rc}" -eq 1 ]]; then
    ok "self-check: the scan fails on a tracked file naming the machine"
  else
    bad "self-check: the scan returned ${last_rc} instead of 1 on a named-machine file"
  fi
  if [[ "${last_out}" == "poison.txt" ]]; then
    ok "self-check: the failure names the file"
  else
    bad "self-check: the failure did not report poison.txt but [${last_out}]"
  fi
  if [[ "${last_out}" != *"${name}"* ]]; then
    ok "self-check: the failure prints no matched text"
  else
    bad "self-check: the failure printed the matched text"
  fi
  rm "${COPY}/poison.txt"
  copy_git add -A
  copy_git commit -q -m "the file is gone again"
  run_on_copy
  if [[ "${last_rc}" -eq 0 ]]; then
    ok "self-check: the scan passes again with the file removed"
  else
    bad "self-check: the scan returned ${last_rc} instead of 0 after the removal"
  fi
done

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
