#!/usr/bin/env bash
# Checks that no tracked, non-binary file of this repository names either of the two retired
# machines, in any letter case, and that none of them names a home directory: a path that starts at
# the root of one person's account and goes on below it is one person's machine layout, and it has
# no business in a public file. Both names and both directory roots are assembled from fragments
# below, so this file holds no string its own scan matches, and it reports the offending file names
# and never the matched text.
#
# A URL path is not a home directory: the token after the root has to be followed by another slash,
# which is what keeps /home/logo.png of the site out of the way.
#
# Usage: bash scripts/no-host-names.test.sh              check the repository this file lives in
#        bash scripts/no-host-names.test.sh --tree DIR   check another repository (used by the
#                                                        self-check below)
set -euo pipefail

NAME_ONE="nez""opt"
NAME_TWO="pi""-home"
PATTERN="${NAME_ONE}|${NAME_TWO}"

ROOT_ONE="/ho""me"
ROOT_TWO="/U""sers"
DIR_PATTERN="(${ROOT_ONE}|${ROOT_TWO})/[A-Za-z0-9_.-]+/"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="${HERE}/$(basename -- "${BASH_SOURCE[0]}")"
REAL_ROOT="$(cd -- "${HERE}/.." && pwd)"
GIT_ID_NAME="no-host-names self-check"
GIT_ID_EMAIL="no-host-names@invalid"

# scan <root> <pattern>: exit 0 with the matching file names on stdout, exit 1 when nothing matches,
# exit 2 when there was nothing to scan. Tracked files only, and -I skips binary ones.
scan() {
  local root="$1" pattern="$2"
  local -a tracked=()
  mapfile -d '' -t tracked < <(git -C "${root}" ls-files -z)
  if (( ${#tracked[@]} == 0 )); then
    return 2
  fi
  git -C "${root}" grep -I -i -l -E "${pattern}" -- "${tracked[@]}"
}

# scan_tree <root> <pattern>...: the union of the file names each pattern matches, and the exit code
# of the whole: 0 when any pattern matched, 1 when none did, 2 when the tree could not be scanned.
# The names of one pattern come before the names of the next, and a file two patterns match is
# listed once, under the first of them.
scan_tree() {
  local root="$1"; shift
  local pattern out='' rc=1 one='' one_rc=0
  for pattern in "$@"; do
    if one="$(scan "${root}" "${pattern}")"; then
      one_rc=0
    else
      one_rc=$?
    fi
    if [[ "${one_rc}" -eq 0 ]]; then
      rc=0
      out+="${one}"$'\n'
    elif [[ "${one_rc}" -ne 1 ]]; then
      rc=2
      out=''
      break
    fi
  done
  if [[ -n "${out}" ]]; then
    printf '%s' "${out}" | awk 'NF && !seen[$0]++'
  fi
  return "${rc}"
}

if [[ "${1:-}" == "--tree" ]]; then
  root="${2:-}"
  if [[ -z "${root}" ]]; then
    echo "usage: ${SELF} --tree DIR" >&2
    exit 2
  fi
  out=""
  if out="$(scan_tree "${root}" "${PATTERN}" "${DIR_PATTERN}")"; then
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
if out="$(scan_tree "${REAL_ROOT}" "${PATTERN}" "${DIR_PATTERN}")"; then
  fail=1
  echo "FAIL: tracked files naming a retired machine or a home directory:"
  while IFS= read -r file; do
    if [[ -n "${file}" ]]; then
      echo "  ${file}"
    fi
  done <<< "${out}"
else
  rc=$?
  if [[ "${rc}" -eq 1 ]]; then
    ok "no tracked file names a retired machine (${tracked_count} files checked)"
    ok "no tracked file names a home directory (${tracked_count} files checked)"
  else
    bad "the repository could not be scanned (rc ${rc})"
    fail=1
  fi
fi

# Each of the two patterns is reported under its own headline, so a failure says which rule it broke
# even when one file breaks both.
for want in "machine:${PATTERN}" "home directory:${DIR_PATTERN}"; do
  label="${want%%:*}"
  pattern="${want#*:}"
  if hit="$(scan "${REAL_ROOT}" "${pattern}")"; then
    bad "tracked files naming a ${label}:"
    while IFS= read -r file; do
      if [[ -n "${file}" ]]; then
        echo "  ${file}"
      fi
    done <<< "${hit}"
  fi
done

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

# poison <text>: one tracked file of the copy carrying this text, and the commit that records it
poison() {
  printf 'this tracked file holds %s on purpose\n' "$1" > "${COPY}/poison.txt"
  copy_git add -A
  copy_git commit -q -m "a tracked file carrying that text"
}
# clean_poison: the file is gone again
clean_poison() {
  rm -f "${COPY}/poison.txt"
  copy_git add -A
  copy_git commit -q -m "the file is gone again"
}

run_on_copy
if [[ "${last_rc}" -eq 0 ]]; then
  ok "self-check: the scan passes on a copy of the tree"
else
  bad "self-check: the scan of the copy returned ${last_rc} instead of 0: ${last_out}"
fi

for name in "${NAME_ONE}" "${NAME_TWO}"; do
  poison "mentions ${name}"
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
  clean_poison
  run_on_copy
  if [[ "${last_rc}" -eq 0 ]]; then
    ok "self-check: the scan passes again with the file removed"
  else
    bad "self-check: the scan returned ${last_rc} instead of 0 after the removal"
  fi
done

# The home-directory rule: each shape that names one fails the scan, and each URL-style path that
# only looks like one passes. The text is built from the fragments above, so this file holds none of
# it. The name inside the path is a dummy made up here; it is not a real account of this repository.
for shape in "${ROOT_ONE}/some.owner/data/objects/a.png" "${ROOT_TWO}/some.owner/Pictures/x.png" \
  "${ROOT_ONE}/a.b/c" "${ROOT_TWO}/a-b/c" "${ROOT_ONE}/0/x"; do
  poison "the directory ${shape}"
  run_on_copy
  if [[ "${last_rc}" -eq 1 ]]; then
    ok "self-check: the scan fails on a tracked file holding [${shape}]"
  else
    bad "self-check: [${shape}] returned ${last_rc} instead of 1"
  fi
  if [[ "${last_out}" == "poison.txt" ]]; then
    ok "self-check: the failure of a home-directory file names the file"
  else
    bad "self-check: the failure did not report poison.txt but [${last_out}]"
  fi
  if [[ "${last_out}" != *"${shape}"* ]] && [[ "${last_out}" != *"${ROOT_ONE}"* ]] \
    && [[ "${last_out}" != *"${ROOT_TWO}"* ]]; then
    ok "self-check: the failure of a home-directory file prints no matched text"
  else
    bad "self-check: the failure printed the matched text"
  fi
  clean_poison
  run_on_copy
  if [[ "${last_rc}" -eq 0 ]]; then
    ok "self-check: the scan passes again with the directory file removed"
  else
    bad "self-check: the scan returned ${last_rc} instead of 0 after the removal"
  fi
done

# A URL path of the site is not a home directory: the token after the root is a file name, and no
# slash follows it. Both of these are real paths of this repository.
for plain in "${ROOT_ONE}/logo.png" "${ROOT_ONE}/satoshi.woff2" "${ROOT_TWO}" \
  "${ROOT_ONE#?}/some.owner/x" "${ROOT_TWO#?}/some.owner/x"; do
  poison "the path ${plain}"
  run_on_copy
  if [[ "${last_rc}" -eq 0 ]]; then
    ok "self-check: [${plain}] is not a home directory and passes the scan"
  else
    bad "self-check: [${plain}] failed the scan with rc ${last_rc}: [${last_out}]"
  fi
  clean_poison
done

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
