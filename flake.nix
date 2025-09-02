{
  description = "";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt.url = "github:numtide/treefmt-nix";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    advisory-db.url = "github:rustsec/advisory-db";
    advisory-db.flake = false;
  };

  outputs = inputs @ {
    flake-parts,
    treefmt,
    git-hooks,
    fenix,
    crane,
    advisory-db,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux"];

      imports = [
        treefmt.flakeModule
        git-hooks.flakeModule
      ];

      perSystem = {
        system,
        config,
        pkgs,
        lib,
        ...
      }: let
        name = "pg_json_patch";
        rustToolchain = fenix.packages.${system}.stable.toolchain;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        unfilteredRoot = ./.;
        src = lib.fileset.toSource {
          root = unfilteredRoot;
          fileset = lib.fileset.unions [
            (craneLib.fileset.commonCargoSources unfilteredRoot)
            (lib.fileset.fileFilter (file: file.hasExt "control") unfilteredRoot)
          ];
        };

        postgresql = pkgs.postgresql_18;
        postgresMajor = lib.versions.major postgresql.version;

        pgrxFeatures = builtins.toString [];

        preBuildAndTest = ''
          export PGRX_HOME=$(mktemp -d)
          mkdir -p $PGRX_HOME/${postgresMajor}

          cp -r -L ${postgresql}/. $PGRX_HOME/${postgresMajor}/
          chmod -R ugo+w $PGRX_HOME/${postgresMajor}
          cp -r -L ${postgresql.pg_config}/. $PGRX_HOME/${postgresMajor}/
          cp -r -L ${postgresql.lib}/lib/. $PGRX_HOME/${postgresMajor}/lib/

          ${lib.getExe pkgs.cargo-pgrx} pgrx init --pg${postgresMajor} $PGRX_HOME/${postgresMajor}/bin/pg_config \
        '';

        commonArgs = {
          inherit src;
          pname = "${name}-pg${postgresMajor}";
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.rustPlatform.bindgenHook
            postgresql.lib
            postgresql
          ];
          cargoExtraArgs = "--no-default-features --features \"pg${postgresMajor}\"";
          postPatch = "patchShebangs .";
          preBuild = preBuildAndTest;
          preCheck = preBuildAndTest;
          postBuild = ''
            if [ -f "${name}.control" ]; then
              export NIX_PGLIBDIR=${postgresql.out}/share/postgresql/extension/
              ${lib.getExe pkgs.cargo-pgrx} pgrx package --pg-config ${postgresql.pg_config}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
              export NIX_PGLIBDIR=$PGRX_HOME/${postgresMajor}/lib
            fi
          '';

          PGRX_PG_SYS_SKIP_BINDING_REWRITE = "1";
          CARGO = "${rustToolchain}/bin/cargo";
          CARGO_BUILD_INCREMENTAL = "false";
          RUST_BACKTRACE = "full";
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        pg_json_patch = craneLib.mkCargoDerivation ({
            inherit cargoArtifacts;
            buildPhaseCargoCommand = ''
              ${lib.getExe pkgs.cargo-pgrx} pgrx package --pg-config ${postgresql.pg_config}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
            '';
            doCheck = false;
            preFixup = ''
              if [ -f "${name}.control" ]; then
                ${lib.getExe pkgs.cargo-pgrx} pgrx stop all
                rm -rfv $out/target*
              fi
            '';

            postInstall = ''
              mkdir -p $out/lib
              # cp target/release/lib${name}.so $out/lib/${name}.so
              mv -v $out/${postgresql.out}/* $out
              rm -rfv $out/nix
            '';
          }
          // commonArgs);
      in {
        checks = {
          inherit pg_json_patch;

          pg_json_patch-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          pg_json_patch-doc = craneLib.cargoDoc (commonArgs // {inherit cargoArtifacts;});
          pg_json_patch-audit = craneLib.cargoAudit {inherit src advisory-db;};
          pg_json_patch-deny = craneLib.cargoDeny {inherit src;};

          pg_json_patch-nextest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );
        };

        packages.default = pg_json_patch;

        apps.default = {
          type = "app";
          program = lib.getExe pg_json_patch;
          meta.description = "";
        };

        treefmt.programs = {
          alejandra.enable = true; # nix
          rustfmt.enable = true; # rust
          taplo.enable = true; # toml
        };

        pre-commit.settings.hooks = {
          treefmt.enable = true;
          treefmt.package = config.treefmt.build.wrapper;
        };

        devShells.default = craneLib.devShell {
          checks = config.checks;

          # PGRX_HOME = ".pgrx";

          shellHook = ''
            ${config.pre-commit.installationScript}
          '';

          packages = with pkgs;
            [
              rust-analyzer # rust lsp
              nil # nix lsp
              cargo-pgrx
              # pgrx requirements
              pkg-config
              bison
              flex
              icu
              readline
              zlib
            ]
            ++ config.pre-commit.settings.enabledPackages
            ++ lib.attrValues config.treefmt.build.programs;
        };
      };
    };
}
