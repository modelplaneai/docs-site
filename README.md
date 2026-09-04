# Modelplane docs site

The Hugo project behind [docs.modelplane.ai](https://docs.modelplane.ai):
config, layouts, the geekboot theme, the CSS and JavaScript pipelines, and the
docs MCP server. This repo is the root of the Vercel project.

**None of the prose is here.** Content, the example manifests the pages embed,
and the API definitions the reference is generated from all live in the
[modelplane](https://github.com/modelplaneai/modelplane) repo, under `docs/`
and `apis/`. Edit pages there, not here.

## Versions

Every version is built from this one branch, by one Vercel project. The latest
release is the site - served bare at the root, with no prefix anywhere in its
URLs. Every other version is served under its own prefix and carries a banner
saying it is not the latest.

| URL | Built from | Banner |
|---|---|---|
| `/getting-started/` | `@release-0.3` (`latest`) | none |
| `/main/getting-started/` | `@main` | "unreleased version" |
| `/v0.2/…`, `/v0.1/…` | `@release-0.2`, `@release-0.1` | "older version" |

So a version's prefix is not a fixed property of it: `0.3` is bare today and
moves to `/v0.3/` the day `0.4` ships. That is why `latest` lives in the
version list rather than being baked into a path anywhere.

`themes/geekboot/data/docversions.json` is the whole list. `build.sh` clones
each branch and builds it; the version dropdown and the banners read the same file, so the
builds, the switcher, and "which one is current" cannot drift.

### Adding a version

One line, and nothing else:

```json
{ "version": "0.4", "path": "v0.4", "branch": "release-0.4" }
```

Bump `latest` in the same file if the new one is the latest release - that one
edit moves it to the root and moves the version it replaces to its own prefix.
There is no content pin to compute, no hash, no submodule, no flake input, no
release branch in this repo, and no second Vercel project.

Because nothing is pinned, **publishing new prose is a redeploy** - every build
reads the tip of the branch it tracks. A theme or layout fix reaches every
archived version the same way, which per-branch builds could never do.

## Working on it

Point `modelplane/` at a checkout of the content repo and Hugo will live-reload
against your working copy:

```console
ln -s ~/src/modelplane modelplane
hugo server
```

That needs Hugo **extended**, at the version pinned at the top of `build.sh`
(the theme's CSS is SCSS, and the templates use recent functions).

Build every version exactly as Vercel does, then check the links:

```console
bash build.sh
utils/htmltest/check.sh
```

`build.sh` fetches its own pinned Hugo on Linux and writes to `public/`. Both
are what CI runs, so a green CI run is the deploy rehearsed.

## How the content gets in

`hugo.toml` mounts four trees out of `modelplane/`: `docs/content` as content,
`docs/data` as data, `apis/` (repo root, not under `docs/`) as the API
reference's data and assets, and `docs/manifests` as the example YAML the
`manifests` shortcode embeds.
`build.sh` swaps the checkout under that fixed path once per version, so no
mount is per-version and no config is templated.

Two wrinkles worth knowing, both from the prose being written as though the
site sat at the domain root (`/getting-started/`) - which for the latest
release it does:

- **Prefixing.** For any other version, a root-absolute link in the prose would
  jump out of the version being read. `partials/utils/docurl.html` prefixes
  them at render time, so nothing has to be back-ported to content on release
  branches already cut. It is a no-op for the latest release. Note that
  Hugo's `relURL` only prepends the baseURL subdirectory for a *relative*
  input - a leading slash makes it a no-op - which is the whole reason that
  partial exists.
- **Absolute URLs.** The `kubectl apply -f …` commands are copied out of the
  page and pasted into a shell, so they cannot be root-relative. `.Permalink`
  is only absolute when `baseURL` is, and preview deployments build
  root-relative on purpose (several hostnames reach one deployment, so baking
  in a single host breaks the assets). `partials/utils/absurl.html` builds
  those against `params.site`, the canonical root, so the command names the
  published file whatever renders the page.

## Rebuilding the JavaScript bundle

The bundle under `themes/geekboot/assets/js` is committed, so the site build
needs no Node step for it. After changing anything under `utils/webpack/src`:

```console
cd utils/webpack && npm ci && npm run prod
git diff ../../themes/geekboot/assets/js
```
