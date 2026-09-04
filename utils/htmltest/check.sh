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
# htmltest cannot express "ignore links that leave this version", so per run:
# the tree root stays public/, because links carry a /v0.3/-style prefix and
# resolve only from there; IgnoreDirs narrows the documents checked to the one
# version; and IgnoreURLs drops links pointing into the others. Across the
# loop every version is checked, and the deliberately dangling switcher links
# are checked never.
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

paths=$(node -p 'require("./data/docversions.json").versions.map(v=>v.path).join(" ")')
cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT

failed=""
for path in $paths; do
	# Every other version's prefix, as one regex alternation with the dots
	# escaped ("v0.3" would otherwise match "v0x3").
	others=$(VER="$path" node -p '
		require("./data/docversions.json").versions
			.map(v => v.path)
			.filter(p => p !== process.env.VER)
			.map(p => p.replace(/[.]/g, "\\."))
			.join("|")')

	# Single-quoted YAML scalars: the patterns contain \. , which is not a
	# legal escape inside a double-quoted one.
	cat > "$cfg" <<-YAML
		DirectoryPath: 'public'
		CheckExternal: false
		IgnoreInternalEmptyHash: true
		IgnoreDirs:
		  - '^(${others})/'
		IgnoreURLs:
		  - '^/(${others})/'
		  - '/site.webmanifest'
		  - '/safari-pinned-tab.svg'
	YAML

	echo "==> /$path/"
	htmltest --conf "$cfg" || failed="$failed $path"
done

if [ -n "$failed" ]; then
	echo "Broken internal links in:$failed" >&2
	exit 1
fi
echo "Internal links are intact in every version."
