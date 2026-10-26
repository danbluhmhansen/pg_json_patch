{
  description = "A JSON Patch (RFC 6902) and JSON Merge Patch (RFC 7396) implementation for PostgreSQL.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    omniflake.url = "github:fzakaria/omniflake";
    omniflake.inputs.nixpkgs.follows = "nixpkgs";
    advisory-db.url = "github:rustsec/advisory-db";
    advisory-db.flake = false;
  };

  outputs = inputs @ {
    omniflake,
    advisory-db,
    ...
  }:
    omniflake.flakes.flake-parts.lib.mkFlake {inherit inputs;} {
      debug = false;
      imports = with omniflake.flakes; [
        treefmt-nix.flakeModule
        git-hooks-nix.flakeModule
        rust-flake.flakeModules.default
        rust-flake.flakeModules.nixpkgs
      ];
      systems = inputs.nixpkgs.lib.systems.flakeExposed;
      perSystem = {
        config,
        pkgs,
        lib,
        ...
      }: let
        inherit (config.rust-project) crane-lib src;

        postgresql = pkgs.postgresql_19;
        buildPgrxExtension = args:
          (pkgs.callPackage "${pkgs.path}/pkgs/development/tools/rust/cargo-pgrx/buildPgrxExtension.nix" {} args)
            .overrideAttrs (old: {
            meta = (old.meta or {}) // {broken = false;};
          });
      in {
        packages.default = config.rust-project.crates.pg_json_patch.crane.outputs.packages.pg_json_patch;

        checks = {
          inherit (config.rust-project.crates.pg_json_patch.crane.outputs.packages) pg_json_patch;
          cargo-audit = crane-lib.cargoAudit {inherit src advisory-db;};
          cargo-deny = crane-lib.cargoDeny {inherit src;};
        };

        rust-project = {
          src = lib.cleanSourceWith {
            src = ./.;
            filter = path: type: (builtins.match ".*control$" path != null) || (crane-lib.filterCargoSources path type);
          };

          crates.pg_json_patch.crane = {
            args = {
              env = {
                PGRX_HOME = "$TMPDIR/pgrx-home";
                PGRX_PG_CONFIG_PATH = "${postgresql.pg_config}/bin/pg_config";
              };
              preBuild = ''
                mkdir -p "$PGRX_HOME"
              '';
            };

            outputs = let
              pname = config.rust-project.crates.pg_json_patch.cargoToml.package.name;
              craneArgs = {
                inherit src pname;
                strictDeps = true;
                env = {
                  PGRX_HOME = "$TMPDIR/pgrx-home";
                  PGRX_PG_CONFIG_PATH = "${postgresql.pg_config}/bin/pg_config";
                  LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
                  BINDGEN_EXTRA_CLANG_ARGS =
                    lib.optionalString pkgs.stdenv.isLinux "-isystem ${pkgs.glibc.dev}/include";
                };
                preBuild = ''
                  mkdir -p "$PGRX_HOME"
                '';
              };
              cargoArtifacts = crane-lib.buildDepsOnly craneArgs;
            in {
              drv.crate = buildPgrxExtension (
                finalAttrs: {
                  inherit src postgresql;
                  cargo-pgrx = pkgs.cargo-pgrx;
                  inherit pname;
                  version = config.rust-project.cargoToml.package.version;
                  cargoHash = "sha256-VbEFXxRu7OxmJ1CMQSz93oMDepL0PpW3+dpTvalspaI=";

                  # pgrx tests try to install the extension into postgresql nix store
                  doCheck = false;

                  meta = {
                    description = config.rust-project.crates.pg_json_patch.cargoToml.package.description;
                    homepage = config.rust-project.cargoToml.package.homepage;
                    license = lib.licenses.mit;
                  };
                }
              );

              drv.clippy = crane-lib.cargoClippy (craneArgs
                // {
                  inherit cargoArtifacts;
                  cargoClippyExtraArgs = "--all-targets --no-default-features --features pg19 -- --deny warnings";
                  meta = {
                    description = "Clippy check for the pg_json_patch crate";
                  };
                });
            };
          };
        };

        treefmt.programs = {
          alejandra.enable = true;
          rustfmt.enable = true;
          taplo.enable = true;
        };

        pre-commit.settings.package = pkgs.prek;
        pre-commit.settings.settings.rust.check.cargoDeps = pkgs.rustPlatform.importCargoLock {
          lockFile = ./Cargo.lock;
        };
        pre-commit.settings.hooks = {
          clippy = {
            enable = true;
            packageOverrides.cargo = crane-lib.cargo;
            packageOverrides.clippy = crane-lib.clippy;
            entry = toString (pkgs.writeShellScript "clippy-with-env" ''
              export PGRX_HOME="$PWD/.pgrx"
              export PGRX_PG_CONFIG_PATH="${postgresql.pg_config}/bin/pg_config"
              export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
              ${lib.optionalString pkgs.stdenv.isLinux
                "export BINDGEN_EXTRA_CLANG_ARGS=\"-isystem ${pkgs.glibc.dev}/include\""}
              mkdir -p "$PGRX_HOME"
              exec ${crane-lib.clippy}/bin/cargo-clippy clippy \
                --offline \
                --no-default-features \
                --features "pg19" \
                -- \
                -D warnings
            '');
          };
          convco.enable = true;
          nil.enable = true;
          treefmt.enable = true;
          trufflehog.enable = true;
        };

        devShells.default = pkgs.mkShell {
          PSQL_PAGER = "${lib.getExe pkgs.pspg} --reprint-on-exit --blackwhite";

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS =
            lib.optionalString pkgs.stdenv.isLinux "-isystem ${pkgs.glibc.dev}/include";

          inputsFrom = with config; [treefmt.build.devShell pre-commit.devShell devShells.rust];

          shellHook = ''
            export PGRX_HOME=$PWD/.pgrx
          '';

          packages = with pkgs;
            [
              postgresql.out
              nixd
              tombi
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
              llvmPackages.libclang
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [
              glibc.dev
            ];
        };
      };
    };
}
