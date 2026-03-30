{
  description = "A JSON Patch (RFC 6902) and JSON Merge Patch (RFC 7396) implementation for PostgreSQL.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt.url = "github:numtide/treefmt-nix";
    treefmt.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    rust.url = "github:juspay/rust-flake";
    rust.inputs.nixpkgs.follows = "nixpkgs";
    advisory-db.url = "github:rustsec/advisory-db";
    advisory-db.flake = false;
  };

  outputs = inputs @ {
    flake-parts,
    advisory-db,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      debug = true;
      imports = with inputs; [
        treefmt.flakeModule
        git-hooks.flakeModule
        rust.flakeModules.default
        rust.flakeModules.nixpkgs
      ];
      systems = inputs.nixpkgs.lib.systems.flakeExposed;
      perSystem = {
        config,
        pkgs,
        lib,
        ...
      }: let
        inherit (config.rust-project) crane-lib src;

        postgresql = pkgs.postgresql_18;

        buildPgrxExtension =
          pkgs.callPackage "${pkgs.path}/pkgs/development/tools/rust/cargo-pgrx/buildPgrxExtension.nix" {};
      in {
        checks = {
          inherit (config.rust-project.crates.pg_json_patch.crane.outputs.packages) pg_json_patch;
          cargo-audit = crane-lib.cargoAudit {inherit src advisory-db;};
          cargo-deny = crane-lib.cargoDeny {inherit src;};
        };

        packages.default = config.rust-project.crates.pg_json_patch.crane.outputs.packages.pg_json_patch;

        rust-project = {
          src = lib.cleanSourceWith {
            src = ./.;
            filter = path: type: (builtins.match ".*control$" path != null) || (crane-lib.filterCargoSources path type);
          };
          crates.pg_json_patch.crane.outputs.drv.crate = buildPgrxExtension (
            finalAttrs: {
              inherit src postgresql;
              cargo-pgrx = pkgs.cargo-pgrx_0_17_0;
              pname = config.rust-project.cargoToml.package.name;
              version = config.rust-project.cargoToml.package.version;
              cargoHash = "sha256-69pQ7W2mM6TBj6Sb1CgkODCZxJ+44vBelOJjCg8lCMI=";

              # pgrx tests try to install the extension into postgresql nix store
              doCheck = false;

              meta = {
                description = config.rust-project.cargoToml.package.description;
                homepage = config.rust-project.cargoToml.package.homepage;
                license = lib.licenses.mit;
              };
            }
          );
        };

        treefmt.programs = {
          alejandra.enable = true;
          rustfmt.enable = true;
          taplo.enable = true;
          taplo.settings.formatting.align_entries = true;
          taplo.settings.formatting.column_width = 120;
          taplo.settings.formatting.reorder_keys = false;
          taplo.settings.rule = [
            {
              include = ["**/Cargo.toml" "Cargo.toml"];
              keys = ["dependencies" "workspace.dependencies"];
              formatting.reorder_keys = true;
            }
          ];
        };

        pre-commit.settings.package = pkgs.prek;
        pre-commit.settings.settings.rust.check.cargoDeps = pkgs.rustPlatform.importCargoLock {
          lockFile = ./Cargo.lock;
        };
        pre-commit.settings.hooks = {
          clippy.enable = true;
          clippy.packageOverrides.cargo = crane-lib.cargo;
          clippy.packageOverrides.clippy = crane-lib.clippy;
          convco.enable = true;
          nil.enable = true;
          treefmt.enable = true;
          trufflehog.enable = true;
        };

        devShells.default = pkgs.mkShell {
          PSQL_PAGER = "${lib.getExe pkgs.pspg} --reprint-on-exit --blackwhite";

          inputsFrom = with config; [treefmt.build.devShell pre-commit.devShell devShells.rust];

          shellHook = ''
            export PGRX_HOME=$PWD/.pgrx
          '';

          packages = with pkgs; [
            postgresql.out
            nixd
            cargo-audit
            cargo-deny
            cargo-nextest
            cargo-pgrx
            # pgrx requirements
            pkg-config
            bison
            flex
            icu
            readline
            zlib
          ];
        };
      };
    };
}
