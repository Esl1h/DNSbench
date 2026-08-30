# Releasing

How a version of `dnsbench` is cut, what makes the result reproducible, and which
steps need an account and therefore cannot be done from a checkout.

Companion documents: `docs/ROADMAP.md` § M4 is the milestone this implements,
`docs/PLAN.md` § Where this stands is the current state.

## What a release is

One git tag, `vMAJOR.MINOR.PATCH`, and the artifacts built from it:

```
dnsbench-0.1.0-linux-amd64            the stripped binary
dnsbench-0.1.0-linux-amd64.tar.gz     binary, man page, completions, LICENSE, README, CHANGELOG
dnsbench-0.1.0-linux-arm64
dnsbench-0.1.0-linux-arm64.tar.gz
SHA256SUMS
```

Versioning is SemVer, with one rule of its own from `CHANGELOG.md`: a change to
the score is **semver-minor at minimum**, because people make decisions from that
number. A dataset ID bump, the Tranco list or the catalog version, gets its own
changelog entry, because it breaks historical comparability and `history` has to
be able to detect it.

## The procedure

1. **Bump the version in `v.mod`.** It is the single source: the Makefile reads
   it and passes it to the compiler, and `cmd/cli.v` carries the same string only
   as the default for a build made outside a checkout.
2. **Move `CHANGELOG.md`'s `[Unreleased]` section under the new version**, with
   the date.
3. **`make check`**, then commit both.
4. **Tag and push.** `git tag -s v0.1.0 -m 'dnsbench 0.1.0' && git push --tags`.
   The tag is signed, like every commit in this repository.
5. **`.github/workflows/release.yml` does the rest**: it builds each target
   natively, statically linked against musl, confirms the binary runs, and
   publishes the artifacts with one `SHA256SUMS` over all of them.

`make release` cuts the same artifacts for the host architecture alone. It
refuses on a dirty tree and refuses outside a git checkout, because an artifact
that cannot say which commit it came from is not a release.

## Reproducibility

Two builds of the same source, with the same compiler, at the same path, produce
byte-identical binaries. Verified:

```
$ v -prod -d version=0.1.0 -d commit=test -o /tmp/r1 cmd/
$ v -prod -d version=0.1.0 -d commit=test -o /tmp/r2 cmd/
$ sha256sum /tmp/r1 /tmp/r2
18df07a171d252b973d5991dc0d9bd5b6e36bcfeb2a83a3b5190bf5378955833  /tmp/r1
18df07a171d252b973d5991dc0d9bd5b6e36bcfeb2a83a3b5190bf5378955833  /tmp/r2
```

Three things make that hold, and each is a thing the release procedure has to
keep doing.

**The compiler is pinned.** `V_COMMIT` in the release workflow. V is not
API-stable and its generated C changes between commits; an unpinned toolchain
means an unreproducible artifact.

**The version and the commit are compile-time defines, not file edits.**
`-d version=` and `-d commit=`, read with `$d()`. Nothing in the source is
rewritten to make a release, so the tree at the tag is the tree that was built.

**The build path is fixed.** This is the one that is not obvious.
`$embed_file('data/providers.toml')` records the **absolute path** of the file it
embedded, so the same source built at two different paths produces two different
binaries. The difference is one string and it changes nothing the program does,
but it does change the checksum:

```
$ diff <(v -prod -o /tmp/a.c cmd/) ...
< string _str_918 = {"/home/esli/GIT/DNSbench/data/providers.toml", 43, 1};
> string _str_918 = {"/tmp/copy2/data/providers.toml", 30, 1};
```

The workflow therefore copies the checkout to `/build/dnsbench` and builds there,
so that anyone can reproduce a published binary by doing the same. See
`docs/V-NOTES.md` § $embed_file records an absolute path.

### Reproducing a published binary

```sh
git clone https://github.com/vlang/v /tmp/v && git -C /tmp/v checkout <V_COMMIT>
make -C /tmp/v
sudo mkdir -p /build && sudo git clone --branch v0.1.0 \
    https://github.com/Esl1h/DNSbench /build/dnsbench
sudo chown -R "$USER" /build/dnsbench
cd /build/dnsbench && PATH=/tmp/v:$PATH make release STATIC=1
sha256sum -c SHA256SUMS
```

`V_COMMIT` is in `.github/workflows/release.yml` at the tag being reproduced,
never the current one.

## Packaging

`packaging/` holds everything a distribution needs, and `make install` is what
each package calls:

| File | For |
|---|---|
| `packaging/dnsbench.1` | man page, section 1 |
| `packaging/completions/dnsbench.bash` | bash |
| `packaging/completions/dnsbench.zsh` | zsh, installed as `_dnsbench` |
| `packaging/completions/dnsbench.fish` | fish |
| `packaging/PKGBUILD` | AUR |
| `packaging/dnsbench.spec` | Fedora Copr |

`make install` honours `DESTDIR` and `PREFIX`, which is all a package build root
needs.

The completion files repeat the flag vocabularies rather than asking the binary
for them, because a completion that runs the binary on every Tab is a completion
that hangs when the binary is mid-upgrade. That means they have to be updated
when a flag is added; `dnsbench --help` is the list they must agree with.

## Steps that need an account

These cannot be done from a checkout and are listed so that a release is not
reported as finished when it is not:

- **The GitHub release** is created by the workflow, which needs the tag pushed.
- **AUR** needs an SSH key registered with `aur.archlinux.org` and a `.SRCINFO`
  regenerated with `makepkg --printsrcinfo > .SRCINFO` on an Arch machine. The
  `sha256sums` line in `PKGBUILD` is `SKIP` until there is a tarball to hash;
  replace it with the real checksum at the first release.
- **Fedora Copr** needs a FAS account and a project. The spec builds V from a
  pinned commit in `%prep`, which is why this lives in Copr rather than in Fedora
  proper: V is not packaged in Fedora.
- **VPM** needs an account on `vpm.vlang.io`. `v.mod` is already the manifest.

## Not yet done

**Signed release artifacts.** `docs/ROADMAP.md` § M4 asks for `dnsbench update`
with minisign verification. No signing key exists yet, so no artifact is signed
and there is nothing for an update command to verify. Creating the key is a
decision about key custody, not a coding task, and it blocks that item rather
than the rest of the release.

**Verification of the workflow itself.** Everything above that can be run from a
checkout has been: `make release`, `make install` into a staging root, the man
page through `groff -ww` and `man`, the bash completion through `shellcheck` and
by invoking it, the zsh completion by driving the completion system through a
pty. The workflow cannot run here. Its YAML parses and its steps mirror commands
that were run by hand, but the first tag is what verifies it, and the arm64
runner and the musl static link are both unproven until then.
