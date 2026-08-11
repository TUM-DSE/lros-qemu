{
  description = "QEMU with the virtio-accel device, for vAccel offload from a guest";

  # This tree is a QEMU fork that carries the device as source rather than as a
  # patch series: subprojects/vaccel/{hw/virtio,backends}, wired into the build
  # at meson.build:3540. The only thing it needs from outside is libvaccel,
  # which it finds through pkg-config -- hence the `vaccel` package below.
  #
  # Consumers add this flake as an input and take packages.qemu-vaccel; miniOSv
  # does exactly that (chair_fork/flake.nix) so `scripts/run.py --vaccel` has a
  # QEMU that knows the device.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        rtArch = if system == "x86_64-linux" then "x86_64" else "aarch64";

        # The host-side vAccel runtime. The device's acceldev backend links
        # against it, and the plugin that talks to the real accelerator (RKNN on
        # the Orange Pi, CUDA on a GPU host) is loaded by it at run time through
        # $VACCEL_PLUGINS.
        vaccel = pkgs.gcc13Stdenv.mkDerivation {
          pname = "vaccel";
          version = "0.7.1";

          src = pkgs.fetchgit {
            name = "vaccel-src";
            url = "https://github.com/TUM-DSE/vaccel";
            rev = "cc9942e6f5de46ff1f5eb139a208de5998024d64";
            hash = "sha256-r+oPz/6BBQol1+U31hP7J+bfaiU/PvagywzS2HoCNyQ=";
            fetchSubmodules = true;
            # meson wants its subprojects present at configure time, and the
            # build runs with no network. Fetch them while we still can, then
            # drop their .git so the output is reproducible.
            postFetch = ''
              cd "$out"
              export NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              ${nixpkgs.lib.getExe pkgs.meson} subprojects download
              find subprojects -type d -name .git -prune -execdir rm -r {} +
            '';
          };

          nativeBuildInputs = with pkgs; [ meson ninja pkg-config git ];

          # Its meson.build shells out to git for the submodules and for the
          # version; neither works in the sandbox.
          preConfigure = ''
            substituteInPlace meson.build \
              --replace "git submodule update --init >/dev/null && " ""
            echo "0.7.1-99" > .version
          '';

          mesonBuildType = "release";
        };

        # QEMU pulls a few of its meson subprojects over git at configure time.
        # A release tarball ships them; a git checkout does not, and the build
        # sandbox has no network. Fetch the one this configuration needs and
        # drop it in place. (The other .wrap files are for features nixpkgs'
        # QEMU configures off, or for system libraries it provides instead.)
        # Revisions and URLs come from the matching subprojects/*.wrap files;
        # update them together.
        wrapSubprojects = {
          keycodemapdb = pkgs.fetchgit {
            name = "keycodemapdb";
            url = "https://gitlab.com/qemu-project/keycodemapdb.git";
            rev = "f5772a62ec52591ff6870b7e8ef32482371f22c6";
            hash = "sha256-EQrnBAXQhllbVCHpOsgREzYGncMUPEIoWFGnjo+hrH4=";
          };
          # tests/fp requires these unconditionally, even though this
          # derivation does not run the test suite.
          berkeley-softfloat-3 = pkgs.fetchgit {
            name = "berkeley-softfloat-3";
            url = "https://gitlab.com/qemu-project/berkeley-softfloat-3.git";
            rev = "b64af41c3276f97f0e181920400ee056b9c88037";
            hash = "sha256-Yflpx+mjU8mD5biClNpdmon24EHg4aWBZszbOur5VEA=";
          };
          berkeley-testfloat-3 = pkgs.fetchgit {
            name = "berkeley-testfloat-3";
            url = "https://gitlab.com/qemu-project/berkeley-testfloat-3.git";
            rev = "e7af9751d9f9fd3b47911f51a5cfd08af256a9ab";
            hash = "sha256-inQAeYlmuiRtZm37xK9ypBltCJ+ycyvIeIYZK8a+RYU=";
          };
        };

        qemu-vaccel = pkgs.qemu.overrideAttrs (prev: {
          pname = "qemu-vaccel";
          version = "10.1.50-vaccel";

          src = self;

          # nixpkgs' patches target the QEMU release it packages; this fork is a
          # different tree and does not need them.
          patches = [ ];

          buildInputs = prev.buildInputs ++ [ vaccel ];
          nativeBuildInputs = prev.nativeBuildInputs ++ [ pkgs.pkg-config ];

          # --target-list: one softmmu target, the host's own. Two reasons.
          # The device is added to specific_ss unconditionally
          # (meson.build:4137), so any target built without CONFIG_VIRTIO fails
          # to link it -- `undefined reference to virtio_error`. And the point
          # of this QEMU is to run a guest of the host's own architecture under
          # KVM; emulating the other one is what the plain nixpkgs qemu is for.
          # lros-expe configures it the same way.
          #
          # --enable-virtfs: lros-expe shares the model directory over 9p.
          configureFlags = prev.configureFlags ++ [
            "--enable-virtfs"
            "--target-list=${rtArch}-softmmu"
          ];

          doCheck = false;

          postPatch = (prev.postPatch or "") + ''
            ${nixpkgs.lib.concatStringsSep "\n" (
              nixpkgs.lib.mapAttrsToList (name: src: ''
                cp -r ${src} subprojects/${name}
                chmod -R u+w subprojects/${name}
                # A wrap with patch_directory has its meson.build in the
                # in-tree overlay rather than upstream; meson would apply it
                # after downloading, so do the same.
                if [ -d subprojects/packagefiles/${name} ]; then
                  cp -r subprojects/packagefiles/${name}/. subprojects/${name}/
                fi
              '') wrapSubprojects
            )}

            # docs/conf.py looks for the VERSION file relative to sphinx's
            # working directory, which is not the source root during meson's
            # sphinx probe. It then falls back to the literal "unknown version"
            # and dies parsing that as x.y.z. Give the fallback the real one.
            substituteInPlace docs/conf.py \
              --replace 'version = release = "unknown version"' \
                        "version = release = \"$(cat VERSION)\""
          '';
        });
      in
      {
        packages = {
          inherit vaccel qemu-vaccel;
          default = qemu-vaccel;
        };

        devShells.default = pkgs.mkShell {
          packages = [ qemu-vaccel vaccel ];
        };
      }
    );
}
