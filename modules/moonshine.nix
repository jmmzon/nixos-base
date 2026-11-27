# The Moonshine game-streaming server (my.streaming.moonshine).
{ inputs, ... }:
{
  flake.modules.nixos.moonshine = {
    imports = [
      inputs.moonshine.nixosModules.default
      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          user = config.my.user.name;
        in
        {
          # Off while the RTX 4090 is passed through: there is nothing to stream
          # games with, and the guest runs its own streaming server.
          config =
            lib.mkIf
              (
                config.my.streaming.moonshine.enable
                && !(config.virtualisation.windowsGpuPassthrough.enable or false)
              )
              {
                users.users.${user}.extraGroups = [ "moonshine" ];
                services.moonshine = {
                  enable = true;
                  user = "${user}";
                  uid = 1000;
                  openFirewall = true;
                  settings = {
                    name = "Erebor Moonshine";
                    # The control panel (port 47990) has no password: any local
                    # process, a streamed session's browser included, could pair a
                    # device or add an application that runs a command as the user.
                    # Its edits to config.toml cannot be saved here (the file is in
                    # the store), and pairing works without it.
                    ui.enabled = false;
                    application = [
                      {
                        title = "Steam Big Picture";
                        steam_integration = true;
                        command = [
                          "${pkgs.steam}/bin/steam"
                          "steam://open/bigpicture"
                        ];
                      }
                    ];
                  };
                };
              };
        }
      )
    ];
  };
}
