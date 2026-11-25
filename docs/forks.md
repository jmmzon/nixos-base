# Forked inputs

Umbriel, Noctalia, the Noctalia greeter and Strata come from public forks
(`github:question44/{umbriel,noctalia,noctalia-greeter,strata}`). Local changes are
commits on each fork's `erebor` branch, on top of the upstream revision; the
flake input pins a commit of that branch.

## Updating to a new upstream

```sh
git fetch upstream
git tag erebor-$(date +%F) erebor && git push fork erebor-$(date +%F)
git rebase --onto <new-upstream-rev> <old-upstream-rev> erebor
# build and test, then:
git push --force-with-lease fork erebor
nix flake update umbriel   # or noctalia, noctalia-greeter
```

Keep each change as its own commit (`local: <feature>` or a descriptive
subject) so a conflict points at one feature. Before every push, run
`gitleaks git --log-opts=<upstream-rev>..erebor` and check the new commits for
personal data, as for this repository. Rebasing rewrites the branch: before the
force push, tag the old head (`git tag erebor-<date> && git push fork
erebor-<date>`) so older lock files still fetch.

Strata's fork changes `Cargo.lock` and `package.nix`, which an
`overrideAttrs` patch cannot do (the vendored crates come from the unpatched
lock file). Its flake also pins Ghostty for the libghostty-vt build; that input
keeps its own nixpkgs and Zig, so it does not follow ours. In the Strata clone
the upstream remote is `origin`, not `upstream`.

A one-off patch on top can still go in `programs.noctalia.patches` or
`programs.noctalia.greeterPatches`.
