{
  # Local path callers must use scripts/nix-source.sh before evaluating this file.
  # Filtering packageSource below cannot filter the initial flake snapshot.
  description = "isled development environment";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    agent-lsp-src = {
      url = "github:blackwell-systems/agent-lsp/c7d6a8e72e42a10bbfa8c53a8f407ab78f3b612b";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      agent-lsp-src,
    }:
    if builtins.any (name: builtins.pathExists (./. + "/${name}")) [
      "target"
      ".jj"
      ".git"
      ".direnv"
      ".dogfood"
      ".issues"
      ".agent-shell"
    ] then
      throw "Unfiltered isled checkout: use scripts/dev.sh or the flake reference printed by scripts/nix-source.sh with a path: prefix. Nix has already copied this source; do not retry the raw checkout."
    else
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        agentLsp = pkgs.buildGoModule {
          pname = "agent-lsp";
          version = "0.19.2+code-actions";
          src = agent-lsp-src;
          vendorHash = "sha256-aBokNk3GGCkMX5UYotiQHzWRKfHF6Tc0EA4hIj5XIKg=";
          subPackages = [ "cmd/agent-lsp" ];
          ldflags = [ "-s" "-w" "-X main.Version=0.19.2+code-actions" ];
        };
        # Keep unrelated documentation and frontend edits from invalidating the
        # Rust package build and test derivation.
        packageSource = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./Cargo.lock
            ./Cargo.toml
            ./LICENSE
            ./src
            ./tests
            ./skills/isled
          ];
        };
        isled = pkgs.rustPlatform.buildRustPackage {
          pname = "isled";
          version = "0.33.0";
          buildFeatures = [ "release-binary" ];
          src = packageSource;
          cargoLock.lockFile = ./Cargo.lock;
          postInstall = ''
            mkdir -p "$out/share/isled"
            cp -R skills/isled "$out/share/isled/skill"
          '';
        };
        frontendEmacs = pkgs.emacs.pkgs.withPackages (emacsPackages: [
          emacsPackages.markdown-mode
          emacsPackages.package-lint
          emacsPackages.transient
        ]);
      in
      {
        packages.default = isled;
        packages.agent-lsp = agentLsp;
        checks.default = isled;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            agentLsp
            bacon
            cargo
            clippy
            frontendEmacs
            gnumake
            jujutsu
            perl
            (python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]))
            rust-analyzer
            rustc
            rustfmt
            shellcheck
            util-linux
          ] ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ];

          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          ISLED_EMACS = "${frontendEmacs}/bin/emacs";
          ISLED_PACKAGE_LINT_ROOT = "${pkgs.emacsPackages.package-lint}";
          ISLED_TRANSIENT_ROOT = "${pkgs.emacsPackages.transient}";
          ISLED_MARKDOWN_MODE_ROOT = "${pkgs.emacsPackages.markdown-mode}";
        };
      }
    );
}
