#!/bin/sh
# Install the Bistro world into Graffitty's worlds folder.
#
#   gft world install bistro                    # runs this script from the release's tag
#   sh install.sh                               # latest release
#   sh install.sh v0.0.1                        # a specific release
#
# It checks the zip against the release's SHA256SUMS and replaces
# $XDG_DATA_HOME/graffitty/worlds/bistro (default ~/.local/share/graffitty/worlds).
set -eu

REPO=graffitty/bistro-world
ID=bistro
ZIP=bistro-world.zip

info() { printf 'bistro: %s\n' "$*" >&2; }
error() { printf 'bistro: error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || error "'$1' is required but was not found"; }

# All work happens in main, called on the last line. If `curl | sh` receives
# only part of the script, nothing runs.
main() {
  [ "$#" -le 1 ] || error "usage: install.sh [version]"
  [ -n "${HOME:-}" ] || error "HOME is not set"
  for tool in unzip awk cut mktemp mv rm; do need "$tool"; done
  sha_tool
  resolve_version "${1:-}"

  worlds="${XDG_DATA_HOME:-$HOME/.local/share}/graffitty/worlds"
  mkdir -p "$worlds" || error "could not create $worlds"
  tmp="$(mktemp -d)" || error "could not create a temporary directory"
  # Unpack next to the destination, so installing is a rename.
  staging="$(mktemp -d "$worlds/.$ID-install.XXXXXX")" || error "could not create a directory in $worlds"
  trap 'rm -rf "$tmp" "$staging"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  info "downloading Bistro $version"
  base="https://github.com/$REPO/releases/download/$version"
  download "$base/SHA256SUMS" "$tmp/SHA256SUMS" || error "could not fetch SHA256SUMS for release $version"
  download "$base/$ZIP" "$tmp/$ZIP" progress || error "could not download $ZIP for release $version"
  verify "$tmp" "$ZIP"

  unzip -q "$tmp/$ZIP" -d "$staging" || error "could not unpack $ZIP"
  [ -f "$staging/$ID/$ID.pck" ] && [ -f "$staging/$ID/$ID.json" ] \
    || error "$ZIP does not contain $ID/$ID.pck and $ID/$ID.json"

  # Replace the whole folder: the .pck and .json must always match.
  rm -rf "${worlds:?}/$ID"
  mv "$staging/$ID" "$worlds/$ID" || error "could not move $ID into $worlds"
  info "Bistro $version is installed at $worlds/$ID"
  info "restart Graffitty and choose View > World > Bistro"
}

# Sets $version to a release tag such as v0.0.1. Without one it asks GitHub for
# the latest release once; both downloads then use that tag.
resolve_version() {
  if [ -n "$1" ] && [ "$1" != latest ]; then
    version="$1"
    case "$version" in v*) ;; *) version="v$version" ;; esac
  else
    url="https://github.com/$REPO/releases/latest"
    if command -v curl >/dev/null 2>&1; then
      final="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o /dev/null -w '%{url_effective}' "$url")" \
        || error "could not reach $url"
    elif command -v wget >/dev/null 2>&1; then
      final="$(wget -S -O /dev/null "$url" 2>&1 \
        | awk 'tolower($1) == "location:" { l = $2 } END { sub(/\r$/, "", l); print l }')"
    else
      error "curl or wget is required"
    fi
    version="${final##*/}"
  fi
  printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]+)?$' \
    || error "invalid release tag '$version' (expected e.g. v0.0.1)"
}

download() {
  if command -v curl >/dev/null 2>&1; then
    if [ "${3:-}" = progress ] && [ -t 2 ]; then
      curl --proto '=https' --tlsv1.2 -fL --retry 3 -# -o "$2" "$1"
    else
      curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    error "curl or wget is required"
  fi
}

sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    sha="shasum -a 256"
  else
    error "sha256sum or shasum is required"
  fi
}

# Stops unless SHA256SUMS has an entry for $2 and the file matches it.
verify() {
  expected="$(awk -v f="$2" '
    NF == 2 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ {
      name = $2; sub(/^\*/, "", name); sub(/^\.\//, "", name)
      if (name == f) { print $1; exit }
    }' "$1/SHA256SUMS")"
  [ -n "$expected" ] || error "release SHA256SUMS has no entry for $2; refusing to install it unverified"
  actual="$($sha "$1/$2" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || error "checksum mismatch for $2 (expected $expected, got $actual)"
}

main "$@"
