# The documentation site (https://docs.modelplane.ai).
#
# This repo holds the Hugo project: config, layouts, the geekboot theme, and
# the asset pipelines. The prose, the example manifests, and the API
# definitions come from the modelplane repo, mounted from the modelplane/
# submodule (see hugo.toml). Nix only sees a flake's submodules when asked, so
# every build here needs the submodules query parameter:
#
#   nix build '.?submodules=1#site'
#   nix flake check '.?submodules=1'
#
# Two asset pipelines feed the build:
#
#   - JavaScript is bundled by webpack and committed to git (see the generate
#     app), so the Hugo build needs no Node step for it.
#
#   - CSS is compiled from SCSS by Hugo, then run through PostCSS to prune
#     unused Bootstrap rules (PurgeCSS), sort media queries, and minify
#     (LightningCSS). Hugo shells out to the `postcss` CLI, so the build needs
#     a node_modules tree on disk. We build it reproducibly from
#     package-lock.json with fetchNpmDeps, so the Hugo build stays inside the
#     Nix sandbox with no network.
{
  pkgs,
  self,
}:
let
  # Just the two files npm reads, so an edit to the site or the content
  # submodule doesn't invalidate the node_modules build.
  npmSrc = pkgs.runCommandLocal "modelplane-docs-npm-src" { } ''
    mkdir -p $out
    cp ${../package.json} $out/package.json
    cp ${../package-lock.json} $out/package-lock.json
  '';
  # node_modules for the PostCSS pipeline, built from the committed lockfile.
  # Update fetchNpmDeps.hash below whenever package-lock.json changes:
  #   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  nodeModules = pkgs.stdenv.mkDerivation {
    pname = "modelplane-docs-node-modules";
    version = "0";
    src = npmSrc;

    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.npmHooks.npmConfigHook
    ];

    npmDeps = pkgs.fetchNpmDeps {
      src = npmSrc;
      hash = "sha256-kiwL9KU3l65W38B3OZh4JxxJPhPgp940zaIiTvXLAlk=";
    };

    dontBuild = true;

    # cp -a copies node_modules verbatim, preserving any symlinks (e.g. under
    # .bin) as npmConfigHook left them; cp -r would dereference them.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a node_modules $out/node_modules
      runHook postInstall
    '';
  };
  # Build the Hugo site inside the Nix sandbox, so:
  #
  #   HUGO_ENABLEGITINFO=false   no .git in the sandbox; git metadata is
  #                              cosmetic (last-modified dates).
  #   HUGO_ENVIRONMENT=production   selects the PostCSS+PurgeCSS CSS pipeline.
  #   baseURL                    the site is served under the /docs path of
  #                              modelplane.ai (the marketing site proxies
  #                              /docs/* here), so every Permalink, canonical
  #                              tag, asset, and sitemap URL must carry the
  #                              /docs prefix. Only the production artifact is
  #                              served there; `hugo server` (the serve app)
  #                              keeps the baseURL = "/" from hugo.toml for
  #                              local dev. Vercel PR previews override
  #                              HUGO_BASEURL with the preview's own URL so the
  #                              deployment is self-contained and reviewable
  #                              (it is served at the deployment root, not
  #                              under /docs). Pure flake eval returns "" for
  #                              getEnv, so CI and production builds keep the
  #                              canonical URL and stay reproducible/cached;
  #                              previews pass --impure (see vercel-build.sh).
  #
  # PostCSS resolves plugins from node_modules via NODE_PATH, and Hugo finds
  # the postcss CLI through the node_modules/.bin on PATH.
  # Every version of the docs, newest first. This is the same file Hugo's
  # version dropdown reads, so the build and the switcher can never drift.
  versionsData = builtins.fromJSON (builtins.readFile ../data/versions.json);
  latest = versionsData.latest;
  latestPath =
    (pkgs.lib.findFirst (
      v: v.version == latest
    ) (builtins.head versionsData.versions) versionsData.versions).path;

  # main builds from the modelplane/ submodule, so `hugo server` live-reloads
  # against a working copy. Every archived version is fetched at the rev and
  # hash recorded next to it in data/versions.json, so that one file is the
  # whole pin: adding a release is one entry there and nothing else. A flake
  # input has to be written out statically, so deriving one per version is
  # impossible - that is why the pins live in the version list instead.
  contentFor =
    v:
    if v.version == "main" then
      null
    else
      pkgs.fetchFromGitHub {
        owner = builtins.elemAt (pkgs.lib.splitString "/" versionsData.repo) 0;
        repo = builtins.elemAt (pkgs.lib.splitString "/" versionsData.repo) 1;
        inherit (v) rev hash;
      };

  # Hugo joins baseURL to paths verbatim, so a missing trailing slash silently
  # produces ".../comv0.3/".
  withSlash = url: if pkgs.lib.hasSuffix "/" url then url else url + "/";

  # The apex holds no Hugo build of its own; it points at the latest version.
  redirectPage = pkgs.writeText "index.html" ''
    <!doctype html>
    <meta charset="utf-8">
    <title>Modelplane documentation</title>
    <meta http-equiv="refresh" content="0; url=/${latestPath}/">
    <link rel="canonical" href="/${latestPath}/">
    <a href="/${latestPath}/">Modelplane documentation</a>
  '';

  mkSite =
    {
      name,
      baseURL,
      version,
      content,
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.hugo
          pkgs.nodejs
        ];
        env = {
          HUGO_ENABLEGITINFO = "false";
          HUGO_ENVIRONMENT = "production";
          HUGO_BASEURL = baseURL;
          # Which version this build is: drives the dropdown's active entry and
          # the "not the latest release" banners. Passing them per build keeps
          # every version's banner accurate, which a value baked into hugo.toml
          # on a release branch cannot be.
          HUGO_PARAMS_VERSION = version;
          HUGO_PARAMS_LATEST = latest;
        };
      }
      ''
        cp -r ${self} src
        chmod -R u+w src
        cd src
        ${pkgs.lib.optionalString (content != null) ''
          # An archived version: swap its pinned content in at the path
          # hugo.toml already mounts, so the mounts need no per-version config.
          rm -rf modelplane
          cp -r ${content} modelplane
          chmod -R u+w modelplane
        ''}
        # Without ?submodules=1 the flake source has no content to build, and
        # Hugo's failure mode is a wall of missing-mount errors. Say why.
        if [ ! -d modelplane/docs/content ]; then
          echo "modelplane/ submodule is empty. Build with '.?submodules=1#site'." >&2
          exit 1
        fi
        ln -s ${nodeModules}/node_modules node_modules
        export PATH="$PWD/node_modules/.bin:$PATH"
        export NODE_PATH="$PWD/node_modules"
        hugo --minify --destination "$out"
      '';

  # One artifact holding every version under its own path prefix, plus a root
  # redirect to the latest. One Vercel project serves all of it: no per-version
  # subdomain, no per-version project, no release branches in this repo, and a
  # theme fix reaches every archived version on the next build.
  mkJoined =
    { name, root }:
    let
      copy = v: ''
        cp -r ${
          mkSite {
            name = "${name}-${v.path}";
            baseURL = "${withSlash root}${v.path}/";
            version = v.version;
            content = contentFor v;
          }
        } $out/${v.path}
      '';
    in
    pkgs.runCommand name { } ''
      mkdir -p $out
      ${pkgs.lib.concatMapStrings copy versionsData.versions}
      cp ${redirectPage} $out/index.html
    '';
in
{
  # Every version, served at docs.modelplane.ai.
  site = mkJoined {
    name = "modelplane-docs";
    root =
      let
        envBaseURL = builtins.getEnv "HUGO_BASEURL";
      in
      if envBaseURL != "" then envBaseURL else "https://docs.modelplane.ai/";
  };

  # Check internal links with htmltest against a root-relative build of every
  # version at once. htmltest resolves links relative to the site root, so it
  # must not run against the production artifact, whose links are absolute.
  # CheckExternal is false in .htmltest.yml, so this needs no network.
  htmltest =
    pkgs.runCommand "modelplane-docs-htmltest"
      {
        nativeBuildInputs = [ pkgs.htmltest ];
      }
      ''
        htmltest --conf ${self}/utils/htmltest/.htmltest.yml \
          ${mkJoined {
            name = "modelplane-docs-local";
            root = "/";
          }}
        mkdir -p $out
        touch $out/.htmltest-passed
      '';
}
