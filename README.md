# Modelplane docs site

The Hugo project behind [docs.modelplane.ai](https://docs.modelplane.ai). This
repo is the root of the Vercel project.

**The prose is not in this repo.** Content, the example manifests the pages
embed, and the API definitions the reference is generated from are all in the
[modelplane](https://github.com/modelplaneai/modelplane) repo, under `docs/`
and `apis/`. Edit pages there.

## What is in this repo

| Path | Contents |
|---|---|
| `build.sh` | The build. Clones each content branch and runs Hugo against it. |
| `hugo.toml` | Hugo config, including the mounts that read the content checkout. |
| `themes/geekboot/` | Templates, SCSS, the JavaScript bundle, static files, and the version list. |
| `themes/geekboot/data/docversions.json` | The version list. |
| `utils/` | The webpack build, the link checker, and the DocSearch config. |
| `api/mcp.js` | The docs MCP server, deployed as a Vercel function. |
| `vercel.json` | Build command, output directory, and rewrites. |
| `flake.nix` | The `preview` app, so a content checkout can serve itself. |

## URL layout

One Vercel project serves every version. The release named by `latest` in the
version list is served at the root; the others are served under a prefix.

| URL | Built from | Banner |
|---|---|---|
| `/getting-started/` | `release-0.3`, the current `latest` | none |
| `/main/getting-started/` | `main` | "unreleased version" |
| `/v0.2/…`, `/v0.1/…` | `release-0.2`, `release-0.1` | "older version" |

A version's prefix depends on which release is `latest`, so it changes over
time. When `latest` becomes 0.4, the 0.4 build moves to the root and the 0.3
build moves to `/v0.3/`.

## Tasks

### Preview the site locally

1. Install Hugo extended, at the version pinned near the top of `build.sh`.
2. Point `modelplane/` at a checkout of the content repo:

   ```console
   ln -s ~/src/modelplane modelplane
   ```

3. Start the server:

   ```console
   hugo server
   ```

Hugo reloads on edits to the checkout, so this is the setup for writing
content. `build.sh` clones into its own scratch directories and leaves this
symlink alone.

### Build every version

```console
bash build.sh
utils/htmltest/check.sh
```

`build.sh` downloads its own pinned Hugo on Linux and writes to `public/`.
`check.sh` checks internal links in each version and needs `htmltest` on PATH.
Both are what CI runs.

### Add a version

1. Confirm the branch exists in the modelplane repo. A missing branch fails the
   whole build, including the versions that would otherwise succeed.
2. Add one line to `themes/geekboot/data/docversions.json`:

   ```json
   { "version": "0.4", "path": "v0.4", "branch": "release-0.4" }
   ```

3. If the new version is the current release, set `"latest": "0.4"` in the same
   file.
4. Merge. Vercel rebuilds every version.

The version list is the only file to edit. Adding a version does not involve a
content revision, a checksum, a submodule, or a separate Vercel project.

### Change which release is latest

Set `"latest"` in the version list and merge. That moves the new release to the
root, moves the previous one to its own prefix, adds the "older version" banner
to it, and repoints the DocSearch crawl.

### Publish content changes

Nothing in this repo is pinned to a content revision, so each build reads the
current tip of every branch. A content merge in the modelplane repo therefore
appears at the next build of this repo, but nothing here triggers that build.
Until a deploy hook is wired up, run one by pushing to this repo or
redeploying from the Vercel dashboard.

### Preview a content pull request

Everything the modelplane repo needs is here; it holds no Hugo config, no
Vercel project, and no copy of this repo. Two entry points serve it, both
building one version at the root, built as `main`, so a preview carries the
"unreleased version" banner:

| Entry point | Content from | Used by |
|---|---|---|
| `nix run github:modelplaneai/docs-site#preview` | the working directory | a writer, locally |
| `CONTENT_REF=<sha> bash build.sh` | a fetch of that revision | the `Content` workflow |

`build.sh` reads `CONTENT_DIR` (a checkout on disk) or `CONTENT_REF` (a
revision to fetch) in step 4a and stops there, instead of cloning the branches
in the version list. `params.branch` becomes the revision or branch built, so
"view page source" links land on the code under review. The version switcher
still lists every version and those links 404 on a preview that contains one.

`.github/workflows/content.yml` is what the modelplane repo dispatches to. It
holds the Vercel credentials and is the only thing that deploys:

| Dispatch | Effect |
|---|---|
| `content-preview` (`ref`, `pr`) | deploys that revision as a preview, aliased to `modelplane-docs-pr-<pr>.vercel.app` |
| `content-published` | rebuilds every version and promotes it to production |

The alias is why nothing here needs write access to the modelplane repo: the
hostname follows from the pull request number, so that repo posts the link
itself when it dispatches, before this build finishes. Deploys run on Vercel
rather than in the workflow, so `vercel.json` still applies - `/mcp` and the
per-version rewrites included.

`content-published` is also what publishes a content merge. Nothing here pins a
content revision, so production is a rebuild that reads the tip of every branch
in the version list.

### Rebuild the JavaScript bundle

The bundle in `themes/geekboot/assets/js` is committed, so the site build runs
no Node step for it. After editing anything under `utils/webpack/src`:

```console
cd utils/webpack
npm ci
npm run prod
git diff ../../themes/geekboot/assets/js
```

## How the content is fetched

1. `build.sh` reads `repo` and the version list from
   `themes/geekboot/data/docversions.json`. This is the only reference to the
   content repo; the CI workflow has none.
2. The versions are built concurrently, one background job each. A job gets its
   own copy of `hugo.toml`, `postcss.config.js`, and `themes/` in a scratch
   directory, with `node_modules` symlinked, because `hugo.toml` mounts the
   checkout from the fixed path `modelplane/` and concurrent builds cannot
   share it.
3. Each job clones its branch into `modelplane/` inside its own scratch
   directory, shallow and sparse:

   ```bash
   git clone --depth 1 --single-branch --branch "$branch" \
       --sparse --filter=blob:none \
       "https://github.com/${repo}.git" "$src/modelplane"
   git -C "$src/modelplane" sparse-checkout set docs/content docs/data docs/manifests apis
   ```

   `--sparse` limits the working tree to those four directories and
   `--filter=blob:none` limits the download to their blobs, so the rest of the
   repo is never transferred.

   It then logs the resolved commit. Nothing here pins a content revision, so
   the build log is the only record of what was deployed.
4. `hugo.toml` mounts four paths out of that checkout: `docs/content` as
   content, `docs/data` as data, `apis/` (at the repo root, not under `docs/`)
   as the API reference's data and assets, and `docs/manifests` as the example
   YAML the `manifests` shortcode reads.
5. Once every job finishes, the finished trees are moved into `public/`: the
   latest release to the root, the others to their prefixes. A failure in any
   job prints all the logs and exits without assembling `public/`.

The scratch directories are inside the repo, so the move in step 5 is a rename
rather than a copy, and they are removed on exit. `.build-*` and `modelplane/`
are both gitignored.

The clone is anonymous HTTPS. If the modelplane repo ever becomes private, both
CI and Vercel will need a credential and that URL will need a token.

## URLs in templates

The content is written for a site at the domain root, which affects templates
in two ways.

**Prefixing.** A root-absolute link in the prose, such as `/getting-started/`,
is correct for the release at the root and wrong for every other version.
`partials/utils/docurl.html` adds the current prefix at render time. Content on
release branches already cut therefore stays as it is. Use the partial for any
caller-supplied URL. Hugo's `relURL` adds the baseURL subdirectory only to a
*relative* input, so the partial trims the leading slash first.
**Absolute URLs.** The `kubectl apply -f …` commands are copied into a shell,
so they cannot be root-relative. `.Permalink` is absolute only when `baseURL`
is, and preview builds are root-relative on purpose (see step 3 of `build.sh`).
`partials/utils/absurl.html` builds these against `params.site`.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on every pull request.
It checks out this repo, runs `build.sh`, then runs the link check. It does not
deploy.

On `main` it runs after the merge, in parallel with Vercel's build, so it
cannot block a bad deploy. Content is also not pinned, so a passing run says
nothing about what the content branches contain when Vercel builds later.

`.github/workflows/docsearch.yml` reindexes the deployed site into Algolia
daily. It crawls the root and stops at the archived versions' prefixes, so only
the current release is indexed.
