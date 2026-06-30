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

function set_package_info() {

	if [ "$GITHUB_ACTION" ]; then
		sed -i "s#^Maintainer:.*#Maintainer: Github Action <no-reply@github.com>#" debian/control
		sed -i "s#^Homepage:.*#Homepage: https://github.com/qemus/proxmox-mail-arm64#" debian/control
 	else
		sed -i "s#^\(Maintainer.*\)\$#\1\nOrigin: https://github.com/wofferl/proxmox-mail-arm64#" debian/control
	fi
}

SUDO="${SUDO:-sudo -E}"

SCRIPT=$(realpath "${0}")
BASE=$(dirname "${SCRIPT}")
PACKAGES="${BASE}/packages"
SOURCES="${BASE}/sources"
PATCHES="${BASE}/patches"
LOGFILE="build.log"

PACKAGE_ARCH=$(dpkg-architecture -qDEB_BUILD_ARCH)
HOST_ARCH=$(dpkg-architecture -qDEB_HOST_ARCH)
HOST_CPU=$(dpkg-architecture -qDEB_HOST_GNU_CPU)
HOST_SYSTEM=$(dpkg-architecture -qDEB_HOST_GNU_SYSTEM)

BUILD_PROFILES=""
GITHUB_ACTION=""

export DEB_HOST_RUST_TYPE=${HOST_CPU}-unknown-${HOST_SYSTEM}

. /etc/os-release

[ ! -d "${PACKAGES}" ] && mkdir -p "${PACKAGES}"
[ ! -d "${SOURCES}" ] && mkdir -p "${SOURCES}"

while [ "$#" -ge 1 ]; do
	case "$1" in
    cross)
	    PACKAGE_ARCH=arm64
	    BUILD_PROFILES=${BUILD_PROFILES}",cross"

	    export PKG_CONFIG=/usr/bin/aarch64-linux-gnu-pkg-config
	    export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig/
    	export CC=/usr/bin/aarch64-linux-gnu-gcc
    	export DEB_HOST_MULTIARCH=aarch64-linux-gnu
    	;;

	nocheck)
		[[ ${BUILD_PROFILES} =~ nocheck ]] || BUILD_PROFILES=${BUILD_PROFILES}",nocheck"
		export DEB_BUILD_OPTIONS="nocheck"
		;;

	github)
		GITHUB_ACTION="true"
		;;

	debug)
		exec &> >(tee "${LOGFILE}")
		echo "$@"
		cat /etc/os-release
		set -x
		;;

	*)
		echo "usage: $0 [cross] [nocheck] [debug] [github]"
		exit 1
		;;
	esac
	shift
done

[ -n "${BUILD_PROFILES}" ] && BUILD_PROFILES="--build-profiles=${BUILD_PROFILES#,}"

cd "${SOURCES}"

# Use master by default so you can quickly test the current PMG source.
# Replace this with a fixed commit once you know which PMG version you want.
PMG_GIT_COMMIT="${PMG_GIT_COMMIT:-master}"

if [ ! -e "${PACKAGES}/proxmox-mailgateway_${PMG_VERSION:-unknown}_${PACKAGE_ARCH}.deb" ]; then
	git_clone_or_fetch https://git.proxmox.com/git/proxmox-mailgateway.git
	git_clean_and_checkout "${PMG_GIT_COMMIT}" proxmox-mailgateway

	cd proxmox-mailgateway

	set_package_info

	# Remove Rust-only build-deps if they ever appear.
	# PMG is mostly Perl/Debian packaging, but this keeps the script tolerant.
	sed -i '/dh-cargo\|cargo:native\|rustc:native\|librust-/d' debian/control || true

	# Install build dependencies for the selected architecture.
	${SUDO} apt -y build-dep -a"${PACKAGE_ARCH}" ${BUILD_PROFILES} .

	export DEB_VERSION=$(dpkg-parsechangelog -SVersion)
	export DEB_VERSION_UPSTREAM=$(dpkg-parsechangelog -SVersion | cut -d- -f1)

	dpkg-buildpackage -a"${PACKAGE_ARCH}" -b -us -uc ${BUILD_PROFILES}

	cd ..

	mkdir -p "${PACKAGES}"
	mv -f ./*.deb "${PACKAGES}/"
else
	echo "proxmox-mail-gateway up-to-date"
fi

echo
echo "Built packages:"
ls -lh "${PACKAGES}"
