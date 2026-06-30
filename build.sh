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

	# First try tags.
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

	# If no tag exists, try commits from current branch history.
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
	if [ "$GITHUB_ACTION" ]; then
		sed -i "s#^Maintainer:.*#Maintainer: Github Action <no-reply@github.com>#" debian/control
		sed -i "s#^Homepage:.*#Homepage: https://github.com/qemus/proxmox-mail-arm64#" debian/control
	else
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

	version_target="0"
	file_target=""

	while IFS=';' read -r name version arch file; do
		[ "${name}" = "${package_name}" ] || continue

		if [ -n "${arch_filter}" ] && [ "${arch}" != "${arch_filter}" ]; then
			continue
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

	url=$(select_package "${package_name}" "${arch_filter}")
	file=${url##*/}

	echo "${file}" |
		sed -E "s/^${package_name}_([^_]+)_.*/\1/"
}

function download_package() {
	package=${1}
	arch_filter=${2:-all}
	dest=${3:-${PACKAGES}}

	url=$(select_package "${package}" "${arch_filter}")

	if [ -z "${url}" ]; then
		echo "Error: package ${package} with architecture ${arch_filter} not found" >&2
		return 1
	fi

	file="${dest}/${url##*/}"

	if [ -e "${file}" ]; then
		echo "${package} up-to-date"
		return 0
	fi

	echo "${package} downloading..."
	curl -sSfL "${url}" -o "${file}"
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

	${SUDO} apt-get -y build-dep .

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

	${SUDO} apt-get -y build-dep -a"${PACKAGE_ARCH}" ${BUILD_PROFILES} .

	dpkg-buildpackage -a"${PACKAGE_ARCH}" -b -us -uc ${BUILD_PROFILES}

	cd ..

	mv -f ./*.deb "${PACKAGES}/"
}

SUDO="${SUDO:-sudo -E}"

SCRIPT=$(realpath "${0}")
BASE=$(dirname "${SCRIPT}")
PACKAGES="${BASE}/packages"
SOURCES="${BASE}/sources"
PATCHES="${BASE}/patches"
LOGFILE="build.log"

PACKAGE_ARCH=$(dpkg-architecture -qDEB_BUILD_ARCH)

BUILD_PROFILES=""
GITHUB_ACTION=""
PMG_VERSION="${PMG_VERSION:-9.1}"

. /etc/os-release

[ ! -d "${PACKAGES}" ] && mkdir -p "${PACKAGES}"
[ ! -d "${SOURCES}" ] && mkdir -p "${SOURCES}"

while [ "$#" -ge 1 ]; do
	case "$1" in
	version=*)
		PMG_VERSION="${1#*=}"
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
		echo "usage: $0 [version=9.1] [github=9.1] [nocheck] [debug]"
		exit 1
		;;
	esac
	shift
done

[ -n "${BUILD_PROFILES}" ] && BUILD_PROFILES="--build-profiles=${BUILD_PROFILES#,}"

echo "Download package list from PMG repository"
PACKAGES_PMG=$(load_packages http://download.proxmox.com/debian/pmg/dists/trixie/pmg-no-subscription/binary-amd64/Packages.gz)

cd "${SOURCES}"

echo "Build proxmox-mailgateway ${PMG_VERSION}"
build_make_deb_package \
	https://git.proxmox.com/git/proxmox-mailgateway.git \
	proxmox-mailgateway \
	"${PMG_VERSION}"

echo "Download architecture-independent PMG packages"
download_package pmg-api all
download_package pmg-gui all
download_package pmg-docs all
download_package pmg-i18n all

PMG_LOG_TRACKER_VERSION=$(package_version pmg-log-tracker amd64)
PROXMOX_SPAMASSASSIN_VERSION=$(package_version proxmox-spamassassin amd64)

echo "Build pmg-log-tracker ${PMG_LOG_TRACKER_VERSION}"
build_dpkg_package \
	https://git.proxmox.com/git/pmg-log-tracker.git \
	pmg-log-tracker \
	"${PMG_LOG_TRACKER_VERSION}"

echo "Build proxmox-spamassassin ${PROXMOX_SPAMASSASSIN_VERSION}"
build_dpkg_package \
	https://git.proxmox.com/git/proxmox-spamassassin.git \
	proxmox-spamassassin \
	"${PROXMOX_SPAMASSASSIN_VERSION}"

echo
echo "Built/downloaded packages:"
ls -lh "${PACKAGES}"
