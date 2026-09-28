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

Versioning is SemVer, with one rule of its own from `docs/CHANGELOG.md`: a change to
the score is **semver-minor at minimum**, because people make decisions from that
number. A dataset ID bump, the Tranco list or the catalog version, gets its own
changelog entry, because it breaks historical comparability and `history` has to
be able to detect it.

## The procedure

1. **Bump the version in `v.mod`.** It is the single source: the Makefile reads
   it and passes it to the compiler, and `cmd/cli.v` carries the same string only
   as the default for a build made outside a checkout.
2. **Move `docs/CHANGELOG.md`'s `[Unreleased]` section under the new version**, with
   the date.
3. **`make check`**, then commit both.
4. **Rehearse.** `git push origin HEAD:release-check --force` runs the release
   workflow's builds on both architectures without publishing anything; see
   § Rehearsing.
5. **Tag and push.** `git tag -s v0.1.0 -m 'dnsbench 0.1.0' && git push --tags`.
   The tag is signed, like every commit in this repository.
6. **`.github/workflows/release.yml` does the rest**: it builds each target
   natively, statically linked against musl, confirms the binary runs, and
   publishes the artifacts with one `SHA256SUMS` over all of them.

### Rehearsing

A tag is public the moment it is pushed, and the arm64 job runs nowhere else, so
the first sign of an arm64-only break used to be a failed release. Pushing to the
`release-check` branch runs the same `build` job for both targets, static-link
check and `--version` included; the `publish` job runs only for a tag. The
branch carries no meaning between rehearsals and can be force-pushed.

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

**So is the bootstrap snapshot.** `v1` is built from the generated C in
`vlang/vc`, whose master moves far faster than any V pin does, and a newer
snapshot can both emit calls to builtins the pinned V tree lacks and need
more memory compiling `cmd/v` than the pinned compiler permits (v0.1.0's
first failed CI run of 2026-09-26 was exactly this: fresh vc + cbf4e85).
`VC_COMMIT` in the workflows pins it too; find the one to pin by looking for
the `"[v:master] <sha>"` label in the vc log nearest, but not newer, to
`V_COMMIT`. The workflows bootstrap V by hand instead of `make -C /tmp/v`,
because the GNUmakefile `latest_vc` target unconditionally pulls vc master.
`make -C /tmp/v local=1`, which skips that pull, was tried and is worse: it
skips the tcc download too, then runs `cmd/tools/detect_tcc.v`, whose C
compile fails without tcc, and V answers that failure by trying to send a
bug report to bugs.vlang.io, which fails and reports itself in turn.

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
git clone https://github.com/vlang/vc /tmp/v/vc && git -C /tmp/v/vc checkout <VC_COMMIT>
cd /tmp/v
cc -std=c99 -w -o /tmp/v/v1 /tmp/v/vc/v.c -lm -lpthread
/tmp/v/v1 -no-parallel -o /tmp/v/v2 -gc none cmd/v
/tmp/v/v2 -nocache -o /tmp/v/v -gc none cmd/v
tmarch=amd64; [ "$(uname -m)" = aarch64 ] && tmarch=arm64
bash /tmp/v/cmd/tools/select_linux_tcc.sh fresh /tmp/v/thirdparty/tcc \
    https://github.com/vlang/tccbin "$tmarch" /tmp/v
sudo mkdir -p /build && sudo git clone --branch v0.1.0 \
    https://github.com/Esl1h/DNSbench /build/dnsbench
sudo chown -R "$USER" /build/dnsbench
cd /build/dnsbench && PATH=/tmp/v:$PATH make release STATIC=1
sha256sum -c SHA256SUMS
```

`V_COMMIT` is in `.github/workflows/release.yml` at the tag being reproduced,
never the current one. So is `VC_COMMIT`, for every tag cut after the vc pin
was added. A tag older than that, v0.1.0 included, has no `VC_COMMIT` in its
workflow: use `9d047035`, the snapshot verified to bootstrap its `cbf4e85`.

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

**The Copr spec cannot build the pinned compiler.** `packaging/dnsbench.spec`'s
`%build` runs `make -C v-<commit>`, the bootstrap `.github/workflows` stopped
using: its `latest_vc` target clones vc master, which no longer builds
`cbf4e85`, a source tarball has no git for it to work with, Copr builds
offline by default, and the link needs `thirdparty/tcc/lib/libgc.a`, which only
the tcc download provides. The fix is the workflows' hand bootstrap with vc
and tccbin as pinned `Source` tarballs, and it has not been written because it
has not been tested: that needs `rpmbuild` or `mock`. Until then Copr is the
one channel a release does not reach. The AUR `PKGBUILD` builds with the
distribution's own `vlang` and is unaffected.

**Signed release artifacts.** Nothing published here is signed. That is a
separate question from `dnsbench update`, which verifies **DNSCrypt's** catalog
against **DNSCrypt's** published key and needs no key of ours; that is built and
`catalog/minisign.v` is the verifier. Signing our own artifacts would need a key
and a decision about where it lives, and is not on the milestone list. The
verifier would be reusable for it if that decision is ever taken.

**Verification of the workflow itself.** `v0.1.0` was the first tag, and it did
not pass on the first attempt: the pinned compiler, `cbf4e85`, truncates
`int * time.Duration` to 32 bits before widening it, a bug `store/history.v`'s
`parse_duration` hit on every unit and `cmd/cli.v`'s `--timeout` hit above
roughly 2147 ms, invisible against a newer unpinned V and caught only once
`make check` actually ran under the pinned one; `release.yml` never installed
`check-jsonschema`, unlike `ci.yml`; and the static, musl-linked build failed
at the link step, `undefined reference to getcontext`, from the default
Boehm GC's stack-scanning code, which Ubuntu's `musl-tools` does not provide
for static linking, fixed by dropping the GC for `STATIC=1` builds only,
`-gc none`, safe because `dnsbench` is a short-lived CLI process. All three
are fixed and the tag that carries the fixes is the one that published.
The arm64 runner and the musl static link are proven now, not unproven.
