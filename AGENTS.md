# Instructions for agents working on nixos-base

This is a public flake of shared NixOS, Home Manager and nix-darwin aspects.
Other flakes consume it and build real machines from it; nothing here is
deployed directly. [README.md](README.md) is the overview.

## Rules that always apply

- No personal data in this repository: no real user names, domains, IP or
  MAC addresses, host or device names, hardware serials or IDs, email
  addresses, tokens or keys, and no links to private repositories or private
  task trackers. Use generic examples (`alice`, `myhost.example.com`,
  `enp1s0`). A value only one machine needs is a `my.*` option with a
  generic default, set by the consuming flake.
- Secrets never enter this repository, encrypted or not. A module that needs
  one declares `sops.secrets.<name>` and reads it from the host's
  `my.secretsFile`.
- Read the relevant Nix files before editing. Keep changes small and
  declarative.
- Run `nix fmt` before committing (nixfmt, RFC 166 style) and
  `nix flake check` before declaring a change done; the check fails on
  unformatted files and on a stale `docs/my-options.md`.
- Before publishing, scan the tree for secrets (for example
  `nix run nixpkgs#gitleaks -- dir .`) and for personal data.

## Layout

- Dendritic pattern: `flake.nix` loads every `.nix` file under `modules/`
  with import-tree as a flake-parts module. Each file adds aspects:
  `flake.modules.nixos.<name>`, `flake.modules.homeManager.<name>` or
  `flake.modules.darwin.<name>`. A feature that spans NixOS and Home Manager
  keeps both halves in one file. The flake exports them as
  `modules.{nixos,homeManager,darwin}`.
- Paths with a `_`-prefixed component (`_hardware-configuration.nix`,
  `_live-file.nix`) are not loaded as flake-parts modules; use that for
  helpers imported by hand.
- Flake inputs reach modules by closure (`{ inputs, ... }:` around the
  aspect); do not add `specialArgs`.
- `modules/workstation/default.nix` is the `workstation` aspect, which
  imports every shared NixOS aspect: add a new shared aspect there.
  `modules/home/workstation.nix` is the user's Home Manager profile
  (`homeManager.workstation`): add new Home Manager aspects to its imports.
  Hardware-specific aspects (`nvidia`, `xremap`, `looking-glass`) are
  imported per host instead.
- `modules/hosts/template/` is the starting point for a new machine. It is
  evaluated by `nix flake check` and never deployed; it proves that optional
  features switch off.
- `home/` holds the dotfiles the aspects deploy. Files linked live through
  `my.flakePath` (`_live-file.nix`) must work as store copies too.

## The `my.*` options

- `modules/my.nix` declares the per-machine settings (user, domain, LAN
  interface, feature toggles). Shared modules read `config.my.*`; never
  hard-code a machine's values in them.
- Features are switched by `my.*` toggles that default to off, not by which
  aspects a host imports. A feature that needs a value or a file the host
  must provide asserts it, with a message naming the option.
- After adding or changing an option, run `nix run .#write-docs` and commit
  `docs/my-options.md`.
- Some identifiers keep an `erebor-` prefix (`erebor-modes`, …); keep them
  as they are unless the change is a deliberate rename with a migration.

## Architectures

- The template must evaluate on `aarch64-linux` as well as `x86_64-linux`
  (`eval-template-aarch64`). Keep x86-only packages and settings behind
  `pkgs.stdenv.hostPlatform.isx86_64`, and take flake input packages by
  `pkgs.stdenv.hostPlatform.system`, never a literal `x86_64-linux`.
- The darwin profile reuses the cross-platform Home Manager aspects
  (`shell`, `nvim`, `ghostty`); keep Linux-only parts of a shared aspect
  behind `pkgs.stdenv.hostPlatform.isLinux`.

## Module order

Module order is breadth-first by import depth, so moving a definition into
another aspect, or adding a level of nesting, can reorder list options
(packages, overlays, kernel parameters, graphics drivers) and change the
built system. When moving code between aspects, compare a consuming host's
system before and after (same derivation, or explain the difference).

## Design boundaries

- Umbriel is the only session, started by the Noctalia greeter; Noctalia
  runs as a systemd user service on `graphical-session.target`. Oo7 is the
  Secret Service; GNOME Keyring and KWallet stay off. The eval tests in
  `modules/flake/tests.nix` enforce these rules; extend them when adding a
  rule.
- Keep the flake lock committed. Third-party inputs are pinned to a commit:
  bump one deliberately, review the upstream changes, then build a host that
  uses it.
