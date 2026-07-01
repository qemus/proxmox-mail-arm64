#!/bin/bash
#
# Build script for Proxmox Mail Gateway on ARM64
# https://github.com/qemus/proxmox-mail-arm64

set -eu

function git_clone_or_fetch() {
	url=${1}
	name_git=${url##*/}
	name=${name_git%.git}

	if [ ! -d "${name}" ]; then
		git clone "${url}"
	else
		git -C "${name}" fetch --all --tags
	fi
}

function git_clean_and_checkout() {
	commit_id=${1}
	path=${2}

	path_args=()
	if [[ "${path}" != "" ]]; then
		path_args=("-C" "${path}")
	fi

	git "${path_args[@]}" clean -ffdx
	git "${path_args[@]}" reset --hard
	git "${path_args[@]}" checkout "${commit_id}"
}

function git_checkout_version() {
	path=${1}
	version=${2}

	ref="$(
		git -C "${path}" for-each-ref --format='%(refname:short)' refs/tags |
			while read -r tag; do
				if git -C "${path}" show "${tag}:debian/changelog" >/dev/null 2>&1; then
					tag_version="$(
						git -C "${path}" show "${tag}:debian/changelog" |
							dpkg-parsechangelog -l- -SVersion 2>/dev/null || true
					)"

					if [ "${tag_version}" = "${version}" ]; then
						echo "${tag}"
						break
					fi
				fi
			done
	)"

	if [ -z "${ref}" ]; then
		ref="$(
			git -C "${path}" log --format='%H' -- debian/changelog |
				while read -r commit; do
					commit_version="$(
						git -C "${path}" show "${commit}:debian/changelog" |
							dpkg-parsechangelog -l- -SVersion 2>/dev/null || true
					)"

					if [ "${commit_version}" = "${version}" ]; then
						echo "${commit}"
						break
					fi
				done
		)"
	fi

	if [ -z "${ref}" ]; then
		echo "Could not find Git ref for ${path} version ${version}" >&2
		return 1
	fi

	git_clean_and_checkout "${ref}" "${path}"
}

function set_package_info() {
	if [ "${GITHUB_ACTION}" ]; then
		sed -i "s#^Maintainer:.*#Maintainer: Github Action <no-reply@github.com>#" debian/control
		sed -i "s#^Homepage:.*#Homepage: https://github.com/qemus/proxmox-mail-arm64#" debian/control
	else
		sed -i '\#^Origin: https://github.com/qemus/proxmox-mail-arm64$#d' debian/control
		sed -i "s#^\(Maintainer.*\)\$#\1\nOrigin: https://github.com/qemus/proxmox-mail-arm64#" debian/control
	fi
}

function load_packages() {
	url=${1}

	curl -sSf -H 'Cache-Control: no-cache' "${url}" |
		gzip -dc |
		awk -F": " '
			/^(Package|Version|Architecture|Filename)/ {
				if ($1 == "Package") {
					package=$2
					version=""
					arch=""
					filename=""
				} else if ($1 == "Version") {
					version=$2
				} else if ($1 == "Architecture") {
					arch=$2
				} else if ($1 == "Filename") {
					filename=$2
					print package ";" version ";" arch ";" filename
				}
			}
		'
}

function select_package() {
	package_name=${1}
	arch_filter=${2:-}
	version_operator=${3:-}
	version_filter=${4:-}

	version_target="0"
	file_target=""

	while IFS=';' read -r name version arch file; do
		[ "${name}" = "${package_name}" ] || continue

		if [ -n "${arch_filter}" ] && [ "${arch}" != "${arch_filter}" ]; then
			continue
		fi

		if [ -n "${version_operator}" ] && [ -n "${version_filter}" ]; then
			dpkg --compare-versions "${version}" "${version_operator}" "${version_filter}" || continue
		fi

		if dpkg --compare-versions "${version}" ">>" "${version_target}"; then
			version_target=${version}
			file_target=${file}
		fi
	done <<<"${PACKAGES_PMG}"

	if [ -n "${file_target}" ]; then
		echo "http://download.proxmox.com/debian/pmg/${file_target}"
	fi
}

function package_version() {
	package_name=${1}
	arch_filter=${2:-}
	version_operator=${3:-}
	version_filter=${4:-}

	url=$(select_package "${package_name}" "${arch_filter}" "${version_operator}" "${version_filter}")
	file=${url##*/}

	echo "${file}" |
		sed -E "s/^${package_name}_([^_]+)_.*/\1/"
}

function download_package() {
	package=${1}
	arch_filter=${2:-all}
	dest=${3:-${PACKAGES}}
	version_operator=${4:-}
	version_filter=${5:-}

	url=$(select_package "${package}" "${arch_filter}" "${version_operator}" "${version_filter}")

	if [ -z "${url}" ]; then
		echo "Error: package ${package} with architecture ${arch_filter} not found" >&2
		return 1
	fi

	file="${dest}/${url##*/}"

	if [ -e "${file}" ]; then
		echo "${package} up-to-date"
		return 0
	fi

	echo "${package} downloading... ${url}"
	curl -sSfL "${url}" -o "${file}"
}

function get_dependency_constraint() {
	deb=${1}
	dependency=${2}

	dpkg-deb -f "${deb}" Depends |
		tr ',' '\n' |
		sed 's/^ *//' |
		awk -v dep="${dependency}" '
			$1 == dep {
				operator=$2
				version=$3
				gsub(/[()]/, "", operator)
				gsub(/[()]/, "", version)
				print operator ";" version
				exit
			}
		'
}

function dependency_operator() {
	constraint=${1}

	if [ -n "${constraint}" ]; then
		echo "${constraint%;*}"
	fi
}

function dependency_version() {
	constraint=${1}

	if [ -n "${constraint}" ]; then
		echo "${constraint#*;}"
	fi
}

function download_dependency_package() {
	meta_deb=${1}
	package=${2}
	arch=${3:-all}

	constraint=$(get_dependency_constraint "${meta_deb}" "${package}" || true)
	operator=$(dependency_operator "${constraint}")
	version=$(dependency_version "${constraint}")

	if [ -n "${operator}" ] && [ -n "${version}" ]; then
		download_package "${package}" "${arch}" "${PACKAGES}" "${operator}" "${version}"
	else
		download_package "${package}" "${arch}" "${PACKAGES}"
	fi
}

function prepare_pmg_log_tracker() {
	git_clone_or_fetch https://git.proxmox.com/git/proxmox.git

	sed -i '/librust-/d' debian/control

	mkdir -p debian
	echo "git clone https://git.proxmox.com/git/pmg-log-tracker.git" > debian/SOURCE
	echo "git checkout $(git rev-parse HEAD)" >> debian/SOURCE

	rm -f .cargo/config .cargo/config.toml

	mkdir -p .cargo
	cat > .cargo/config.toml <<'EOF_CARGO_CONFIG'
[source.crates-io]
registry = "https://github.com/rust-lang/crates.io-index"
EOF_CARGO_CONFIG

	PROXMOX_TIME_PATH="$(find ./proxmox -maxdepth 4 -path '*/proxmox-time/Cargo.toml' -print -quit)"
	PROXMOX_TIME_PATH="${PROXMOX_TIME_PATH%/Cargo.toml}"

	if [ -z "${PROXMOX_TIME_PATH}" ]; then
		echo "Could not find proxmox-time Cargo.toml" >&2
		exit 1
	fi

	if ! grep -q '^\[patch.crates-io\]' Cargo.toml; then
		cat >> Cargo.toml <<EOF_PATCH

[patch.crates-io]
proxmox-time = { path = "${PROXMOX_TIME_PATH}" }
EOF_PATCH
	elif ! grep -q '^proxmox-time[[:space:]]*=' Cargo.toml; then
		cat >> Cargo.toml <<EOF_PATCH
proxmox-time = { path = "${PROXMOX_TIME_PATH}" }
EOF_PATCH
	fi

	cat > debian/rules <<'EOF_RULES'
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_build:
	cargo build --release

override_dh_auto_install:
	install -Dm755 target/release/pmg-log-tracker debian/pmg-log-tracker/usr/bin/pmg-log-tracker
EOF_RULES

	chmod +x debian/rules

	if command -v rustup >/dev/null 2>&1; then
		export PATH="$HOME/.cargo/bin:$PATH"

		if [ -f rust-toolchain.toml ] || [ -f rust-toolchain ]; then
			rustup show >/dev/null
		else
			echo "No rust-toolchain file found, using default rustup toolchain"
			export RUSTUP_TOOLCHAIN=stable
			rustup default stable
		fi
	fi
}

function prepare_proxmox_spamassassin() {
	sed -i "s/_amd64\.deb/_${PACKAGE_ARCH}.deb/g" Makefile
	sed -i "s/_amd64\.changes/_${PACKAGE_ARCH}.changes/g" Makefile
	sed -i "s/_amd64\.buildinfo/_${PACKAGE_ARCH}.buildinfo/g" Makefile
}

function prepare_package() {
	repo_name=${1}

	case "${repo_name}" in
		pmg-log-tracker)
			prepare_pmg_log_tracker
			;;

		proxmox-spamassassin)
			prepare_proxmox_spamassassin
			;;
	esac
}

function build_make_deb_package() {
	repo_url=${1}
	repo_name=${2}
	version=${3}

	if compgen -G "${PACKAGES}/${repo_name}_${version}_*.deb" >/dev/null; then
		echo "${repo_name} up-to-date"
		return 0
	fi

	git_clone_or_fetch "${repo_url}"
	git_checkout_version "${repo_name}" "${version}"

	cd "${repo_name}"

	set_package_info
	prepare_package "${repo_name}"

	${SUDO} apt-get -y build-dep ${BUILD_PROFILES} .

	make deb

	mv -f ./*.deb "${PACKAGES}/"

	cd ..
}

function build_dpkg_package() {
	repo_url=${1}
	repo_name=${2}
	version=${3}

	if compgen -G "${PACKAGES}/${repo_name}_${version}_${PACKAGE_ARCH}.deb" >/dev/null; then
		echo "${repo_name} up-to-date"
		return 0
	fi

	git_clone_or_fetch "${repo_url}"
	git_checkout_version "${repo_name}" "${version}"

	cd "${repo_name}"

	set_package_info
	prepare_package "${repo_name}"

	${SUDO} apt-get -y build-dep ${BUILD_PROFILES} .

	dpkg-buildpackage -b -us -uc ${BUILD_PROFILES}

	cd ..

	mv -f ./*.deb "${PACKAGES}/"
}

function is_container() {
	[ -f /.dockerenv ] ||
	[ -f /run/.containerenv ] ||
	[ -e /dev/.buildkit_qemu_emulator ] ||
	grep -qaE '(docker|containerd|kubepods|libpod|buildkit)' /proc/1/cgroup 2>/dev/null
}

file_list=()
function download_release() {
	version=${1:-latest}
	release_url="https://api.github.com/repos/qemus/proxmox-mail-arm64/releases/${version}"

	echo "Downloading ${version} released files to ${PACKAGES}"

	mapfile -t download_urls < <(
		curl -sSfL "${release_url}" |
			jq -r '
				.assets[]
				| select(.name | test("static|dbgsym") | not)
				| .browser_download_url
			'
	)

	if [ "${#download_urls[@]}" -eq 0 ]; then
		echo "Error: no release assets found for ${version}" >&2
		return 1
	fi

	for download_url in "${download_urls[@]}"; do
		file=$(basename "${download_url}")

		if [ -e "${PACKAGES}/${file}" ]; then
			echo "${file} already exists"
		else
			echo "Downloading ${file}"
			curl -sSfL "${download_url}" -o "${PACKAGES}/${file}"
		fi

		[[ "$file" == *"dbgsym"* ]] && rm "${PACKAGES}/${file}" && continue

		file_list+=("${PACKAGES}/${file}")
	done
}

function install_server() {
    if [ "${#file_list[@]}" -eq 0 ]; then
        echo "Error: no files found to install" >&2
        return 1
    fi

    if is_container; then
        rm -f "${PACKAGES}"/proxmox-mailgateway_*.deb
    else
        rm -f "${PACKAGES}"/proxmox-mailgateway-container_*.deb
    fi

    mapfile -t file_list < <(find "${PACKAGES}" -maxdepth 1 -name '*.deb' -print | sort)

    if ${SUDO} apt-get install -y "${file_list[@]}"; then
        rm -f -- "${file_list[@]}"
    fi
}

SUDO="${SUDO:-sudo -E}"
SCRIPT=$(realpath "${0}")
BASE=$(dirname "${SCRIPT}")
PACKAGES="${BASE}/packages"
SOURCES="${BASE}/sources"
LOGFILE="build.log"
PACKAGE_ARCH=$(dpkg-architecture -qDEB_BUILD_ARCH)
BUILD_PROFILES=""
GITHUB_ACTION=""
PMG_VERSION="${PMG_VERSION:-9.1.0}"

. /etc/os-release

mkdir -p "${PACKAGES}" "${SOURCES}"

while [ "$#" -ge 1 ]; do
	case "$1" in
	version=*)
		PMG_VERSION="${1#*=}"
		;;

	install*)
		if [[ "$1" =~ install=[0-9.-]+ ]]; then
			download_release tags/${1/*=/}
		else
			download_release
		fi
		install_server
		exit 0
		;;

	download*)
		if [[ "$1" =~ download=[0-9.-]+ ]]; then
			download_release tags/${1/*=/}
		else
			download_release
		fi
		exit 0
		;;

	github=*)
		GITHUB_ACTION="true"
		PMG_VERSION="${1#*=}"
		;;

	github)
		GITHUB_ACTION="true"
		;;

	nocheck)
		[[ ${BUILD_PROFILES} =~ nocheck ]] || BUILD_PROFILES=${BUILD_PROFILES}",nocheck"
		export DEB_BUILD_OPTIONS="nocheck"
		;;

	debug)
		exec &> >(tee "${LOGFILE}")
		echo "$@"
		cat /etc/os-release
		set -x
		;;

	*)
		echo "usage: $0 [version] [github] [download] [install] [nocheck] [debug]"
		exit 1
		;;
	esac
	shift
done

[ -n "${BUILD_PROFILES}" ] && BUILD_PROFILES="--build-profiles=${BUILD_PROFILES#,}"

if [[ ! " ${DEB_BUILD_OPTIONS:-} " =~ " nocheck " ]]; then
	export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+${DEB_BUILD_OPTIONS} }nocheck"
fi

echo "Download package list from PMG repository"
PACKAGES_PMG=$(load_packages http://download.proxmox.com/debian/pmg/dists/trixie/pmg-no-subscription/binary-amd64/Packages.gz)

PMG_META_VERSION=$(package_version proxmox-mailgateway all "<=" "${PMG_VERSION}")

if [ -z "${PMG_META_VERSION}" ]; then
	echo "Could not resolve proxmox-mailgateway version for ${PMG_VERSION}" >&2
	exit 1
fi

cd "${SOURCES}"

echo "Build proxmox-mailgateway ${PMG_META_VERSION}"
build_make_deb_package \
	https://git.proxmox.com/git/proxmox-mailgateway.git \
	proxmox-mailgateway \
	"${PMG_META_VERSION}"

PMG_META_DEB="${PACKAGES}/proxmox-mailgateway_${PMG_META_VERSION}_all.deb"

if [ ! -e "${PMG_META_DEB}" ]; then
	echo "Could not find built meta package: ${PMG_META_DEB}" >&2
	exit 1
fi

echo "Download architecture-independent PMG packages"
download_dependency_package "${PMG_META_DEB}" pmg-api all
download_dependency_package "${PMG_META_DEB}" pmg-gui all
download_dependency_package "${PMG_META_DEB}" pmg-docs all
download_dependency_package "${PMG_META_DEB}" pmg-i18n all

PMG_LOG_TRACKER_CONSTRAINT=$(get_dependency_constraint "${PMG_META_DEB}" pmg-log-tracker || true)
PMG_LOG_TRACKER_VERSION=$(package_version pmg-log-tracker amd64 "$(dependency_operator "${PMG_LOG_TRACKER_CONSTRAINT}")" "$(dependency_version "${PMG_LOG_TRACKER_CONSTRAINT}")")

PROXMOX_SPAMASSASSIN_CONSTRAINT=$(get_dependency_constraint "${PMG_META_DEB}" proxmox-spamassassin || true)
PROXMOX_SPAMASSASSIN_VERSION=$(package_version proxmox-spamassassin amd64 "$(dependency_operator "${PROXMOX_SPAMASSASSIN_CONSTRAINT}")" "$(dependency_version "${PROXMOX_SPAMASSASSIN_CONSTRAINT}")")

if [ -z "${PMG_LOG_TRACKER_VERSION}" ]; then
	echo "Could not resolve pmg-log-tracker version" >&2
	exit 1
fi

if [ -z "${PROXMOX_SPAMASSASSIN_VERSION}" ]; then
	echo "Could not resolve proxmox-spamassassin version" >&2
	exit 1
fi

echo "Build pmg-log-tracker ${PMG_LOG_TRACKER_VERSION}"
build_dpkg_package \
	https://git.proxmox.com/git/pmg-log-tracker.git \
	pmg-log-tracker \
	"${PMG_LOG_TRACKER_VERSION}"

echo "Build proxmox-spamassassin ${PROXMOX_SPAMASSASSIN_VERSION}"
build_make_deb_package \
	https://git.proxmox.com/git/proxmox-spamassassin.git \
	proxmox-spamassassin \
	"${PROXMOX_SPAMASSASSIN_VERSION}"

# Remove debug symbol packages from output directory.
rm -f "${PACKAGES}"/*-dbgsym_*.deb "${PACKAGES}"/*.ddeb
