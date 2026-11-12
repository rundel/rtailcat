#!/bin/sh
# Create src/go/vendor so the package builds fully offline (go build -mod=vendor).
# The vendor tree is about 32 MB; it is git-ignored but included by R CMD build,
# so run this before building a self-contained source tarball.
set -e

root=`cd "\`dirname "$0"\`/.." && pwd`
GO="${RTAILCAT_GO:-go}"
: "${GOTOOLCHAIN:=local}"
export GOTOOLCHAIN
# Like the build, ignore any go.work in a parent directory.
GOWORK=off
export GOWORK

cd "$root/src/go"
rm -rf vendor
"$GO" mod vendor
"$GO" list -mod=vendor github.com/tailscale/tailcat/cmd/libtailcat > /dev/null
echo "Vendored modules into $root/src/go/vendor (`du -sh vendor | cut -f1`)"
