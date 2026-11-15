{
  description = "A JSON Patch (RFC 6902) and JSON Merge Patch (RFC 7396) implementation for PostgreSQL.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    omniflake.url = "github:fzakaria/omniflake";
    omniflake.inputs.nixpkgs.follows = "nixpkgs";
    # A current rust-overlay: omniflake's pinned rust-flake ships an older one
    # that only knows up to Rust 1.98. Substitute it via omniflake.lib.load.
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    advisory-db.url = "github:rustsec/advisory-db";
    advisory-db.flake = false;
  };

  outputs = inputs @ {
    omniflake,
    advisory-db,
    ...
  }: let
    # Load rust-flake from the index, overriding its rust-overlay input
    # with the current one so rust-toolchain.toml can resolve to 1.99+.
    rust-flake = omniflake.lib.load "rust-flake" {inherit (inputs) rust-overlay;};
  in
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

        # cargo-pgrx is pinned to 0.19.3 in nixpkgs, but this extension
        # targets pgrx 0.20.0, so build cargo-pgrx ourselves from crates.io.
        cargoPgrxSrc = pkgs.fetchCrate {
          pname = "cargo-pgrx";
          version = "0.20.0";
          hash = "sha256-/m7INFfPmDjcUozktErKJu9jw8m8vWctg0aSTEFufIY=";
        };

        cargo-pgrx = crane-lib.buildPackage {
          src = cargoPgrxSrc;
          pname = "cargo-pgrx";
          version = "0.20.0";
          cargoLock = "${cargoPgrxSrc}/Cargo.lock";
          nativeBuildInputs = [pkgs.pkg-config];
          buildInputs = [pkgs.openssl pkgs.zstd];
          doCheck = false;
        };

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
                  inherit src postgresql pname cargo-pgrx;
                  version = config.rust-project.cargoToml.package.version;
                  cargoHash = "sha256-9uGn0KxdG+gD+NHr+DhvRLxU11fXPX6BL8swkLaMvD0=";

                  # pgrx tests try to install the extension into postgresql nix store
                  doCheck = false;

                  env = {
                    LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
                    CLANG_PATH = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
                    PGRX_BINDGEN_NO_DETECT_INCLUDES = "1";
                  };

                  preBuild = ''
                    export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
                    export CLANG_PATH="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
                    export PGRX_BINDGEN_NO_DETECT_INCLUDES=1
                    ${lib.optionalString pkgs.stdenv.isLinux ''
                      export BINDGEN_EXTRA_CLANG_ARGS="$(cat ${pkgs.llvmPackages.clang}/nix-support/cc-cflags) $(cat ${pkgs.llvmPackages.clang}/nix-support/libc-cflags)"
                    ''}
                    ${lib.optionalString pkgs.stdenv.isDarwin
                      "export BINDGEN_EXTRA_CLANG_ARGS=\"\""}
                  '';

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
              export CLANG_PATH="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
              ${lib.optionalString pkgs.stdenv.isLinux
                "export BINDGEN_EXTRA_CLANG_ARGS=\"-isystem ${pkgs.glibc.dev}/include\""}
              export PGRX_BINDGEN_NO_DETECT_INCLUDES=1
              mkdir -p "$PGRX_HOME"
              exec ${crane-lib.clippy}/bin/cargo-clippy clippy \
                --offline \
                --no-default-features \
                --features "pg19" \
                -- \
                -D warnings
            '');
          };
          # FIX: Enabling convco breaks at latest flake.lock
          convco.enable = false;
          nil.enable = true;
          treefmt.enable = true;
          trufflehog.enable = true;
        };

        devShells.default = pkgs.mkShell {
          PSQL_PAGER = "${lib.getExe pkgs.pspg} --reprint-on-exit --blackwhite";

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          CLANG_PATH = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
          BINDGEN_EXTRA_CLANG_ARGS =
            lib.optionalString pkgs.stdenv.isLinux "-isystem ${pkgs.glibc.dev}/include";
          PGRX_BINDGEN_NO_DETECT_INCLUDES = "1";

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
