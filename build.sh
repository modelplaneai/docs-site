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

# Build every version of the docs site into public/.
#
# The prose is in the modelplane repo, not in this one.
# themes/geekboot/data/docversions.json has one entry per version, and each
# entry names a branch of that repo. This script clones each branch in turn and
# runs Hugo against it.
#
# Output layout, for a version list whose "latest" is 0.3:
#
#   public/           built from release-0.3
#   public/main/      built from main
#   public/v0.2/      built from release-0.2
#   public/v0.1/      built from release-0.1
#
# The release named by "latest" is written to the root and served without a path
# prefix. Changing "latest" to 0.4 moves 0.4 to the root and moves 0.3 to
# public/v0.3/. No prefix is written down outside docversions.json.
#
# Steps below:
#   1. install Hugo
#   2. install node_modules for the PostCSS pipeline
#   3. work out the baseURL
#   4. read the version list
#   5. build the versions, all at once
#   6. assemble public/
#
# vercel.json sets this script as the buildCommand, and CI runs the same
# script.

set -euo pipefail
cd "$(dirname "$0")"

# --- 1. Install Hugo -------------------------------------------------------
#
# Hugo ships as a single binary, so download it rather than requiring the build
# image to provide one. The checksum is verified because this runs unattended
# with network access. To upgrade, replace the version and both hashes with
# values from:
#
#   curl -sL https://github.com/gohugoio/hugo/releases/download/v<ver>/hugo_<ver>_checksums.txt
#
# The extended build is required, because the theme's CSS is SCSS.

HUGO_VERSION="0.165.0"
HUGO_SHA256_linux_amd64="f43494894cdf4a8630a201d5c828051c77f523cc66bb3938b30806835470ac20"
HUGO_SHA256_linux_arm64="f40ebc44dfda3896cecd3ae7ed44f5c44c4b4a30a2b7d976ece6da62da699a58"

# Put a Hugo downloaded by a previous run on PATH before testing the version,
# so repeat runs skip the download.
export PATH="$PWD/bin:$PATH"

# Test the version rather than just whether some hugo is on PATH. The templates
# call functions added in recent Hugo releases. An older binary fails inside a
# partial with "can't evaluate field Data", which is difficult to trace back to
# the Hugo version.
if ! hugo version 2>/dev/null | grep -q "v${HUGO_VERSION}+extended"; then
	case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) arch="linux-amd64"; sha="$HUGO_SHA256_linux_amd64" ;;
	Linux-aarch64) arch="linux-arm64"; sha="$HUGO_SHA256_linux_arm64" ;;
	*)
		# Upstream publishes macOS builds only as a .pkg, which this cannot
		# unpack. Install Hugo yourself for local builds on a Mac.
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
fi

# --- 2. Install node_modules -----------------------------------------------
#
# Hugo runs the postcss CLI to prune, sort, and minify the compiled CSS (see
# postcss.config.js), which needs node_modules on disk. Vercel's install step
# has already done this; the check covers CI and local runs.

[ -d node_modules ] || npm ci --no-audit --no-fund
export PATH="$PWD/node_modules/.bin:$PATH"
export NODE_PATH="$PWD/node_modules"

# --- 3. Work out the baseURL ----------------------------------------------
#
# Production builds use the canonical domain. Other builds use root-relative
# URLs, because a preview deployment answers on both its own deployment URL and
# its branch alias, and Deployment Protection blocks cross-host requests. An
# absolute baseURL pinned to one of those hosts returns the login page instead
# of the stylesheet when the page is opened on the other, and the page renders
# unstyled.
#
# HUGO_BASEURL overrides both cases, for a Vercel project serving some other
# domain.

if [ "${VERCEL_ENV:-}" = "production" ]; then
	root="${HUGO_BASEURL:-https://docs.modelplane.ai/}"
else
	root="${HUGO_BASEURL:-/}"
fi

# Hugo concatenates baseURL and path without inserting a separator, so the
# trailing slash is required. Without it, "https://docs.modelplane.ai" and
# "v0.3/" produce "https://docs.modelplane.aiv0.3/".
root="${root%/}/"

# --- 4. Read the version list ---------------------------------------------
#
# The version dropdown and the "not the latest release" banner read the same
# file through Hugo, so the build and the templates agree on the version set.
# node does the parsing here because jq is not installed on Vercel's build
# image.

versions_json="./themes/geekboot/data/docversions.json"
read_json() { node -p "$1"; }

repo=$(read_json "require('$versions_json').repo")
latest=$(read_json "require('$versions_json').latest")

# params.site. The kubectl commands in the pages are copied into a shell, so
# they need absolute URLs even when this build's baseURL is root-relative. See
# themes/geekboot/layouts/partials/utils/absurl.html.
site=$(read_json "require('$versions_json').site")

# Fail here rather than producing a site with no root.
read_json "const d = require('$versions_json');
	if (!d.versions.some(v => v.version === d.latest))
		throw new Error(\`latest \"\${d.latest}\" is not in the versions list\`);
	''" >/dev/null

# Write the list to a temp file instead of piping it. Reading from a pipe would
# need bash process substitution, which requires /dev/fd, and Vercel's Amazon
# Linux 2023 image does not provide it.
#
# The latest release sorts first because step 6 renames its output to public/
# and the other versions then become subdirectories of it.
versions=$(mktemp)
trap 'rm -f "$versions"' EXIT
read_json "const d = require('$versions_json');
	const first = v => v.version === d.latest ? 0 : 1;
	[...d.versions].sort((a, b) => first(a) - first(b))
		.map(v => [v.version, v.path, v.branch].join('\t')).join('\n')" > "$versions"

# --- 5. Build the versions, all at once ----------------------------------
#
# The versions are independent, so they are built concurrently and the build
# takes about as long as the slowest one instead of the sum of all of them.
#
# Each version needs its own copy of the site, because hugo.toml mounts the
# content checkout from the fixed path modelplane/ and four concurrent builds
# cannot share one path. A copy is hugo.toml, postcss.config.js and themes/,
# which is a few megabytes; node_modules is symlinked instead of copied.
#
# The work directory is inside the repo so that moving finished output into
# public/ in step 6 is a rename rather than a copy across filesystems.

work=$(mktemp -d "$PWD/.build-XXXXXX")
trap 'rm -f "$versions"; rm -rf "$work"' EXIT
mkdir -p "$work/out"

# Output goes to a per-version log and is printed in step 6, because four
# concurrent builds writing to the terminal interleave into nothing readable.
build_version() {
	local version=$1 path=$2 branch=$3 prefix=$4
	local src="$work/src-$path"
	local sha

	mkdir -p "$src"
	cp -R hugo.toml postcss.config.js themes "$src/"
	ln -s "$PWD/node_modules" "$src/node_modules"

	git clone --quiet --depth 1 --single-branch --branch "$branch" --sparse \
		"https://github.com/${repo}.git" "$src/modelplane"
	git -C "$src/modelplane" sparse-checkout set \
		docs/content docs/data docs/manifests apis

	# Record which commit was built. Nothing in this repo pins a content
	# revision, so the log is the only place the deployed content is named.
	sha=$(git -C "$src/modelplane" rev-parse --short HEAD)
	echo "==> /$prefix  from $repo@$branch ($sha)"

	# These four values differ per version, so they are passed as environment
	# overrides rather than committed to each release branch. hugo.toml sets
	# the defaults used by a plain `hugo server`.
	HUGO_BASEURL="${root}${prefix}" \
	HUGO_PARAMS_VERSION="$version" \
	HUGO_PARAMS_BRANCH="$branch" \
	HUGO_PARAMS_SITE="$site" \
		hugo --source "$src" --minify --destination "$work/out/$path"
}

pids=""
while IFS=$'\t' read -r version path branch; do
	[ -n "$path" ] || continue
	if [ "$version" = "$latest" ]; then
		prefix=""
	else
		prefix="$path/"
	fi
	build_version "$version" "$path" "$branch" "$prefix" \
		> "$work/log-$path" 2>&1 &
	pids="$pids $!"
done < "$versions"

# Wait for all of them before failing, so one broken version does not hide
# what the others reported.
status=0
for pid in $pids; do
	wait "$pid" || status=1
done

# --- 6. Assemble public/ ---------------------------------------------------

rm -rf public
while IFS=$'\t' read -r version path branch; do
	[ -n "$path" ] || continue
	cat "$work/log-$path"
	[ "$status" -eq 0 ] || continue
	# The latest release sorted first in step 4, so this rename creates
	# public/ and the other versions become subdirectories of it.
	if [ "$version" = "$latest" ]; then
		mv "$work/out/$path" public
	else
		mv "$work/out/$path" "public/$path"
	fi
done < "$versions"

exit "$status"
