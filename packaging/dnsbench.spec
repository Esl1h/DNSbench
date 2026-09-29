# Fedora Copr spec.
#
# V is not in Fedora, so the toolchain is fetched and built in %prep from a
# pinned commit. That is the one thing this package does that a Fedora reviewer
# would object to, and it is why this lives in Copr rather than in Fedora
# proper. The pin is what keeps the build reproducible.

%global vlang_commit cbf4e8509630da710d04cc9fd0f777761ebe55a7
# The generated-C snapshot the pinned compiler is bootstrapped from, pinned for
# the reason .github/workflows/ci.yml gives: vc master no longer builds it.
%global vc_commit    9d047035b4c0e58e8649200fcf39f806a8d8b70c
# The tcc bundle the compiler uses for everything but -prod builds, as CI has
# it: tests compiled without it fail in ways CI never sees. Both architectures
# ride in the source RPM, since Copr rebuilds that one SRPM on each.
%global tccbin_x86_64  d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74
%global tccbin_aarch64 125ad2e1153c7cb86f19ac4aa070063d18504462
%global forgeurl     https://github.com/Esl1h/DNSbench
# V generates one C file per build in a temporary directory and removes it, so
# there are no sources for a debuginfo package to collect and rpmbuild stops
# on an empty debugsourcefiles.list.
%global debug_package %{nil}

Name:           dnsbench
Version:        0.2.1
Release:        1%{?dist}
Summary:        Rank DNS resolvers from your own connection, including CDN edge quality

License:        MIT
URL:            %{forgeurl}
Source0:        %{forgeurl}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz
Source1:        https://github.com/vlang/v/archive/%{vlang_commit}.tar.gz#/vlang-%{vlang_commit}.tar.gz
Source2:        https://github.com/vlang/vc/archive/%{vc_commit}.tar.gz#/vc-%{vc_commit}.tar.gz
Source3:        https://github.com/vlang/tccbin/archive/%{tccbin_x86_64}.tar.gz#/tccbin-%{tccbin_x86_64}.tar.gz
Source4:        https://github.com/vlang/tccbin/archive/%{tccbin_aarch64}.tar.gz#/tccbin-%{tccbin_aarch64}.tar.gz

ExclusiveArch:  x86_64 aarch64

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  glibc-devel
BuildRequires:  openssl-devel

%description
dnsbench measures and ranks DNS resolvers from the link it is run on, over UDP,
TCP, DNS over TLS and DNS over HTTPS. Besides lookup latency it measures CDN
edge quality: it resolves DNS-steered CDN hostnames through every resolver and
times a connection to whichever address came back, so a resolver that answers
quickly and sends you to an edge on another continent is visible as such.

It changes no system setting, carries no telemetry, and ships its provider
catalog and domain sets inside the binary.

%prep
%setup -q -n DNSbench-%{version}
# -b, not -a: the compiler is unpacked beside the source tree and not inside
# it, where `v test .` would find and run the compiler's own test suite.
%setup -q -T -D -b 1 -n DNSbench-%{version}
%setup -q -T -D -b 2 -n DNSbench-%{version}
mv ../v-%{vlang_commit} ../vlang
mv ../vc-%{vc_commit} ../vlang/vc
%ifarch aarch64
tar -xzf %{SOURCE4} -C ..
mv ../tccbin-%{tccbin_aarch64} ../tccbin
%else
tar -xzf %{SOURCE3} -C ..
mv ../tccbin-%{tccbin_x86_64} ../tccbin
%endif

# The compiler is bootstrapped by hand, as the release workflow does, and not
# with its own `make`: that pulls vc master, which no longer builds this pin,
# and a build root has neither git nor, on Copr, a network.
%build
# The compiler is built without the distribution's flags: V hands CFLAGS to
# the C compiler, and with -flto=auto compiling cmd/v went past 8 GiB where it
# otherwise peaks under 6 GiB. dnsbench itself is still built with them.
(
	unset CFLAGS CXXFLAGS LDFLAGS
	cd ../vlang
	cc -std=c99 -w -o v1 vc/v.c -lm -lpthread
	./v1 -no-parallel -o v2 -gc none cmd/v
	./v2 -nocache -o v -gc none cmd/v
	rm -f v1 v2
	# After the bootstrap, as the workflows install it.
	rm -rf thirdparty/tcc
	mv ../tccbin thirdparty/tcc
)
# On a C compile failure V would otherwise try to send a report to its bug
# tracker. docs/V-NOTES.md.
export V_C_ERROR_BUG_REPORT_DISABLED=1
export VMODULES="$PWD/../.vmodules"
export PATH="$PWD/../vlang:$PATH"
make build COMMIT="v%{version}"

%check
# v test compiles one test per CPU, about a gigabyte each; on a builder with
# more CPUs than memory that kills compilers mid-run. Two GiB per job, and none
# of the distribution's LTO flags, which the tests do not need.
%constrain_build -m 2048
export VJOBS=%{_smp_build_ncpus}
unset CFLAGS CXXFLAGS LDFLAGS
export V_C_ERROR_BUG_REPORT_DISABLED=1
export VMODULES="$PWD/../.vmodules"
export PATH="$PWD/../vlang:$PATH"
# VFLAGS emptied on the command line: the Makefile sets it to -prod and make
# exports that over any inherited value, and CI runs the tests without it.
make test VFLAGS=

# make install depends on the build target, which is phony and runs again, so
# it needs the compiler and the same stamp as %build.
%install
export V_C_ERROR_BUG_REPORT_DISABLED=1
export VMODULES="$PWD/../.vmodules"
export PATH="$PWD/../vlang:$PATH"
make install DESTDIR=%{buildroot} PREFIX=%{_prefix} COMMIT="v%{version}"

%files
%license LICENSE
%doc README.md docs/CHANGELOG.md
%{_bindir}/dnsbench
%{_mandir}/man1/dnsbench.1*
%{_datadir}/bash-completion/completions/dnsbench
%{_datadir}/zsh/site-functions/_dnsbench
%{_datadir}/fish/vendor_completions.d/dnsbench.fish

%changelog
* Mon Sep 28 2026 Esli Silva <not.announced@simplelogin.fr> - 0.2.1-1
- Bootstrap the pinned compiler offline from pinned V, vc and tccbin sources.
* Sun Sep 27 2026 Esli Silva <not.announced@simplelogin.fr> - 0.2.0-1
- Update to 0.2.0.
* Sat Aug 29 2026 Esli Silva <not.announced@simplelogin.fr> - 0.1.0-1
- First packaged release.
