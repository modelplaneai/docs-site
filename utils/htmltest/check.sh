#!/usr/bin/env bash
# Copyright 2026 The Modelplane Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Check internal links in every version built into public/.
#
# Run once per version rather than once over the whole tree. Each version is
# its own Hugo build, so the version switcher on every page necessarily links
# to the same page in the other versions - which may not exist there, and in
# production lands on that version's own 404 (see the rewrite in vercel.json).
# htmltest cannot express "check only this version", so each run derives the
# set of top-level directories in public/ that do NOT belong to the version
# being checked, and ignores both their documents (IgnoreDirs, so their
# switcher links never fire) and links pointing into them (IgnoreURLs). The
# tree root stays public/, because prefixed links resolve only from there.
#
# The latest release is served bare at the root, so "its" directories are
# whatever is left once the archived versions' prefixes are removed - which is
# why the foreign set is computed from the built tree rather than written down.
#
# Only internal links are checked (CheckExternal is false), so this needs no
# network and cannot flake on someone else's downtime.
set -euo pipefail
cd "$(dirname "$0")/../.."

[ -d public ] || {
	echo "No public/ to check. Run build.sh first." >&2
	exit 1
}
command -v htmltest >/dev/null 2>&1 || {
	echo "htmltest is not on PATH: https://github.com/wjdp/htmltest" >&2
	exit 1
}

versions=$(node -p 'require("./themes/geekboot/data/docversions.json").versions
	.map(v => v.version).join(" ")')
# The prefix each archived version is served under. The latest release has
# none: it is the root.
archived=$(node -p 'const d=require("./themes/geekboot/data/docversions.json");
	d.versions.filter(v => v.version !== d.latest).map(v => v.path).join(" ")')
latest=$(node -p 'require("./themes/geekboot/data/docversions.json").latest')
toplevel=$(cd public && for d in */; do echo "${d%/}"; done)

cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT

# Regex-escape the dots in a version prefix: "v0.3" would match "v0x3".
escape() { printf '%s' "$1" | sed 's/[.]/\\./g'; }

failed=""
for version in $versions; do
	# Everything in the built tree that is not part of this version. For an
	# archived version that is every other top-level directory; for the latest
	# release, which owns the root, it is the archived prefixes.
	if [ "$version" = "$latest" ]; then
		foreign="$archived"
	else
		mine=$(VER="$version" node -p 'const d=require("./themes/geekboot/data/docversions.json");
			d.versions.find(v => v.version === process.env.VER).path')
		foreign=""
		for d in $toplevel; do
			[ "$d" = "$mine" ] || foreign="$foreign $d"
		done
	fi

	# Single-quoted YAML scalars: the patterns contain \. , which is not a
	# legal escape inside a double-quoted one.
	{
		echo "DirectoryPath: 'public'"
		echo "CheckExternal: false"
		echo "IgnoreInternalEmptyHash: true"
		echo "IgnoreURLs:"
		echo "  - '/site.webmanifest'"
		echo "  - '/safari-pinned-tab.svg'"
		for d in $foreign; do
			echo "  - '^/$(escape "$d")/'"
		done
		echo "IgnoreDirs:"
		for d in $foreign; do
			echo "  - '^$(escape "$d")/'"
		done
	} > "$cfg"

	echo "==> $version"
	htmltest --conf "$cfg" || failed="$failed $version"
done

if [ -n "$failed" ]; then
	echo "Broken internal links in:$failed" >&2
	exit 1
fi
echo "Internal links are intact in every version."
