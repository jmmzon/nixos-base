{
  description = "Shared NixOS, nix-darwin and Home Manager aspects for an Umbriel/Noctalia desktop";

  # Third-party inputs are pinned to a commit, so `nix flake update` moves only
  # nixpkgs and home-manager. Bump a pin deliberately: change its revision,
  # review the upstream changes, then build and compare the hosts that use it.
  inputs = {
    # The dashboard (jmmzon/erebor-dashboard), pinned to a commit.
    dashboard = {
      url = "github:jmmzon/erebor-dashboard/ce53307dbc189b6a7eca7130dd4ff4c795c1b694";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    moonshine = {
      url = "github:hgaiser/moonshine/f4b0ce559d29278062cebd65d171c74a7912f4a8";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    strata = {
      url = "github:jmmzon/strata/7899f338184f959792b0c85fb30d96ac8219b7ce";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    monstar.url = "github:rockorager/monstar/860f55d7000692e98a37b814d0eebc3575fede73";
    claude-desktop-nix.url = "github:tomsch/claude-desktop-nix/cec2c23d3f04accc5adeb93e94b02e4fd603510b";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    noctalia.url = "github:jmmzon/noctalia/4193c82eeede969c9e918b788a2eb7f676e33f1e";
    noctalia-greeter = {
      url = "github:jmmzon/noctalia-greeter/3f4ba2cccd89792878338353f884d890b8d34c04";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    umbriel.url = "github:jmmzon/umbriel/40cc240dbc511df6a6e65e5883f12d557f443ba8";
    millennium = {
      url = "github:SteamClientHomebrew/Millennium/6522c24e8bd3de41a7601ceb4e78a619930f1704?dir=packages/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:youwen5/zen-browser-flake/ddf9a4d974a43fdc32db8f766a137093d6822ff5";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    helium = {
      url = "github:oxcl/nix-flake-helium-browser/1230f02322b369aae7c0c560ccfc4235ca76546a";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darkly = {
      url = "github:Bali10050/Darkly/0058eb8c76f46c2704fa9e758b08e1206d871697";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Follows nixpkgs so Vicinae uses the system's Qt, not a second copy.
    vicinae = {
      url = "github:vicinaehq/vicinae/23fec1e1da14c422fba01db5c286589b6e946d06";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Vicinae's extension store (source only); the Bitwarden extension is
    # built from it in modules/vicinae.nix.
    vicinae-extensions = {
      url = "github:vicinaehq/extensions/fb1c595374f5190fe36591044a8092660cd793f5";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts/ea2630b7470978622c7689a1ff75d2b389175399";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix/11e5885d241743ff0193465d533b20e754bc3ce0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/ff0e21a414d4547183396da1b44a66f2577b65e9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree/eb1b52eaecc57f7c136d07ae8a93e724dfecac46";
    # Secure Boot: signed systemd-boot and unified kernel images (v1.2.0).
    lanzaboote = {
      url = "github:nix-community/lanzaboote/c1c5edd31802d181c8aa2c71588995d93425d650";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Dendritic layout: every .nix file under modules/ is a flake-parts module
  # (import-tree skips paths with a `_`-prefixed component). Files contribute
  # NixOS, Home Manager and nix-darwin aspects to
  # flake.modules.{nixos,homeManager,darwin}.*, exported as the `modules`
  # output; modules/hosts/template builds nixosConfigurations.template from them.
  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
