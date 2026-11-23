{
  flake.modules.nixos.sunshine =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      domain = config.my.network.domain;
      # Moonshine keeps Moonlight's default ports (47984-48010), so Sunshine
      # moves its whole range up by 1000: add the host in Moonlight as
      # `<host>:48989`. The web UI is the base port + 1.
      basePort = 48989;
      webPort = basePort + 1;
      sunshine = pkgs.sunshine.override {
        cudaSupport = true;
        cudaPackages = pkgs.cudaPackages;
      };
      sunshineConfig =
        (pkgs.formats.keyValue { }).generate "sunshine.conf"
          config.services.sunshine.settings;
      output = pkgs.writeShellApplication {
        name = "sunshine-output";
        runtimeInputs = [
          config.programs.umbriel.package
          pkgs.jq
        ];
        text = builtins.readFile ../home/sunshine/output.sh;
      };
    in
    {
      config = lib.mkMerge [
        {
          # The web UI serves a self-signed certificate on the loopback hop.
          my.services.sunshine = {
            enable = lib.mkDefault config.my.streaming.sunshine.enable;
            port = webPort;
            publicName = "sunshine";
            proxy.https = true;
            proxy.tlsInsecure = true;
          };
        }
        (lib.mkIf config.my.streaming.sunshine.enable {
          environment.systemPackages = [ output ];

          services.sunshine = {
            enable = true;
            package = sunshine;
            openFirewall = true;
            # Compositor capture does not require the privileged KMS wrapper.
            capSysAdmin = false;
            settings = {
              sunshine_name = config.networking.hostName;
              port = basePort;
              capture = "wlr";
              # Intel Quick Sync while the RTX 4090 is passed through.
              encoder = if config.virtualisation.windowsGpuPassthrough.enable or false then "vaapi" else "nvenc";
              output_name = "sunshine";
              upnp = "disabled";
              origin_web_ui_allowed = "lan";
              csrf_allowed_origins = lib.concatStringsSep "," (
                lib.optional (
                  config.my.network.lanAddress != null
                ) "https://${config.my.network.lanAddress}:${toString webPort}"
                ++ [ "https://sunshine.${domain}" ]
              );
              global_prep_cmd = builtins.toJSON [
                {
                  do = "${output}/bin/sunshine-output create";
                  undo = "${output}/bin/sunshine-output remove";
                }
              ];
            };
            applications.apps = [
              { name = "Virtual Desktop"; }
              {
                name = "Steam Big Picture";
                detached = [ "${pkgs.steam}/bin/steam steam://open/bigpicture" ];
                prep-cmd = [
                  {
                    do = "";
                    undo = "${pkgs.steam}/bin/steam steam://close/bigpicture";
                  }
                ];
                image-path = "steam.png";
              }
            ];
          };

          # Sunshine requests CPU thread priority through RealtimeKit after dropping caps.
          security.rtkit.enable = true;

          # Grant scheduling priority to Sunshine without granting KMS/admin access.
          security.wrappers.sunshine = {
            owner = "root";
            group = "users";
            permissions = "u+rx,g+rx,o-rwx";
            capabilities = "cap_sys_nice+ep";
            source = "${sunshine}/bin/sunshine";
          };

          # Capture needs a live supported compositor and its Wayland socket.
          # FFmpeg loads CUDA/NVENC at runtime from the active host driver.
          systemd.user.services.sunshine.enable = config.services.sunshine.enable;
          systemd.user.services.sunshine.environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
          systemd.user.services.sunshine.serviceConfig = {
            ExecCondition = pkgs.writeShellScript "sunshine-session-ready" ''
              test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" || exit 1
              test -S "''${UMBRIEL_SOCKET:-$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock}"
            '';
            ExecStart = lib.mkForce "${config.security.wrapperDir}/sunshine ${sunshineConfig}";
            # Restore the physical outputs even when Sunshine exits mid-stream.
            ExecStopPost = "-${output}/bin/sunshine-output remove";
            UMask = "0077";
          };
        })
      ];
    };
}
