#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/site-guard.XXXXXX)
home_fixture=$(mktemp -d "${TMPDIR:-/tmp}/site-home.XXXXXX")
trap 'rm -rf "$scratch" "$home_fixture"' EXIT
sed -n '/^# BEGIN SITE GUARD$/,/^# END SITE GUARD$/p' "$root/build.sh" > "$scratch/guard.sh"
# The private source is never read or altered by this fixture.
export HOME="$home_fixture"
mkdir -p "$HOME/.config/moonshot"
printf '%s\n' "$scratch/source" > "$HOME/.config/moonshot/site-root"
source "$scratch/guard.sh"
mkdir -p "$scratch/source/dir" "$scratch/outside"
printf 'look-alike\n' > "$scratch/outside/file.html"
printf 'look-alike\n' > "$scratch/source/file.html"
printf 'look-alike\n' > "$scratch/source/dir/file.html"
printf 'file.html\ndir/file.html\n' > "$scratch/list"
expect_refusal() {
  local label="$1" requested="$2" list="$3"
  if site_guard "$requested" "$list" > "$scratch/output" 2>&1; then
    echo "FAIL $label accepted"
    exit 1
  fi
  if ! grep -q 'refuses' "$scratch/output"; then
    echo "FAIL $label has no refusal message"
    exit 1
  fi
  echo "PASS $label"
}
if [ "${1:-}" = --mutant ]; then
  # Remove one boundary at a time in temporary copies, then run the same checks.
  python3 - "$scratch/guard.sh" "$scratch" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
p = pathlib.Path(sys.argv[2])
mutations = {
    'hardlink': ('[ "$(stat -c %h -- "$current")" != 1 ]', 'false'),
    'outside': ('[ "$requested" != "$root" ]', 'false'),
    'root-link': ('[ -L "$root" ]', 'false'),
    'component-link': ('[ -L "$current" ]', '[ -L "$current" ] && [ "$rest" = "$part" ]'),
    'file-link': ('[ -L "$current" ]', '[ -L "$current" ] && [ "$rest" != "$part" ]'),
    'nonregular': ('[ ! -f "$current" ]', 'false'),
    'absent': ('return 0\n  fi', 'return 1\n  fi'),
    'traversal': ("''|/*|*/|*//*|.*|*/.*|*[!a-zA-Z0-9_./-]*)", "'')"),
}
for name, (old, new) in mutations.items():
    assert old in s
    (p / (name + '.sh')).write_text(s.replace(old, new, 1))
PY
  for mutation in hardlink outside root-link component-link file-link nonregular absent traversal; do
    if bash "$0" --case "$mutation" "$scratch/$mutation.sh" > "$scratch/$mutation.log" 2>&1; then
      echo "FAIL mutation survived $mutation"
      exit 1
    fi
    echo "RED $mutation"
    cat "$scratch/$mutation.log"
  done
  exit 0
fi
if [ "${1:-}" = --case ]; then
  sed "s|$(dirname "$3")|$scratch|g" "$3" > "$scratch/mutant.sh"
  source "$scratch/mutant.sh"
fi
ln "$scratch/source/file.html" "$scratch/hardlink"
expect_refusal hardlink "$scratch/source" "$scratch/list"
rm "$scratch/hardlink"
site_guard "$scratch/source" "$scratch/list"
[ "${#SITE_FILES[@]}" = 2 ] || { echo 'FAIL valid subset'; exit 1; }
expect_refusal outside "$scratch/outside" "$scratch/list"
ln -s "$scratch/outside" "$scratch/root-link"
mv "$scratch/source" "$scratch/saved"
ln -s "$scratch/saved" "$scratch/source"
expect_refusal root-link "$scratch/source" "$scratch/list"
rm "$scratch/source"
mv "$scratch/saved" "$scratch/source"
mv "$scratch/source/dir" "$scratch/source/saved-dir"
ln -s "$scratch/outside" "$scratch/source/dir"
expect_refusal component-link "$scratch/source" "$scratch/list"
rm "$scratch/source/dir"
mv "$scratch/source/saved-dir" "$scratch/source/dir"
mv "$scratch/source/file.html" "$scratch/source/saved-file"
ln -s "$scratch/outside/file.html" "$scratch/source/file.html"
expect_refusal file-link "$scratch/source" "$scratch/list"
rm "$scratch/source/file.html"
mkfifo "$scratch/source/file.html"
expect_refusal nonregular "$scratch/source" "$scratch/list"
rm "$scratch/source/file.html"
mv "$scratch/source/saved-file" "$scratch/source/file.html"
printf '../outside/file.html\n' > "$scratch/bad-list"
expect_refusal traversal "$scratch/source" "$scratch/bad-list"
mv "$scratch/source" "$scratch/saved"
site_guard "$scratch/source" "$scratch/list" > "$scratch/absent.log" 2>&1 || { echo 'FAIL absent folder'; exit 1; }
[ "${#SITE_FILES[@]}" = 0 ] || { echo 'FAIL stale checked paths'; exit 1; }
grep -q 'absent' "$scratch/absent.log"
echo 'PASS absent folder clears the checked paths'

cp "$HOME/.config/moonshot/site-root" "$scratch/good-root"
for value in '' 'relative/path' '/tmp/../outside' '/tmp/bad root'; do
  printf '%s\n' "$value" > "$HOME/.config/moonshot/site-root"
  expect_refusal root-pattern "$scratch/source" "$scratch/list"
done
printf '/tmp/one\n/tmp/two\n' > "$HOME/.config/moonshot/site-root"
expect_refusal multi-line "$scratch/source" "$scratch/list"
rm "$HOME/.config/moonshot/site-root"
ln -s "$scratch/good-root" "$HOME/.config/moonshot/site-root"
expect_refusal config-link "$scratch/source" "$scratch/list"
rm "$HOME/.config/moonshot/site-root"
site_guard "" "$scratch/list"
[ "${#SITE_FILES[@]}" = 0 ]
