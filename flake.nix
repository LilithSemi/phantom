{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flakever.url = "github:numinit/flakever";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      flakever,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };

      forAllSystems =
        f:
        genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );

      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix));
    in
    {
      versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default =
            let
              androidEnv = pkgs.callPackage "${pkgs.path}/pkgs/development/mobile/androidenv" {
                inherit pkgs;
                licenseAccepted = true;
              };
              androidSdk =
                (androidEnv.composeAndroidPackages {
                  platformVersions = [ "36" ];
                  buildToolsVersions = [ "36.0.0" ];
                  abiVersions = [
                    "arm64-v8a"
                    "x86_64"
                  ];
                  includeNDK = true;
                  includeEmulator = false;
                  includeSystemImages = false;
                  includeCmake = false;
                }).androidsdk;
              jdk = pkgs.jdk17;

              useAndroidSdk = pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64;
            in
            pkgs.mkShell {
              packages =
                with pkgs;
                [
                  zig_0_17
                  bun
                  nodejs
                  typescript
                  pkg-config
                  vulkan-loader
                ]
                ++ lib.optionals useAndroidSdk [
                  androidSdk
                  gradle_8
                  jdk
                ];

              env = lib.optionalAttrs useAndroidSdk {
                JAVA_HOME = jdk.home;
                ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
                ANDROID_NDK_ROOT = "${androidSdk}/libexec/android-sdk/ndk-bundle";
              };

              shellHook = lib.optionalString useAndroidSdk ''
                export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$(echo "$ANDROID_HOME/build-tools/"*/aapt2) ''${GRADLE_OPTS:-}"
              '';
            };
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        { system, pkgs, ... }:
        {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "phantom";
            inherit (flakeverConfig) version;

            src = lib.cleanSource ./.;

            zigDeps = pkgs.zig_0_17.fetchDeps {
              inherit (finalAttrs) src pname version;
              hash = "sha256-m7KR7GpskAG9k4dao6gzAZHnZEyWB7bj7qeBUrtps6o=";
            };

            nativeBuildInputs = with pkgs; [
              zig_0_17
            ];

            postConfigure = ''
              ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            doCheck = true;
          });

          formatting = treefmtEval.${system}.config.build.check self;
        }
      );
    };
}
