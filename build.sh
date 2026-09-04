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

# Build every documented version of the site into public/.
#
# No prose lives in this repo. Each entry in data/docversions.json names a branch
# of the modelplane repo; this script shallow-clones that branch into
# modelplane/ and runs Hugo against it, writing the result under public/<path>/.
# One Vercel project, rooted at this repo, serves all of them.
#
# Adding a version is one line in data/docversions.json: no content pin, no hash,
# no submodule, no flake input, no second Vercel project. Publishing new prose
# is a redeploy - every build reads the tip of the branch it tracks.
#
# Vercel runs this as the buildCommand (see vercel.json). It is the same script
# CI runs, so a green CI build is the deploy rehearsed.
set -euo pipefail
cd "$(dirname "$0")"

# Hugo is a single binary, so fetch it rather than depending on the build image
# to carry one. Pinned with its published checksum: this runs unattended with
# network access, so an unverified artifact would be code execution. Bump the
# version and both hashes together, from:
#   curl -sL https://github.com/gohugoio/hugo/releases/download/v<ver>/hugo_<ver>_checksums.txt
# The extended build is required - the theme's CSS is SCSS.
HUGO_VERSION="0.165.0"
HUGO_SHA256_linux_amd64="f43494894cdf4a8630a201d5c828051c77f523cc66bb3938b30806835470ac20"
HUGO_SHA256_linux_arm64="f40ebc44dfda3896cecd3ae7ed44f5c44c4b4a30a2b7d976ece6da62da699a58"

# A hugo fetched by an earlier run of this script counts as installed.
export PATH="$PWD/bin:$PATH"

# Match the pinned version, not merely the presence of a hugo on PATH. The
# theme calls template functions that only exist in recent releases, and an
# older binary fails deep inside a partial ("can't evaluate field Data"),
# which reads as a template bug rather than the version mismatch it is.
if ! hugo version 2>/dev/null | grep -q "v${HUGO_VERSION}+extended"; then
	case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) arch="linux-amd64"; sha="$HUGO_SHA256_linux_amd64" ;;
	Linux-aarch64) arch="linux-arm64"; sha="$HUGO_SHA256_linux_arm64" ;;
	*)
		# Upstream ships macOS only as a .pkg, so there is nothing to unpack
		# here. Local builds on a Mac use a Hugo you installed yourself.
		echo "Install Hugo extended v${HUGO_VERSION} (no tarball for $(uname -sm))." >&2
		exit 1
		;;
	esac
	tarball="hugo_extended_${HUGO_VERSION}_${arch}.tar.gz"
	curl -fsSL -o "$tarball" \
		"https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/${tarball}"
	echo "${sha}  ${tarball}" | sha256sum --check --status
	mkdir -p bin
	tar -xzf "$tarball" -C bin hugo
	rm -f "$tarball"
	export PATH="$PWD/bin:$PATH"
fi

# Hugo shells out to the postcss CLI to prune, sort, and minify the compiled
# CSS (see postcss.config.js), so the pipeline needs node_modules on disk.
# Vercel's install step already ran npm install; this covers CI and local runs.
[ -d node_modules ] || npm ci --no-audit --no-fund
export PATH="$PWD/node_modules/.bin:$PATH"
export NODE_PATH="$PWD/node_modules"

# Production bakes the canonical apex into every URL. Previews must not: a
# preview is reachable on both its deployment URL and its branch alias and sits
# behind Deployment Protection, so a baseURL pinned to one host makes the
# cross-host request for the stylesheet hit the auth wall and return HTML,
# leaving the page unstyled. Root-relative URLs resolve against whichever host
# serves the page.
if [ "${VERCEL_ENV:-}" = "production" ]; then
	root="${HUGO_BASEURL:-https://docs.modelplane.ai/}"
else
	root="${HUGO_BASEURL:-/}"
fi
# Hugo joins baseURL to paths verbatim, so a missing trailing slash silently
# produces ".../aiv0.3/".
root="${root%/}/"

# data/docversions.json is read here and by the version dropdown, so the builds
# and the switcher cannot drift. Parsed with node, which every environment that
# runs this already has; jq is not on Vercel's build image.
read_json() { node -p "$1"; }
repo=$(read_json 'require("./data/docversions.json").repo')
latest=$(read_json 'require("./data/docversions.json").latest')
latest_path=$(read_json 'const d=require("./data/docversions.json");
	const v=d.versions.find(v=>v.version===d.latest);
	if(!v) throw new Error(`latest "${d.latest}" is not in the versions list`);
	v.path')

# Write the list to a file rather than piping it: bash process substitution
# needs /dev/fd, which Vercel's Amazon Linux 2023 image does not provide.
versions=$(mktemp)
trap 'rm -f "$versions"' EXIT
read_json 'require("./data/docversions.json").versions
	.map(v=>[v.version,v.path,v.branch].join("\t")).join("\n")' > "$versions"

rm -rf public
while IFS=$'\t' read -r version path branch; do
	[ -n "$path" ] || continue
	echo "==> /$path/  from $repo@$branch"

	# A fresh shallow, sparse clone per version, narrowed to exactly the four
	# trees hugo.toml mounts. Release branches cut before the site moved here
	# still carry their own copy of the theme and config under docs/; leaving
	# them out of the checkout keeps a stale copy from being anywhere Hugo could
	# find it.
	rm -rf modelplane
	git clone --quiet --depth 1 --single-branch --branch "$branch" --sparse \
		"https://github.com/${repo}.git" modelplane
	git -C modelplane sparse-checkout set \
		docs/content docs/data docs/manifests apis

	# Passed per build rather than committed to each release branch: that is
	# what lets one branch of this repo build every version, and it keeps the
	# dropdown's active entry and the "not the latest release" banner accurate
	# without a release branch ever editing hugo.toml.
	HUGO_BASEURL="${root}${path}/" \
	HUGO_PARAMS_VERSION="$version" \
	HUGO_PARAMS_PATH="$path" \
	HUGO_PARAMS_BRANCH="$branch" \
	HUGO_PARAMS_LATEST="$latest" \
		hugo --minify --destination "public/$path"
done < "$versions"

# The apex holds no build of its own; it points at the latest release.
cat > public/index.html <<HTML
<!doctype html>
<meta charset="utf-8">
<title>Modelplane documentation</title>
<meta http-equiv="refresh" content="0; url=/${latest_path}/">
<link rel="canonical" href="/${latest_path}/">
<a href="/${latest_path}/">Modelplane documentation</a>
HTML

# These four are only ever looked for at a site root: crawlers fetch
# /robots.txt, the llms.txt convention puts the corpus at the apex, and
# api/mcp.js fetches /llms.json. Serve the latest release's copies there.
for f in robots.txt llms.txt llms-full.txt llms.json; do
	cp "public/${latest_path}/$f" "public/$f"
done
