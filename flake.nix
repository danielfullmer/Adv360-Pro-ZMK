{
  outputs = { self, nixpkgs }:
    let
      inherit (builtins) attrNames concatStringsSep mapAttrs listToAttrs elemAt filter;
      inherit (nixpkgs) lib;

      # TODO: This could probably be made much more generic.
      westZmk = lib.importJSON ./west-zmk.json; # JSON corresponding to the west.yml from https://github.com/ReFil/zmk
      westZephyr = lib.importJSON ./west-zephyr.json; # JSON corresponding to the west.yml from https://github.com/zmkfirmware/zephyr

      nameBlocklist = (elemAt westZmk.manifest.projects 0).import.name-blocklist;
      filteredProjects = filter (p: !lib.elem p.name nameBlocklist) westZephyr.manifest.projects;
      remotes = listToAttrs (map (p: lib.nameValuePair p.name p.url-base) westZephyr.manifest.remotes);

      modules = {
        "zephyr" = { url = "https://github.com/zmkfirmware/zephyr"; ref = "v3.2.0+zmk-fixes"; rev = "0a586db7b58269fb08248b081bdc3b43452da5f4"; };
      } // listToAttrs (map (p: {
        name = p.name;
        value = {
          url = "${remotes.${p.remote or westZephyr.manifest.defaults.remote}}/${p.name}";
          rev = p.revision;
        };
      }) filteredProjects);

      buildInputs = pkgs: with pkgs; [
        git
        gcc-arm-embedded
        cmake
        bzip2
        ccache
        dtc
        dfu-util
        libtool
        ninja
        gperf
        xz
        (python3.withPackages (p: with p; [
          pyelftools
          pyyaml
          pykwalify
          canopen
          packaging
          progress
          psutil
          intelhex
          west
        ]))
        qemu
      ];

      moduleSetupCommands = pkgs: let
        # Using builtins.fetchGit so we don't have to get the sha256 beforehand
        modulePackages = mapAttrs (path: spec: builtins.fetchGit spec) modules;

        # ln -s might actually work
        moduleSetupCommand = path: pkg: "mkdir -p $(dirname ./${path}); cp -r ${pkg} ./${path}";
      in concatStringsSep "\n" (map (name: moduleSetupCommand name modulePackages.${name}) (attrNames modulePackages));

      system = "x86_64-linux";
    in {
      packages.x86_64-linux = {
        default = self.packages.x86_64-linux.firmwarePackage {
          board = "adv360_left";
          shields = ["left" "right"];
          inherit system;
        };

        defaultZmk =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.fetchFromGitHub {
#          owner = "zmkfirmware";
#          repo = "zmk";
#          rev = "41dc774848dace9b4bcfa59691c81a229dd416e1";
#          sha256 = "/BIVgqOfavHVIIVGLfg7rOx6T8GPhEjOsokvq1uw6sw=";
          owner = "ReFil"; # Fork for adv360 keyboard
          repo = "zmk";
          rev = "4b5ecbc0d905e65f78de66bfc25b862b9782b2c1"; # 2023-05-30
          sha256 = "sha256-jm7S6v+rJhukiVeBvO7ikX68x4ADQnp/htmnCiqYsXY=";
        };

        firmwarePackage =
          { name ? "zmk-firmware"
          , board
          , shields
          , config ? ./config
          , zmk ? null
          , system
          }:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          realZmk = if zmk == null
                    then self.packages.x86_64-linux.defaultZmk
                    else zmk;

          src = pkgs.stdenv.mkDerivation {
            name = "zmk-firmware-source";

            src = realZmk;

            buildPhase = ''
              mkdir -p .west
              cat >.west/config <<EOF
              [manifest]
              path = app
              file = west.yml

              [zephyr]
              base = zephyr
              EOF
              ${moduleSetupCommands pkgs}
            '';
            installPhase = ''
              cp -r . $out
            '';
          };

        in pkgs.stdenv.mkDerivation {
          inherit name src;

          nativeBuildInputs = buildInputs pkgs;

          CCACHE_DISABLE = 1;
          ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
          GNUARMEMB_TOOLCHAIN_PATH = pkgs.gcc-arm-embedded;

          # dontUseCmakeConfigure = true;
          configurePhase = ''
            # The west commands needs to find .git
            git -C zephyr init
            git -C zephyr config user.email 'foo@example.com'
            git -C zephyr config user.name 'Foo Bar'
            git -C zephyr add -A
            git -C zephyr commit -m 'Fake commit'
            git -C zephyr checkout -b manifest-rev
            git -C zephyr checkout --detach manifest-rev
          '';

          #${concatStringsSep "\n" (map (shield: "west -vvv build -p -d build/${shield} -b ${board} -- -DSHIELD=${shield} -DZMK_CONFIG=${config}") shields)}
          buildPhase = ''
            export ZEPHYR_BASE=$PWD/zephyr
            cd app
            west -vvv build -p -d build/left -b adv360_left -- -DZMK_CONFIG=${config}
            west -vvv build -p -d build/right -b adv360_right -- -DZMK_CONFIG=${config}
            cd ..
          '';

          #${concatStringsSep "\n" (map (shield: "cp app/build/${shield}/zephyr/zmk.uf2 $out/${shield}.uf2") shields)}
          installPhase = ''
            mkdir -p $out
            cp app/build/left/zephyr/zmk.uf2 $out/left.uf2
            cp app/build/right/zephyr/zmk.uf2 $out/right.uf2
          '';
        };
      };

      devShell.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.mkShell {
          nativeBuildInputs = buildInputs pkgs;

          ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
          GNUARMEMB_TOOLCHAIN_PATH = pkgs.gcc-arm-embedded;

          shellHook = ''
            export ZEPHYR_BASE=$PWD/zephyr
          '';
        };

    };
}
