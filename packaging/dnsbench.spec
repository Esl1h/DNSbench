# Fedora Copr spec.
#
# V is not in Fedora, so the toolchain is fetched and built in %prep from a
# pinned commit. That is the one thing this package does that a Fedora reviewer
# would object to, and it is why this lives in Copr rather than in Fedora
# proper. The pin is what keeps the build reproducible.

%global vlang_commit cbf4e85
%global forgeurl     https://github.com/Esl1h/DNSbench

Name:           dnsbench
Version:        0.1.0
Release:        1%{?dist}
Summary:        Rank DNS resolvers from your own connection, including CDN edge quality

License:        MIT
URL:            %{forgeurl}
Source0:        %{forgeurl}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz
Source1:        https://github.com/vlang/v/archive/%{vlang_commit}.tar.gz#/vlang-%{vlang_commit}.tar.gz

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
%setup -q -T -D -a 1 -n DNSbench-%{version}

%build
make -C v-%{vlang_commit}
export PATH="$PWD/v-%{vlang_commit}:$PATH"
make build COMMIT="v%{version}"

%check
export PATH="$PWD/v-%{vlang_commit}:$PATH"
make test

%install
make install DESTDIR=%{buildroot} PREFIX=%{_prefix}

%files
%license LICENSE
%doc README.md CHANGELOG.md
%{_bindir}/dnsbench
%{_mandir}/man1/dnsbench.1*
%{_datadir}/bash-completion/completions/dnsbench
%{_datadir}/zsh/site-functions/_dnsbench
%{_datadir}/fish/vendor_completions.d/dnsbench.fish

%changelog
* Sat Aug 29 2026 Esli Silva <not.announced@simplelogin.fr> - 0.1.0-1
- First packaged release.
