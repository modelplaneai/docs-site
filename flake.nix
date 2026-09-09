{
  # The docs site, as a runnable preview.
  #
  # The prose is in the modelplane repo. This flake exists so that repo can
  # preview its own content without knowing anything about Hugo:
  #
  #   nix run github:modelplaneai/docs-site#preview
  #
  # run from a modelplane checkout. The deployed site is built by build.sh, not
  # from here - Vercel's build image is fixed and installs its own pinned Hugo.
  # Keep pkgs.hugo and HUGO_VERSION in build.sh on the same version.
  description = "Modelplane docs site";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      apps = forAllSystems (pkgs: rec {
        default = preview;

        # Serve the site against the content checkout in the working directory,
        # with live reload. Extra arguments pass through to `hugo server`, e.g.
        # `nix run ...#preview -- --port 8080`.
        preview = {
          type = "app";
          meta.description = "Preview a modelplane content checkout, with live reload";
          program = pkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "modelplane-docs-preview";
              runtimeInputs = [
                pkgs.hugo
                pkgs.coreutils
              ];
              inheritPath = false;
              text = ''
                content="$PWD"
                if [ ! -d "$content/docs/content" ]; then
                  echo "No docs/content here - run this from a modelplane checkout." >&2
                  exit 1
                fi

                # hugo.toml mounts the content from a "modelplane" directory
                # beside it, and Hugo writes resources/ and hugo_stats.json into
                # its own source directory, so the site is copied out of the
                # read-only store rather than served from it.
                #
                # Resolved, not just created: with --environment production Hugo
                # runs PostCSS under Node's permission model, Node resolves
                # paths with realpathSync, and on macOS /tmp is a link to
                # /private/tmp, which reads outside what Hugo granted. The
                # failure is an opaque ERR_ACCESS_DENIED on /tmp.
                work="$(cd "$(mktemp -d)" && pwd -P)"
                trap 'rm -rf "$work"' EXIT
                cp -R ${self}/. "$work"/
                chmod -R u+w "$work"
                ln -sfn "$content" "$work/modelplane"

                # `hugo server` builds the development environment, which skips
                # the PostCSS pipeline, so this needs no node_modules.
                #
                # enableGitInfo is off because the copy is not a git checkout;
                # the last-modified dates it reads are cosmetic.
                #
                # The version switcher lists every version and those links 404
                # here, since only this one is being served.
                echo "Serving $content/docs/content - http://localhost:1313"
                HUGO_ENABLEGITINFO=false exec hugo server --source "$work" "$@"
              '';
            }
          );
        };
      });
    };
}
