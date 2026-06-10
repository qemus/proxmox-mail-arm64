#!/bin/bash
#
# Build script for Proxmox Datacenter Manager on ARM64
# https://github.com/qemus/proxmox-datacenter-arm64

set -eu

function download_package() {
	repo=${1}
	package=${2}
    if [ -n "${5:-}" ]; then
		version_test=("${3}" "${4}")
		dest=${5}
	else
		version_test=('=' "${3}")
		dest=${4}
	fi

	url=$(select_package "${repo}" "${package}" "${version_test[@]}")

	if [ -z "${url}" ]; then
		echo "Error package ${package} in version " "${version_test[@]}" " not found" >&2
		return 1
	fi

	file="${dest}/${url##*/}"
	if [ -e "${file}" ]; then
		echo "${package} up-to-date" >&2
		echo "${file}"
		return 0
	fi

	echo "${package} downloading...${url}" >&2
	curl -sSfL "${url}" -o "${file}"
	echo "${file}"
}

function download_package_by_upstream_version() {
	repo=${1}
	package_name=${2}
	upstream_version=${3}
	dest=${4}

	url_base=http://download.proxmox.com/debian/${repo}
	if [[ "${repo}" == "pdm" ]]; then
		packages_target=${PACKAGES_PDM}
	elif [[ "${repo}" == "devel" ]]; then
		packages_target=${PACKAGES_DEVEL}
	elif [[ "${repo}" == "pve" ]]; then
		packages_target=${PACKAGES_PVE}
	else
		echo "Unknown repo ${repo}" >&2
		return 1
	fi

	version_target=0.0
	file_target=

	while IFS= read -r line; do
		name=${line%%;*}
		line=${line##*${name};}

		if [[ "${name}" == "${package_name}" ]]; then
			version=${line%%;*}
			line=${line##*${version};}
			file=${line%%;*}
			line=${line##*${file};}
			depends=${line}

			# Match Debian revisions and binNMUs for the requested upstream version,
			# for example 1.1.4, 1.1.4-1, 1.1.4-1+b1 or 1.1.4~rc1.
			case "${version}" in
				"${upstream_version}"|"${upstream_version}"-*|"${upstream_version}"+*|"${upstream_version}"~*) ;;
				*) continue ;;
			esac

			if dpkg --compare-versions "${version}" '>>' "${version_target}"; then
				if [ -n "${depends}" ]; then
					${SUDO} apt satisfy -s "${depends}" >/dev/null 2>&1 || continue
				fi
				version_target=${version}
				file_target=${file}
			fi
		fi
	done <<<"${packages_target}"

	if [ -z "${file_target}" ]; then
		return 1
	fi

	url=${url_base}/${file_target}
	file="${dest}/${url##*/}"
	if [ -e "${file}" ]; then
		echo "${package_name} ${version_target} up-to-date" >&2
		echo "${file}"
		return 0
	fi

	echo "${package_name} ${version_target} downloading...${url}" >&2
	curl -sSfL "${url}" -o "${file}"
	echo "${file}"
}

function download_package_with_fallback() {
	repo=${1}
	package=${2}
	dest=${3}
	shift 3

	for version in "$@"; do
		[ -n "${version}" ] || continue

		# First try an exact Debian package version.
		if file=$(download_package "${repo}" "${package}" "${version}" "${dest}" 2>/dev/null); then
			echo "${file}"
			return 0
		fi

		# Then try the same value as an upstream version and accept Debian revisions
		# such as 1.1.4-1.
		if file=$(download_package_by_upstream_version "${repo}" "${package}" "${version}" "${dest}" 2>/dev/null); then
			echo "${file}"
			return 0
		fi
	done

	echo "Error: package ${package} not found in ${repo} for any requested version: $*" >&2
	return 1
}


function download_package_prefix_no_deps() {
	repo=${1}
	package_name=${2}
	upstream_version=${3}
	dest=${4}

	url_base=http://download.proxmox.com/debian/${repo}
	if [[ "${repo}" == "pdm" ]]; then
		packages_target=${PACKAGES_PDM}
	elif [[ "${repo}" == "devel" ]]; then
		packages_target=${PACKAGES_DEVEL}
	elif [[ "${repo}" == "pve" ]]; then
		packages_target=${PACKAGES_PVE}
	else
		echo "Unknown repo ${repo}" >&2
		return 1
	fi

	version_target=""
	file_target=""

	while IFS=';' read -r name version file depends; do
		[[ "${name}" == "${package_name}" ]] || continue

		case "${version}" in
			"${upstream_version}"|"${upstream_version}"-*|"${upstream_version}"+*|"${upstream_version}"~*) ;;
			*) continue ;;
		esac

		if [ -z "${version_target}" ] || dpkg --compare-versions "${version}" '>>' "${version_target}"; then
			version_target=${version}
			file_target=${file}
		fi
	done <<<"${packages_target}"

	if [ -z "${file_target}" ]; then
		echo "Error: package ${package_name} not found in ${repo} for upstream version ${upstream_version}" >&2
		echo "Available ${package_name} versions in ${repo}:" >&2
		while IFS=';' read -r name version file depends; do
			[[ "${name}" == "${package_name}" ]] && echo "  ${version}" >&2
		done <<<"${packages_target}"
		return 1
	fi

	url=${url_base}/${file_target}
	file="${dest}/${url##*/}"
	if [ -e "${file}" ]; then
		echo "${package_name} ${version_target} up-to-date" >&2
		echo "${file}"
		return 0
	fi

	echo "${package_name} ${version_target} downloading...${url}" >&2
	curl -sSfL "${url}" -o "${file}"
	echo "${file}"
}


function download_package_max_upstream_no_deps() {
	repo=${1}
	package_name=${2}
	max_upstream_version=${3}
	dest=${4}

	url_base=http://download.proxmox.com/debian/${repo}
	if [[ "${repo}" == "pdm" ]]; then
		packages_target=${PACKAGES_PDM}
	elif [[ "${repo}" == "devel" ]]; then
		packages_target=${PACKAGES_DEVEL}
	elif [[ "${repo}" == "pve" ]]; then
		packages_target=${PACKAGES_PVE}
	else
		echo "Unknown repo ${repo}" >&2
		return 1
	fi

	version_target=""
	file_target=""
	upstream_target=""

	while IFS=';' read -r name version file depends; do
		[[ "${name}" == "${package_name}" ]] || continue
		[ -n "${version}" ] || continue

		# Compare by upstream part, so a repository version like 1.1.2 is accepted
		# when the requested source version is 1.1.4, but 1.1.5 is not.
		upstream=${version%%-*}
		if ! dpkg --compare-versions "${upstream}" le "${max_upstream_version}"; then
			continue
		fi

		if [ -z "${version_target}" ] || dpkg --compare-versions "${version}" '>>' "${version_target}"; then
			version_target=${version}
			upstream_target=${upstream}
			file_target=${file}
		fi
	done <<<"${packages_target}"

	if [ -z "${file_target}" ]; then
		echo "Error: package ${package_name} not found in ${repo} with upstream <= ${max_upstream_version}" >&2
		echo "Available ${package_name} versions in ${repo}:" >&2
		while IFS=';' read -r name version file depends; do
			[[ "${name}" == "${package_name}" ]] && echo "  ${version}" >&2
		done <<<"${packages_target}"
		return 1
	fi

	if [ "${upstream_target}" != "${max_upstream_version}" ]; then
		echo "Warning: using ${package_name} ${version_target}; requested source upstream is ${max_upstream_version}" >&2
	else
		echo "Using ${package_name} ${version_target}" >&2
	fi

	url=${url_base}/${file_target}
	file="${dest}/${url##*/}"
	if [ -e "${file}" ]; then
		echo "${package_name} ${version_target} up-to-date" >&2
		echo "${file}"
		return 0
	fi

	echo "${package_name} ${version_target} downloading...${url}" >&2
	curl -sSfL "${url}" -o "${file}"
	echo "${file}"
}

function git_clone_or_fetch() {
	url=${1}              # url/name.git
	name_git=${url##*/}   # name.git
	name=${name_git%.git} # name

	if [ ! -d "${name}" ]; then
		git clone "${url}"
	else
		git -C "${name}" fetch
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

function resolve_dm_commit() {
	version=${1}
	repo_path=${2}
	local version_stripped=${version%%-*}

	# Try tag formats commonly used by Proxmox
	for tag in $(git -C "${repo_path}" tag -l "*${version_stripped}*" 2>/dev/null); do
		commit=$(git -C "${repo_path}" rev-list -n1 "${tag}" 2>/dev/null)
		if [ -n "${commit}" ]; then
			echo "${commit}"
			return 0
		fi
	done

	# Search for the "bump version to X" commit message pattern used by Proxmox
	commit=$(git -C "${repo_path}" log --all --format="%H" -1 --grep="bump version to ${version_stripped}" -- debian/changelog 2>/dev/null)
	if [ -n "${commit}" ]; then
		echo "${commit}"
		return 0
	fi

	# Use pickaxe (-S) to find the commit that introduced the version in debian/changelog
	commit=$(git -C "${repo_path}" log --all --format="%H" -1 -S "proxmox-datacenter-manager (${version_stripped}" -- debian/changelog 2>/dev/null)
	if [ -n "${commit}" ]; then
		echo "${commit}"
		return 0
	fi

	# Fall back to searching commit messages for the changelog entry pattern
	commit=$(git -C "${repo_path}" log --all --format="%H" -1 --grep="proxmox-datacenter-manager (${version})" -- debian/changelog 2>/dev/null)
	if [ -n "${commit}" ]; then
		echo "${commit}"
		return 0
	fi

	if [ "${version_stripped}" != "${version}" ]; then
		commit=$(git -C "${repo_path}" log --all --format="%H" -1 --grep="proxmox-datacenter-manager (${version_stripped}" -- debian/changelog 2>/dev/null)
		if [ -n "${commit}" ]; then
			echo "${commit}"
			return 0
		fi
	fi

	return 1
}

function resolve_proxmox_commit() {
	dm_commit=${1}
	dm_path=${2}
	proxmox_path=${3}

	# Read the proxmox dependency version from Cargo.toml at the dm commit
	proxmox_version=$(git -C "${dm_path}" show "${dm_commit}:Cargo.toml" 2>/dev/null | \
		sed -n 's/.*proxmox-sys.*version\s*=\s*"\([^"]*\)".*/\1/p' | head -1)

	if [ -n "${proxmox_version}" ]; then
		# Try to find a matching tag in proxmox.git
		for tag in $(git -C "${proxmox_path}" tag -l "*${proxmox_version}*" 2>/dev/null); do
			commit=$(git -C "${proxmox_path}" rev-list -n1 "${tag}" 2>/dev/null)
			if [ -n "${commit}" ]; then
				echo "${commit}"
				return 0
			fi
		done
	fi

	# Fall back to the most recent commit at or before the dm commit date
	dm_date=$(git -C "${dm_path}" show -s --format=%ci "${dm_commit}" 2>/dev/null)
	if [ -n "${dm_date}" ]; then
		commit=$(git -C "${proxmox_path}" log --all --format="%H" -1 --before="${dm_date}" 2>/dev/null)
		if [ -n "${commit}" ]; then
			echo "${commit}"
			return 0
		fi
	fi

	return 1
}

function load_packages() {
	url=${1}
	curl -sSf -H 'Cache-Control: no-cache' "${url}" |
		gzip -d - |
		awk -F": " '/^(Package|Version|Depends|Filename)/ {
				if($1 == "Package") {
					version="";
					depends="";
					filename="";
					package=$2;
				}
				else if($1 == "Version") {
					version=$2;
				}
				else if($1 == "Depends") {
					depends=$2;
				}
				else if($1 == "Filename") {
					filename=$2;
					print package";"version";"filename";"depends;
				}
			}'
}

function select_package() {
	repo=${1}
	package_name=${2}
	version_test=("${3}" "${4}")
	url_base=http://download.proxmox.com/debian/${repo}
	if [[ "${repo}" == "pdm" ]]; then
		packages_target=${PACKAGES_PDM}
	elif [[ "${repo}" == "devel" ]]; then
		packages_target=${PACKAGES_DEVEL}
	elif [[ "${repo}" == "pve" ]]; then
		packages_target=${PACKAGES_PVE}
	else
		echo "Unknown repo ${repo}" >&2
		return 1
	fi

	version_target=0.0
	file_target=

	while IFS= read -r line; do
		name=${line%%;*}
		line=${line##*${name};}

		if [[ "${name}" == "${package_name}" ]]; then
			version=${line%%;*}
			line=${line##*${version};}
			file=${line%%;*}
			line=${line##*${file};}
			depends=${line}
			if dpkg --compare-versions "${version}" "${version_test[@]}" &&
				dpkg --compare-versions "${version}" '>>' "${version_target}"; then
				if [ -n "$depends" ]; then
					${SUDO} apt satisfy -s "${depends}" >/dev/null 2>&1 || continue
				fi
				version_target=${version}
				file_target=${file}
			fi
		fi
	done <<<"${packages_target}"

	if [ -n "${file_target}" ]; then
		url=${url_base}/${file_target}
		echo "${url}"
	fi
}

function set_package_info() {
	if [ "$GITHUB_ACTION" ]; then
		sed -i "s#^Maintainer:.*#Maintainer: Github Actions <no-reply@github.com>#" debian/control
		sed -i "s#^Homepage:.*#Homepage: https://github.com/qemus/proxmox-datacenter-arm64#" debian/control
	else
		sed -i "s#^\(Maintainer.*\)\$#\1\nOrigin: https://github.com/qemus/proxmox-datacenter-arm64#" debian/control
	fi
}

file_list=()
function download_release() {
	version=${1:-latest}
	release_url="https://api.github.com/repos/qemus/proxmox-datacenter-arm64/releases/${version}"

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

        [[ "$file" == *"dbgsym"* ]] && continue
        [[ "$file" == "proxmox-datacenter-manager-client"* ]] && continue

		file_list+=("${PACKAGES}/${file}")
	done
}

function install_server() {
	if [ "${#file_list[@]}" -eq 0 ]; then
		echo "Error: no files found to install" >&2
		return 1
	fi

	${SUDO} apt-get install -y "${file_list[@]}"
}

SUDO="${SUDO:-sudo -E}"

SCRIPT=$(realpath "${0}")
BASE=$(dirname "${SCRIPT}")
PACKAGES="${BASE}/packages"
PACKAGES_BUILD="${BASE}/packages_build"
PATCHES="${BASE}/patches"
SOURCES="${BASE}/sources"
LOGFILE="build.log"
PACKAGE_ARCH=$(dpkg-architecture -q DEB_BUILD_ARCH)
HOST_ARCH=$(dpkg-architecture -q DEB_HOST_ARCH)
HOST_CPU=$(dpkg-architecture -q DEB_HOST_GNU_CPU)
HOST_SYSTEM=$(dpkg-architecture -q DEB_HOST_GNU_SYSTEM)
BUILD_PACKAGE="server"
BUILD_PROFILES=""
GITHUB_ACTION=""

export DEB_HOST_RUST_TYPE=${HOST_CPU}-unknown-${HOST_SYSTEM}

. /etc/os-release

[ ! -d "${PACKAGES}" ] && mkdir -p "${PACKAGES}"

while [ "$#" -ge 1 ]; do
	case "$1" in
	cross*)
		if [[ "$1" =~ cross=[0-9.-]+ ]]; then
			PROXMOX_DM_VER="${1#cross=}"
		fi

		HOST_ARCH=arm64
		export DEB_HOST_ARCH=arm64		
		BUILD_PROFILES=${BUILD_PROFILES}",cross"
		[[ ${BUILD_PROFILES} =~ nocheck ]] || BUILD_PROFILES=${BUILD_PROFILES}",nocheck"
		export DEB_BUILD_OPTIONS="nocheck"

		${SUDO} dpkg --add-architecture arm64
		${SUDO} apt update
		${SUDO} apt install -y crossbuild-essential-arm64 pkgconf:arm64 libssl-dev:arm64 nettle-dev:arm64 libudev-dev:arm64 \
		                       libcrypt-dev:arm64 libsystemd-dev:arm64 libacl1-dev:arm64 uuid-dev:arm64 libfuse3-dev:arm64 \
							   libldap2-dev:arm64 libzstd-dev:arm64 libpam0g-dev:arm64 zlib1g-dev:arm64 libapt-pkg-dev:arm64 \
						       jq rsync qemu-user qemu-user-binfmt patchelf binutils-aarch64-linux-gnu

		export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=/usr/bin/aarch64-linux-gnu-gcc
		export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER=qemu-aarch64
		export CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
		export TARGET=aarch64-unknown-linux-gnu
		export PKG_CONFIG=/usr/bin/aarch64-linux-gnu-pkg-config
		export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig/
		export CC=/usr/bin/aarch64-linux-gnu-gcc
		export DEB_HOST_MULTIARCH=aarch64-linux-gnu
		export DEB_HOST_RUST_TYPE=aarch64-unknown-linux-gnu
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
	github*)
	    if [[ "$1" =~ github=[0-9.-]+ ]]; then
			PROXMOX_DM_VER="${1#github=}"
		fi
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
		rustc -V
		cargo -V
		set -x
		;;
	*)
		echo "usage $0 [cross] [nocheck] [debug] [download] [install]"
		exit 1
		;;
	esac
	shift
done
[ -n "${BUILD_PROFILES}" ] && BUILD_PROFILES="--build-profiles=${BUILD_PROFILES#,}"

if [ ! -d "${PATCHES}" ]; then
	echo "Directory ${PATCHES} is missing! Have you cloned the repository?"
	exit 1
fi

[ ! -d "${SOURCES}" ] && mkdir -p "${SOURCES}"
[ ! -d "${PACKAGES_BUILD}" ] && mkdir -p "${PACKAGES_BUILD}"

echo "Download packages list from proxmox devel repository"
PACKAGES_DEVEL=$(load_packages http://download.proxmox.com/debian/devel/dists/trixie/main/binary-amd64/Packages.gz)
echo "Download packages list from pdm repositories"
PACKAGES_PDM="$(
	load_packages http://download.proxmox.com/debian/pdm/dists/trixie/pdm-test/binary-amd64/Packages.gz
	load_packages http://download.proxmox.com/debian/pdm/dists/trixie/pdm-no-subscription/binary-amd64/Packages.gz
)"
echo "Download packages list from PVE repository"
PACKAGES_PVE=$(load_packages http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz)

echo "Download dependencies"
EXTJS_VER=(">=" "7~")
PDM_I18N_VER=(">=" "3.6.0")
PROXMOX_ACME_VER=(">=" "1.7.0")
PROXMOX_WIDGETTOOLKIT_VER=(">=" "5.0.2")
if [ "${BUILD_PACKAGE}" = "server" ]; then
    download_package pdm pdm-i18n "${PDM_I18N_VER[@]}" "${PACKAGES}" >/dev/null
	libjs_extjs="$(download_package pdm libjs-extjs "${EXTJS_VER[@]}" "${PACKAGES}")"
	proxmox_widget_toolkit="$(download_package pdm proxmox-widget-toolkit "${PROXMOX_WIDGETTOOLKIT_VER[@]}" "${PACKAGES}")"
	download_package pdm libproxmox-acme-plugins "${PROXMOX_ACME_VER[@]}" "${PACKAGES}" >/dev/null

	packages_install=(
		"${libjs_extjs}"
		"${proxmox_widget_toolkit}"
		"$(download_package devel proxmox-widget-toolkit-dev "${PROXMOX_WIDGETTOOLKIT_VER[@]}" "${PACKAGES_BUILD}")"
	)
fi

echo "Install build dependencies"
${SUDO} apt install -y "${packages_install[@]}"

cat <<EOF >rust-toolchain.toml
[toolchain]
channel="1.94.0"
targets = [ "${CARGO_BUILD_TARGET:-$(rustc -vV 2>/dev/null | awk '/^host/ { print $2 }')}" ]
EOF

cd "${SOURCES}"

PROXMOX_DM_VER="${PROXMOX_DM_VER:-1.1.4}"
PROXMOX_DM_VER="${PROXMOX_DM_VER%%-*}"
PROXMOX_DM_GIT=""
PROXMOX_GIT=""

if [ -e "${PACKAGES}/proxmox-datacenter-manager_${PROXMOX_DM_VER}_${HOST_ARCH}.deb" ] && { [[ ! "${BUILD_PROFILES}" =~ cross ]] || [ -e "${PACKAGES}/proxmox-datacenter-manager-ui_${PROXMOX_DM_VER}_all.deb" ]; }; then
  echo "proxmox-datacenter-manager up-to-date" && exit 0
fi

git_clone_or_fetch https://git.proxmox.com/git/proxmox.git
git_clone_or_fetch https://git.proxmox.com/git/proxmox-datacenter-manager.git

echo "Resolving commit hashes for version ${PROXMOX_DM_VER}..."

PROXMOX_DM_GIT=$(resolve_dm_commit "${PROXMOX_DM_VER}" proxmox-datacenter-manager) || true
if [ -z "${PROXMOX_DM_GIT}" ]; then
  echo "Error: Could not resolve proxmox-datacenter-manager commit for version ${PROXMOX_DM_VER}" >&2
  exit 1
fi

echo "Using proxmox-datacenter-manager commit: ${PROXMOX_DM_GIT}"

PROXMOX_GIT=$(resolve_proxmox_commit "${PROXMOX_DM_GIT}" proxmox-datacenter-manager proxmox) || true
if [ -z "${PROXMOX_GIT}" ]; then
  echo "Error: Could not resolve proxmox commit for version ${PROXMOX_DM_VER}" >&2
  exit 1
fi

echo "Using Proxmox commit: ${PROXMOX_GIT}"

git_clean_and_checkout ${PROXMOX_GIT} proxmox
git_clean_and_checkout ${PROXMOX_DM_GIT} proxmox-datacenter-manager

sed -i '/dh-cargo\|cargo:native\|rustc:native\|librust-\|libstd-rust-dev/d' proxmox-datacenter-manager/debian/control
sed -i '/libjs-extjs\|libproxmox-acme-plugins\|libsystemd-dev\|proxmox-widget-toolkit[^-]/d' proxmox-datacenter-manager/debian/control
sed -i 's/\(latexmk\|proxmox-widget-toolkit-dev\|python3-sphinx\)/\1:all/' proxmox-datacenter-manager/debian/control
sed -i 's/^Multi-Arch: .*/Multi-Arch: allowed/' proxmox-datacenter-manager/debian/control

cat >>proxmox-datacenter-manager/debian/rules <<'EOF'

override_dh_builddeb:
	perl -0pi -e 's/^Multi-Arch:[^\n]*(?:\n[ \t].*)*/Multi-Arch: allowed/mg' debian/proxmox-datacenter-manager/DEBIAN/control
	dh_builddeb
EOF

cat >proxmox-datacenter-manager/debian/SOURCE <<EOF
This package was built from:

proxmox-datacenter-manager:
  repository: https://git.proxmox.com/git/proxmox-datacenter-manager.git
  commit: ${PROXMOX_DM_GIT}

proxmox:
  repository: https://git.proxmox.com/git/proxmox.git
  commit: ${PROXMOX_GIT}
EOF

sed -i '/patch.crates-io/,/pxar/s/^#//' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a pbs-api-types = { path = "../proxmox/pbs-api-types" }' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a pve-api-types = { path = "../proxmox/pve-api-types" }' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a proxmox-base64 = { path = "../proxmox/proxmox-base64" }' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a proxmox-disks = { path = "../proxmox/proxmox-disks" }' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a proxmox-procfs = { path = "../proxmox/proxmox-procfs" }' proxmox-datacenter-manager/Cargo.toml
sed -i '/\[patch.crates-io\]/a proxmox-rrd-api-types = { path = "../proxmox/proxmox-rrd-api-types" }' proxmox-datacenter-manager/Cargo.toml

patch -p1 -d proxmox-datacenter-manager/ <"${PATCHES}/proxmox-datacenter-manager-build.patch"
patch -p1 -d proxmox-datacenter-manager/ <"${PATCHES}/proxmox-datacenter-manager-fido2-arm.patch"

if [[ "${BUILD_PROFILES}" =~ cross ]]; then
	# Add COMPILEDIR override for cross-compilation target in Makefile
	sed -i '/^COMPILEDIR := target\/debug$/,/^endif$/{/^endif$/a \\nifdef CARGO_BUILD_TARGET\nCOMPILEDIR := target/$(CARGO_BUILD_TARGET)/$(if $(filter release,$(BUILD_MODE)),release,debug)\nendif
}' proxmox-datacenter-manager/Makefile

	# Add COMPILEDIR override for cross-compilation target in docs/Makefile
	sed -i '/^COMPILEDIR := \.\.\/target\/debug$/,/^endif$/{/^endif$/a \\nifdef CARGO_BUILD_TARGET\nCOMPILEDIR := ../target/$(CARGO_BUILD_TARGET)/$(if $(filter release,$(BUILD_MODE)),release,debug)\nendif
}' proxmox-datacenter-manager/docs/Makefile

	# Use qemu-aarch64 to run cross-compiled binaries in docs/Makefile
	sed -i 's|\t$(COMPILEDIR)/docgen |\tqemu-aarch64 $(COMPILEDIR)/docgen |' proxmox-datacenter-manager/docs/Makefile
	sed -i 's|\t$< printdoc|\tqemu-aarch64 $< printdoc|' proxmox-datacenter-manager/docs/Makefile

	# Add COMPILEDIR override for cross-compilation target in docs/api-viewer/Makefile
	sed -i '/^COMPILEDIR := \.\.\/\.\.\/target\/debug$/,/^endif$/{/^endif$/a \
ifdef CARGO_BUILD_TARGET\
COMPILEDIR := ../../target/$(CARGO_BUILD_TARGET)/$(if $(filter release,$(BUILD_MODE)),release,debug)\
endif
}' proxmox-datacenter-manager/docs/api-viewer/Makefile

	# Use qemu-aarch64 to run the cross-compiled docgen in docs/api-viewer/Makefile
	sed -i 's|$(COMPILEDIR)/docgen apidata.js|qemu-aarch64 $(COMPILEDIR)/docgen apidata.js|' proxmox-datacenter-manager/docs/api-viewer/Makefile
fi

cd proxmox-datacenter-manager/
set_package_info

if [ "${PACKAGE_ARCH}" != "${HOST_ARCH}" ]; then
  export DEB_BUILD_MAINT_OPTIONS="hardening=+all,-branch"
  export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+${DEB_BUILD_OPTIONS} }nostrip"
fi

${SUDO} apt -y build-dep -a${HOST_ARCH} ${BUILD_PROFILES} .

export DEB_VERSION=$(dpkg-parsechangelog -SVersion)
export DEB_VERSION_UPSTREAM=$(dpkg-parsechangelog -SVersion | cut -d- -f1)

echo "Building only Architecture:any PDM packages"
dpkg-buildpackage -a${HOST_ARCH} -B -us -uc ${BUILD_PROFILES}

echo "Downloading Architecture:all PDM packages (latest available <= requested)"
download_package_max_upstream_no_deps pdm proxmox-datacenter-manager-ui "${DEB_VERSION_UPSTREAM}" "${PACKAGES}" >/dev/null
download_package_max_upstream_no_deps pdm proxmox-datacenter-manager-docs "${DEB_VERSION_UPSTREAM}" "${PACKAGES}" >/dev/null
cd ..

shopt -s nullglob
artifacts=(
  proxmox-datacenter-manager{,-dbgsym}_${PROXMOX_DM_VER}_${HOST_ARCH}.*
  proxmox-datacenter-manager-client{,-dbgsym}_${PROXMOX_DM_VER}_${HOST_ARCH}.*
)
shopt -u nullglob

if [ "${#artifacts[@]}" -eq 0 ]; then
  echo "Error: no build artifacts found" >&2
  ls -lh
  exit 1
fi

mv -f "${artifacts[@]}" "${PACKAGES}"

PVE_XTERMJS_VER="6.0.0-1"
PVE_XTERMJS_GIT="1209ea0d5bda89fec71484d09f784bd3b94fafaf"
PROXMOX_XTERMJS_GIT="deb32a6c4a21bea0d72059de0835fde504296bf0"
PROXMOX_TERMPROXY_VER="2.1.0"

if [ ! -e "${PACKAGES}/pve-xtermjs_${PVE_XTERMJS_VER}_all.deb" ]; then
	echo "Downloading Architecture:all pve-xtermjs package"
	download_package_prefix_no_deps pve pve-xtermjs "${PVE_XTERMJS_VER}" "${PACKAGES}" >/dev/null
else
	echo "pve-xtermjs up-to-date"
fi

if [ ! -e "${PACKAGES}/proxmox-termproxy_${PROXMOX_TERMPROXY_VER}_${HOST_ARCH}.deb" ]; then
	git_clone_or_fetch https://git.proxmox.com/git/pve-xtermjs.git
	git_clean_and_checkout ${PVE_XTERMJS_GIT} pve-xtermjs
	patch -p1 -d pve-xtermjs/ <"${PATCHES}/pve-xtermjs-arm.patch"
	[[ "${BUILD_PROFILES}" =~ cross ]] && patch -p1 -d pve-xtermjs/ <"${PATCHES}/pve-xtermjs-cross.patch"
	cd pve-xtermjs/
	git_clone_or_fetch https://git.proxmox.com/git/proxmox.git
	git_clean_and_checkout ${PROXMOX_XTERMJS_GIT} proxmox
	cd termproxy
	set_package_info
	${SUDO} apt -y -a${HOST_ARCH} build-dep .
	if [[ "${BUILD_PROFILES}" =~ cross ]]; then
    	# The upstream Makefile runs lintian after building. Cross builds may use nostrip,
	    # which makes lintian fail even though the package was built correctly.
	    sed -i 's|^\([[:space:]]*\)lintian \(.*\)$|\1- lintian \2|' Makefile
	fi
	BUILD_MODE=release make deb
	cd ../..
    mv -f ../proxmox-termproxy_${PROXMOX_TERMPROXY_VER}_${HOST_ARCH}.deb "${PACKAGES}"
else
	echo "proxmox-termproxy up-to-date"
fi

PROXMOX_JOURNALREADER_VER="1.6-1"
PROXMOX_JOURNALREADER_GIT="b09ee543344fb7082a27346ecb0008f38af6367d"
if [ ! -e "${PACKAGES}/proxmox-mini-journalreader_${PROXMOX_JOURNALREADER_VER}_${HOST_ARCH}.deb" ]; then
	git_clone_or_fetch https://git.proxmox.com/git/proxmox-mini-journalreader.git
	git_clean_and_checkout ${PROXMOX_JOURNALREADER_GIT} proxmox-mini-journalreader
	patch -p1 -d proxmox-mini-journalreader/ <${PATCHES}/proxmox-mini-journalreader.patch
	[[ "${BUILD_PROFILES}" =~ cross ]] &&
		patch -p1 -d proxmox-mini-journalreader/ <"${PATCHES}/proxmox-mini-journalreader-cross.patch"
	cd proxmox-mini-journalreader/
	set_package_info
	${SUDO} apt -y -a${PACKAGE_ARCH} build-dep .
	make deb
	mv -f proxmox-mini-journalreader{,-dbgsym}_${PROXMOX_JOURNALREADER_VER}_${HOST_ARCH}.deb "${PACKAGES}"
	cd ..
else
	echo "proxmox-mini-journalreader up-to-date"
fi

# Remove debug symbol packages from output directory.
rm -f "${PACKAGES}"/*-dbgsym_*.deb "${PACKAGES}"/*.ddeb
