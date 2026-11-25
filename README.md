# nixos-base

Shared NixOS, Home Manager and nix-darwin modules for a Wayland desktop built
around the [Umbriel](https://github.com/noctalia-dev/umbriel) compositor and
the [Noctalia](https://github.com/noctalia-dev/noctalia-shell) shell, with
"liquid glass" effects throughout. The modules are written in the
[dendritic pattern](https://github.com/mightyiam/dendritic): every file is a
[flake-parts](https://flake.parts) module that adds *aspects*. Another flake
takes this one as an input, imports the aspects and sets a handful of `my.*`
options for its machines.

This is a personal configuration, shared as-is. It changes whenever its
owner's desktop changes. There are no releases, no stability guarantees and
no support. Pin a revision, and read the diff before you bump it.

## What is in it

The desktop:

- **Umbriel** as the default session, started by the Noctalia greeter. It is
  patched with a backdrop effect (liquid glass under windows), per-effect
  shader parameters, an `umbriel_glass_v1` protocol that lets apps declare
  glass regions, touchpad gestures (3-finger drag, 4-finger swipe and
  pinch), and a scroll acceleration curve.
- **Noctalia** shell, greeter and lock screen, patched with liquid glass
  under the lock screen and greeter panels, YubiKey-touch unlock, an idle dim
  and pixel shift for the bar (OLED care), screenshots on HDR outputs, and two
  live wallpaper kinds: `shader:` (Shadertoy-style GLSL, optional KDE shader
  library) and `sequoia:` (needs a scene file you supply).
- A Plymouth → greeter handoff without a black gap, and kmscon on the text
  consoles.
- Desktop modes: power-saver (dims the screen over DDC, lowers the ambient
  light and GPU power limit) and reduce-transparency, plus app opacity that
  follows Noctalia's light/dark mode.
- Apps and theming: the Vicinae launcher, Ghostty, the Zen and Helium
  (ungoogled Chromium) browsers, Zed, Neovim (LazyVim), Fish, the Darkly Qt
  style, the Strata file manager, Steam with the Millennium theme, Spotify
  with Spicetify, and Oo7 as the Secret Service (no GNOME Keyring or
  KWallet).

Optional features, all off by default:

- Security keys: YubiKey touch notifications, lock on unplug, and approving
  sudo from a Mac or from a phone passkey (over KDE Connect).
- Hardware: NVIDIA, Looking Glass for a Windows VM, xremap key remapping,
  HyperHDR ambient lighting, a PipeWire headphone EQ.
- Web services behind Caddy on subdomains of `my.network.domain` (optionally
  with a wildcard certificate over OVH DNS): Jellyfin, Nextcloud, Syncthing,
  qBittorrent (optionally only through Proton VPN), Ollama with Open WebUI
  and SearXNG, T3 Code, Cockpit, and a dashboard.
- Game streaming (Sunshine, Moonshine), xrdp remote desktop, a Time Machine
  target for Macs over Samba.
- sops-nix secrets (`my.secretsFile`) and a weekly update-branch timer.

The Mac gets a small nix-darwin profile; see [Darwin](#darwin).

## Layout

| Path | Contents |
|---|---|
| `flake.nix` | The inputs (most pinned to a commit) and the flake-parts entry point; [import-tree](https://github.com/vic/import-tree) loads every `.nix` file under `modules/`. |
| `modules/my.nix` | The `my.*` options: per-machine values and feature toggles. |
| `modules/workstation/` | The `workstation` aspect, which imports every shared NixOS aspect, and the base settings (session, packages, Caddy, SSH, keyring). |
| `modules/home/` | Home Manager aspects; `workstation.nix` is the user's profile. |
| `modules/services/` | Web services, one file each. |
| `modules/darwin/` | nix-darwin aspects. |
| `modules/hosts/template/` | A template host, evaluated by `nix flake check` and never deployed. |
| `modules/flake/` | Checks, the formatter and the options doc generator. |
| `home/` | Dotfiles the aspects deploy. |
| `packages/`, `patches/` | Custom packages and patches for upstream software. |
| `docs/my-options.md` | Reference for every `my.*` option (generated). |

A file sets `flake.modules.nixos.<name>`, `flake.modules.homeManager.<name>`
or `flake.modules.darwin.<name>`, and a feature that has both a NixOS and a
Home Manager half keeps both in one file. Paths with a `_`-prefixed component
are not loaded as modules. The flake exports the aspects as
`modules.{nixos,homeManager,darwin}`.

## Using it from your flake

Copy `modules/hosts/template/` into your flake as a starting point. A minimal
consumer, in the same dendritic layout:

```nix
# flake.nix
{
  inputs = {
    nixos-base.url = "github:jmmzon/nixos-base";
    # Follow the base's pins, so you build what its checks evaluate.
    nixpkgs.follows = "nixos-base/nixpkgs";
    flake-parts.follows = "nixos-base/flake-parts";
    import-tree.follows = "nixos-base/import-tree";
    nix-darwin.follows = "nixos-base/nix-darwin"; # only for a Mac
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
```

```nix
# modules/parts.nix
{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
  systems = [ "x86_64-linux" ];
}
```

```nix
# modules/hosts/myhost/default.nix
{ config, inputs, ... }:
let
  # The base's aspects, plus any this flake defines.
  nixos = inputs.nixos-base.modules.nixos // config.flake.modules.nixos;
in
{
  flake.nixosConfigurations.myhost = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.myhost ];
  };

  flake.modules.nixos.myhost = {
    imports = with nixos; [
      ./_hardware-configuration.nix # from nixos-generate-config
      workstation
      # Hardware-specific aspects, imported per host:
      # nvidia
      # xremap         # set my.xremap.devices
      # looking-glass
    ];

    networking.hostName = "myhost";

    my = {
      # Required:
      user = {
        name = "alice";
        description = "Alice";
      };
      network = {
        domain = "myhost.example.com";
        lanInterface = "enp1s0";
      };
      # Everything else is off until you turn it on.
      liquidGlass.enable = true;
      # services.jellyfin.enable = true;
    };

    # Your own Home Manager settings merge into the base's profile.
    home-manager.users.alice = {
      programs.git.enable = true;
    };

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    system.stateVersion = "26.05";
  };
}
```

Notes:

- `workstation` imports every shared aspect, Home Manager included: it sets
  `home-manager.users.<my.user.name>` to the `homeManager.workstation`
  profile, so you do not import that profile yourself. Features are switched
  by `my.*` options, not by which aspects you import. Only the
  hardware-specific aspects above are imported per host.
- Take the aspects from `inputs.nixos-base.modules` directly. Merging them
  into your own `flake.modules` adds a level of module nesting, which changes
  the order of list options (kernel parameters, packages).
- You do not need the dendritic layout. A plain flake can pass
  `inputs.nixos-base.modules.nixos.workstation` and a module that sets `my`
  to `nixpkgs.lib.nixosSystem`.
- The `packages` aspect allows a fixed list of unfree packages (NVIDIA,
  CUDA, Steam, Discord, Spotify, …) through
  `nixpkgs.config.allowUnfreePredicate`.

## The `my.*` options

[docs/my-options.md](docs/my-options.md) lists every option with its type,
default and description. It is generated from `modules/my.nix` and the
modules that declare options; `nix flake check` fails when it is stale. Only
`my.user.name`, `my.network.domain` and `my.network.lanInterface` have no
default. Options that point at a file of yours (secrets, a keymap, a
script) default to null or to a generic copy in `home/`; a feature that needs
such a file fails with an assertion naming the option until it is set.

## Live dotfiles: `my.flakePath`

Some configs are meant to be edited often: Umbriel's `config.toml` and
`glass.toml`, Noctalia's `config.toml` and the Zed keymap.

- `my.flakePath = null` (the default): Home Manager links the copies from
  this flake's `home/` in the Nix store. They work out of the box, and every
  edit needs a rebuild.
- `my.flakePath = "/path/to/your/checkout"`: Home Manager points those files
  at `<flakePath>/home/...` with out-of-store symlinks, so saving a file there
  applies it without a rebuild. Your checkout must then contain them at the
  same paths as here (`home/umbriel/config.toml`, …). Copy them from this
  repository as a starting point.

`my.taskBoard` and `my.updateBranch` read the checkout, so they need
`my.flakePath` set, and the script they run comes from your flake.

## Architectures

Linux is built and checked for `x86_64-linux`. The shared desktop also
evaluates on `aarch64-linux` (a check proves the template does), with these
parts left out there: Steam, Discord, the Claude desktop app, Intel graphics
and 32-bit graphics. The `nvidia` and `looking-glass` aspects are meant for
x86 machines. On aarch64 some flake inputs may ship a wrong hash for their
arm64 download (Helium has); override the package on that host. For a VMware
guest, `my.vmwgfxDmabufFix` patches wlroots so the compositors accept GPU
buffers.

## Darwin

`modules.darwin.base` is a small nix-darwin profile: system defaults, Touch ID
for sudo, a Nerd Font, Homebrew (never removes unlisted apps), and Home
Manager with `homeManager.mac` (the cross-platform `shell`, `nvim` and
`ghostty` aspects). It expects Determinate Nix, so it sets `nix.enable =
false`.

```nix
flake.darwinConfigurations.mymac = inputs.nix-darwin.lib.darwinSystem {
  modules = [
    inputs.nixos-base.modules.darwin.base
    {
      nixpkgs.hostPlatform = "aarch64-darwin";
      system.primaryUser = "alice";
      homebrew.casks = [ "ghostty" ];
      system.stateVersion = 7;
    }
  ];
};
```

## Checks and formatting

```bash
nix flake check          # eval tests on the template (x86_64 and aarch64), the format check, docs freshness
nix fmt                  # nixfmt (RFC 166 style) on every tracked .nix file
nix run .#write-docs     # regenerate docs/my-options.md after changing an option
```

The eval tests in `modules/flake/tests.nix` check the design rules against
the template: Umbriel is the only session, Oo7 is the
Secret Service, every optional feature is off by default, and so on.
`scripts/tests/` has a VM test that needs KVM and is not part of
`nix flake check`.

## License

MIT, see [LICENSE](LICENSE). The files under `patches/` modify other
projects and remain under those projects' licenses.
