#!/bin/sh
# Bump the pinned tailcat version: tools/update-tailcat.sh <ref>
# <ref> is a commit hash, tag, or branch understood by go get.
set -e

if test $# -ne 1; then
  echo "usage: tools/update-tailcat.sh <ref>" >&2
  exit 1
fi

root=`cd "\`dirname "$0"\`/.." && pwd`
GO="${RTAILCAT_GO:-go}"
: "${GOTOOLCHAIN:=local}"
export GOTOOLCHAIN

cd "$root/src/go"
"$GO" get "github.com/tailscale/tailcat@$1"
"$GO" mod tidy

required=`sed -n 's/^go[ 	][ 	]*\([0-9][0-9.]*\).*$/\1/p' go.mod | head -n 1`
sed -e "s/^SystemRequirements: Go (>= [0-9.]*)/SystemRequirements: Go (>= $required)/" \
  "$root/DESCRIPTION" > "$root/DESCRIPTION.tmp"
mv "$root/DESCRIPTION.tmp" "$root/DESCRIPTION"

if test -d vendor; then
  rm -rf vendor
  "$GO" mod vendor
fi

# Keep the test relay module (tests/relay) on the same tailcat commit.
pin=`sed -n 's/^[ 	]*github.com\/tailscale\/tailcat \(v[^ ]*\).*$/\1/p' go.mod | head -n 1`

# The full commit hash behind the pin, for the header links in the docs.
commit=`"$GO" mod download -json "github.com/tailscale/tailcat@$pin" | sed -n 's/^[ 	]*"Hash": "\([0-9a-f]\{40\}\)".*$/\1/p' | head -n 1`
if test -n "$commit"; then
  sed -e "s/^tailcat_commit = \"[0-9a-f]*\"/tailcat_commit = \"$commit\"/" \
    "$root/R/abi.R" > "$root/R/abi.R.tmp"
  mv "$root/R/abi.R.tmp" "$root/R/abi.R"
else
  echo "Could not find the commit hash of $pin; update tailcat_commit in R/abi.R by hand." >&2
fi

cd "$root/tests/relay"
"$GO" get "github.com/tailscale/tailcat@$pin"
"$GO" mod tidy
cd "$root/src/go"

grep 'github.com/tailscale/tailcat ' go.mod
echo "Go requirement: $required (DESCRIPTION updated). tailcat commit: ${commit:-unknown} (R/abi.R; rerun devtools::document())."
echo "Check tailcat.h for ABI changes before releasing."
echo "Review inst/COPYRIGHTS if the set of bundled Go modules changed (see git diff src/go/go.mod); this script does not regenerate it."
