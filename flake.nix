# New to Nix? Start here:
#   Language basics:  https://nix.dev/tutorials/nix-language
#   Flakes intro:     https://zero-to-nix.com/concepts/flakes
#
# The docs content lives in the modelplane/ submodule, and Nix ignores a
# flake's submodules unless asked, so quote the submodules parameter into every
# command here:
#
#   nix build '.?submodules=1#site'
#   nix flake check '.?submodules=1'
#   nix run '.?submodules=1#serve'
{
  description = "Modelplane documentation site";

  # Nothing here is per-version. Archived doc versions are pinned in
  # data/versions.json (rev + hash per release branch), which is also the file
  # Hugo's version dropdown reads, so adding a release touches that one file
  # and nothing else - no input here, no lockfile entry, no Vercel project.
  #
  # main's content comes from the modelplane/ submodule instead, so `hugo
  # server` live-reloads against a working copy you can edit.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );

      docsFor = pkgs: import ./nix/docs.nix { inherit pkgs self; };
    in
    {
      packages = forAllSystems (
        { pkgs, ... }:
        {
          default = (docsFor pkgs).site;
          site = (docsFor pkgs).site;
        }
      );

      checks = forAllSystems (
        { pkgs, ... }:
        let
          docs = docsFor pkgs;
        in
        {
          # Verify the site builds. The build is the check.
          site = docs.site;

          # Check internal links with htmltest.
          htmltest = docs.htmltest;
        }
      );

      apps = forAllSystems (
        { pkgs, ... }:
        {
          # Serve the site locally with live reload. Extra args pass through to
          # hugo server, e.g.: nix run '.?submodules=1#serve' -- --port 8080
          serve = {
            type = "app";
            meta.description = "Serve the docs site locally with live reload";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "modelplane-docs-serve";
                # Hugo reads git metadata for last-modified dates
                # (enableGitInfo).
                runtimeInputs = [
                  pkgs.hugo
                  pkgs.git
                ];
                inheritPath = false;
                text = ''
                  if [ ! -d modelplane/docs/content ]; then
                    echo "modelplane/ submodule is empty. Run: git submodule update --init" >&2
                    exit 1
                  fi
                  hugo server "$@"
                '';
              }
            );
          };

          # Rebuild the site's JavaScript bundle. webpack writes the bundle
          # into the geekboot theme's assets, which are committed to git;
          # rerun this and commit the result after changing anything under
          # utils/webpack/src.
          generate = {
            type = "app";
            meta.description = "Rebuild the docs site JavaScript bundle";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "modelplane-docs-generate";
                # npm run spawns scripts via sh, so bash must be on PATH
                # alongside node.
                runtimeInputs = [
                  pkgs.nodejs
                  pkgs.bash
                ];
                inheritPath = false;
                text = ''
                  cd utils/webpack
                  npm ci
                  npm run prod
                  echo "Done. Review changes with 'git diff themes/geekboot/assets/js'."
                '';
              }
            );
          };
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.hugo
              pkgs.nodejs
              pkgs.htmltest
              pkgs.nixfmt
            ];

            shellHook = ''
              echo "Modelplane docs shell"
              echo ""
              echo "  nix run '.?submodules=1#serve'      nix run '.?submodules=1#generate'"
              echo "  nix flake check '.?submodules=1'"
              echo ""
            '';
          };
        }
      );
    };
}
