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

function git_checkout_subdir_version() {
	path=${1}
	subdir=${2}
	version=${3}

	changelog="${subdir}/debian/changelog"

	ref="$(
		git -C "${path}" for-each-ref --format='%(refname:short)' refs/tags |
			while read -r tag; do
				if git -C "${path}" show "${tag}:${changelog}" >/dev/null 2>&1; then
					tag_version="$(
						git -C "${path}" show "${tag}:${changelog}" |
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
			git -C "${path}" log --format='%H' -- "${changelog}" |
				while read -r commit; do
					commit_version="$(
						git -C "${path}" show "${commit}:${changelog}" |
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
		echo "Could not find Git ref for ${path}/${subdir} version ${version}" >&2
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

function download_external_package() {
	url=${1}

	file="${PACKAGES}/${url##*/}"

	if [ -e "${file}" ]; then
		echo "${file##*/} up-to-date"
		return
	fi

	echo "Downloading ${file##*/}"
	curl -fsSL "${url}" -o "${file}"
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

function find_package_file() {
	package=${1}

	find "${PACKAGES}" -maxdepth 1 -name "${package}_*.deb" -print -quit
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

function latest_github_release_asset() {
	repo=${1}
	package=${2}
	min_version=${3}

	api_url="https://api.github.com/repos/${repo}/releases"

	curl -sSfL "${api_url}" |
		jq -r --arg package "${package}" '
			.[] as $release |
			$release.assets[] |
			select(.name | test("^" + $package + "_[0-9][^_]*_arm64\\.deb$")) |
			[
				.name,
				($release.tag_name // ""),
				.browser_download_url
			] |
			@tsv
		' |
		while IFS=$'\t' read -r asset tag url; do
			version="$(
				echo "${asset}" |
					sed -E "s/^${package}_([^_]+)_arm64\.deb$/\1/"
			)"

			if dpkg --compare-versions "${version}" ge "${min_version}"; then
				echo "${version};${tag};${url};${asset}"
			fi
		done |
		sort -t ';' -k1,1V |
		tail -n1
}

function repackage_static_package_as_arch() {
	package=${1}
	version=${2}

	target="${PACKAGES}/${package}_${version}_${PACKAGE_ARCH}.deb"

	if [ -e "${target}" ]; then
		echo "${package} up-to-date"
		return 0
	fi

	url=$(select_package "${package}" amd64 "=" "${version}")

	if [ -z "${url}" ]; then
		echo "Could not find ${package} ${version} amd64 package" >&2
		exit 1
	fi

	source_deb="${PACKAGES}/${url##*/}"

	if [ ! -e "${source_deb}" ]; then
		echo "Downloading ${source_deb##*/}"
		curl -sSfL "${url}" -o "${source_deb}"
	fi

	tmpdir="$(mktemp -d)"

	dpkg-deb -R "${source_deb}" "${tmpdir}/pkg"

	elf_files="$(
		find "${tmpdir}/pkg" -type f ! -path "${tmpdir}/pkg/DEBIAN/*" -exec sh -c '
			for file do
				if readelf -h "$file" >/dev/null 2>&1; then
					echo "$file"
				fi
			done
		' sh {} +
	)"

	if [ -n "${elf_files}" ]; then
		echo "${package} contains native ELF files and cannot be safely repackaged:" >&2
		echo "${elf_files}" >&2
		rm -rf "${tmpdir}"
		exit 1
	fi

	sed -i "s/^Architecture:.*/Architecture: ${PACKAGE_ARCH}/" "${tmpdir}/pkg/DEBIAN/control"

	dpkg-deb -b "${tmpdir}/pkg" "${target}"

	rm -rf "${tmpdir}"
	rm -f "${source_deb}"
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

function get_build_dependency_min_version() {
	control_file=${1}
	dependency=${2}

	awk -v dep="${dependency}" '
		/^Build-Depends:/ {
			in_build_depends=1
			line=$0
			sub(/^Build-Depends:[[:space:]]*/, "", line)
			build_depends=line
			next
		}

		in_build_depends && /^[[:space:]]/ {
			build_depends=build_depends " " $0
			next
		}

		in_build_depends {
			in_build_depends=0
		}

		END {
			gsub(/\n/, " ", build_depends)
			gsub(/,/, " , ", build_depends)

			pattern=dep "[[:space:]]*\\(>=[[:space:]]*[^)]*\\)"

			if (match(build_depends, pattern)) {
				value=substr(build_depends, RSTART, RLENGTH)
				sub(".*\\(>=[[:space:]]*", "", value)
				sub("\\).*", "", value)
				print value
			}
		}
	' "${control_file}"
}

function dependency_package_version() {
	source_deb=${1}
	package=${2}
	arch=${3:-amd64}

	constraint=$(get_dependency_constraint "${source_deb}" "${package}" || true)
	operator=$(dependency_operator "${constraint}")
	version=$(dependency_version "${constraint}")

	package_version "${package}" "${arch}" "${operator}" "${version}"
}

function find_debian_package_subdir() {
	path=${1}
	package=${2}

	control_file="$(
		find "${path}" -path '*/debian/control' -print |
			while read -r file; do
				if grep -q "^Package: ${package}$" "${file}"; then
					echo "${file}"
					break
				fi
			done
	)"

	if [ -z "${control_file}" ]; then
		echo "Could not find Debian package ${package} in ${path}" >&2
		return 1
	fi

	control_dir="${control_file%/debian/control}"
	control_dir="${control_dir#${path}/}"

	echo "${control_dir}"
}

function build_perlmod() {
	min_version=${1}

	if compgen -G "${PACKAGES}/perlmod-bin_*_*.deb" >/dev/null; then
		echo "perlmod-bin up-to-date"
		return 0
	fi

	git_clone_or_fetch https://git.proxmox.com/git/perlmod.git

	PERLMOD_SUBDIR="$(find_debian_package_subdir perlmod perlmod-bin)"

	cd "perlmod/${PERLMOD_SUBDIR}"

	PERLMOD_SOURCE_VERSION="$(dpkg-parsechangelog -SVersion)"

	if ! dpkg --compare-versions "${PERLMOD_SOURCE_VERSION}" ge "${min_version}"; then
		echo "perlmod-bin ${PERLMOD_SOURCE_VERSION} is older than required ${min_version}" >&2
		exit 1
	fi

	sed -i '/librust-/d' debian/control

	if [ -f debian/control ]; then
		set_package_info
	fi

	dpkg-buildpackage -b -us -uc ${BUILD_PROFILES}

	cd ../..

	PERLMOD_BIN_DEB="$(
		find perlmod -maxdepth 2 -name 'perlmod-bin_*_*.deb' -print -quit
	)"

	if [ -z "${PERLMOD_BIN_DEB}" ]; then
		echo "Could not find built perlmod-bin package" >&2
		exit 1
	fi

	PERLMOD_BIN_DEB="$(realpath "${PERLMOD_BIN_DEB}")"

	${SUDO} apt-get install -y "${PERLMOD_BIN_DEB}"

	# perlmod-bin is only needed as a build helper for libpmg-rs-perl.
	# Do not keep it in the final release package directory.
	rm -f "${PERLMOD_BIN_DEB}"
	find perlmod -maxdepth 2 -name 'perlmod-bin-dbgsym_*_*.deb' -delete 2>/dev/null || true
}

function find_cargo_package_path() {
	path=${1}
	package=${2}

	cargo_file="$(
		find "${path}" -name Cargo.toml -print |
			while read -r file; do
				if grep -q "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${package}\"" "${file}"; then
					echo "${file}"
					break
				fi
			done
	)"

	if [ -z "${cargo_file}" ]; then
		return 1
	fi

	cargo_dir="${cargo_file%/Cargo.toml}"
	realpath "${cargo_dir}"
}

function build_libpmg_rs_perl() {
	version=${1}

	if compgen -G "${PACKAGES}/libpmg-rs-perl_${version}_${PACKAGE_ARCH}.deb" >/dev/null; then
		echo "libpmg-rs-perl up-to-date"
		return 0
	fi

	git_clone_or_fetch https://git.proxmox.com/git/proxmox-perl-rs.git
	cd proxmox-perl-rs/pmg-rs

	sed -i '/librust-/d; /perlmod-bin/d' debian/control

	# Do not use Debian's offline cargo registry.
	rm -rf debian/cargo_registry
	rm -f .cargo/config .cargo/config.toml

	mkdir -p .cargo
	cat > .cargo/config.toml <<'EOF_CARGO_CONFIG'
[source.crates-io]
registry = "https://github.com/rust-lang/crates.io-index"
EOF_CARGO_CONFIG

	# Disable the Debian cargo registry preparation step.
	if grep -q 'prepare-debian' debian/rules; then
		python3 - <<'EOF_PATCH_RULES'
from pathlib import Path

path = Path("debian/rules")
lines = path.read_text().splitlines()
out = []
skip = False

for line in lines:
    if line.startswith("override_dh_auto_configure:"):
        out.append("override_dh_auto_configure:")
        out.append("\tdh_auto_configure")
        skip = True
        continue

    if skip:
        if line and not line.startswith("\t"):
            skip = False
        else:
            continue

    if not skip:
        out.append(line)

path.write_text("\n".join(out) + "\n")
EOF_PATCH_RULES
	fi

	# Generate one complete [patch.crates-io] section from the local Proxmox
	# Rust repos. This avoids discovering missing crates one build at a time.
	python3 - "${SOURCES}/perlmod" "${SOURCES}/proxmox" <<'EOF_PATCH_CARGO'
from pathlib import Path
import re
import sys

cargo_toml = Path("Cargo.toml")
roots = [Path(arg) for arg in sys.argv[1:]]

def package_name_from_cargo_toml(path):
    in_package = False

    for line in path.read_text(errors="ignore").splitlines():
        stripped = line.strip()

        if stripped == "[package]":
            in_package = True
            continue

        if in_package and stripped.startswith("[") and stripped.endswith("]"):
            return None

        if in_package:
            match = re.match(r'name\s*=\s*"([^"]+)"', stripped)
            if match:
                return match.group(1)

    return None

patches = {}

for root in roots:
    if not root.exists():
        continue

    for path in root.rglob("Cargo.toml"):
        name = package_name_from_cargo_toml(path)
        if not name:
            continue

        # Keep the first match. Duplicate names should not normally happen,
        # but this avoids unstable output if they do.
        patches.setdefault(name, str(path.parent.resolve()))

required = [
    "perlmod",
    "perlmod-macro",
    "proxmox-acme",
    "proxmox-apt",
]

missing = [name for name in required if name not in patches]
if missing:
    raise SystemExit("Missing local Rust crate path(s): " + ", ".join(missing))

lines = cargo_toml.read_text().splitlines()
out = []
skip_patch_section = False

for line in lines:
    stripped = line.strip()

    if stripped == "[patch.crates-io]":
        skip_patch_section = True
        continue

    if skip_patch_section:
        if stripped.startswith("[") and stripped.endswith("]"):
            skip_patch_section = False
            out.append(line)
        continue

    out.append(line)

text = "\n".join(out).rstrip()
text += "\n\n[patch.crates-io]\n"

for name in sorted(patches):
    text += f'{name} = {{ path = "{patches[name]}" }}\n'

cargo_toml.write_text(text)
EOF_PATCH_CARGO

	echo "Cargo patches for libpmg-rs-perl:"
	awk '
		/^\[patch.crates-io\]/ { show=1 }
		show { print }
		show && NR > 1 && /^\[/ && $0 !~ /^\[patch.crates-io\]/ { show=0 }
	' Cargo.toml

	if [ -f debian/control ]; then
		set_package_info
	fi

	dpkg-buildpackage -b -us -uc ${BUILD_PROFILES}

	cd ../..

	find proxmox-perl-rs -maxdepth 2 -name "libpmg-rs-perl_${version}_${PACKAGE_ARCH}.deb" -exec mv -f {} "${PACKAGES}/" \;
	find proxmox-perl-rs -maxdepth 2 -name "libpmg-rs-perl-dbgsym_${version}_${PACKAGE_ARCH}.deb" -exec mv -f {} "${PACKAGES}/" \; 2>/dev/null || true

	if ! compgen -G "${PACKAGES}/libpmg-rs-perl_${version}_${PACKAGE_ARCH}.deb" >/dev/null; then
		echo "Could not find built libpmg-rs-perl package for version ${version}" >&2
		exit 1
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
	output_package=${4:-${repo_name}}

	if compgen -G "${PACKAGES}/${output_package}_${version}_*.deb" >/dev/null; then
		echo "${output_package} up-to-date"
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

	# The meta packages are useful while building to resolve dependency versions,
	# but they are not needed during install if all real subpackages are installed.
	rm -f "${PACKAGES}"/proxmox-mailgateway_*.deb
	rm -f "${PACKAGES}"/proxmox-mailgateway-container_*.deb

	# Kernel/header packages are not usable inside a container.
	if is_container; then
	    rm -f "${PACKAGES}"/pve-headers_*.deb
	    rm -f "${PACKAGES}"/proxmox-headers-*.deb
	    rm -f "${PACKAGES}"/proxmox-default-headers_*.deb
	fi

	mapfile -t file_list < <(find "${PACKAGES}" -maxdepth 1 -name '*.deb' -print | sort)

	if [ "${#file_list[@]}" -eq 0 ]; then
		echo "Error: no installable package files found" >&2
		return 1
	fi

	if ! ${SUDO} apt-get install -y "${file_list[@]}"; then
		echo "Error: failed to install downloaded PMG packages" >&2
		return 1
	fi

	rm -f -- "${file_list[@]}"
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

PMG_API_DEB="$(find_package_file pmg-api)"
PMG_GUI_DEB="$(find_package_file pmg-gui)"
PMG_DOCS_DEB="$(find_package_file pmg-docs)"

if [ -z "${PMG_API_DEB}" ]; then
	echo "Could not find downloaded pmg-api package" >&2
	exit 1
fi

if [ -z "${PMG_GUI_DEB}" ]; then
	echo "Could not find downloaded pmg-gui package" >&2
	exit 1
fi

if [ -z "${PMG_DOCS_DEB}" ]; then
	echo "Could not find downloaded pmg-docs package" >&2
	exit 1
fi

LIBPMG_RS_PERL_VERSION="$(dependency_package_version "${PMG_API_DEB}" libpmg-rs-perl amd64)"
LIBXDGMIME_PERL_VERSION="$(dependency_package_version "${PMG_API_DEB}" libxdgmime-perl amd64)"
PMG_MOBILE_QUARANTINE_UI_VERSION="$(dependency_package_version "${PMG_API_DEB}" pmg-mobile-quarantine-ui amd64)"

if [ -z "${LIBPMG_RS_PERL_VERSION}" ]; then
	echo "Could not resolve libpmg-rs-perl version" >&2
	exit 1
fi

if [ -z "${LIBXDGMIME_PERL_VERSION}" ]; then
	echo "Could not resolve libxdgmime-perl version" >&2
	exit 1
fi

if [ -z "${PMG_MOBILE_QUARANTINE_UI_VERSION}" ]; then
	echo "Could not resolve pmg-mobile-quarantine-ui version" >&2
	exit 1
fi

git_clone_or_fetch https://git.proxmox.com/git/proxmox-perl-rs.git
git_checkout_subdir_version proxmox-perl-rs pmg-rs "${LIBPMG_RS_PERL_VERSION}"

PERLMOD_VERSION="$(
	get_build_dependency_min_version \
		"proxmox-perl-rs/pmg-rs/debian/control" \
		"perlmod-bin"
)"

if [ -z "${PERLMOD_VERSION}" ]; then
	echo "Could not resolve required perlmod-bin version" >&2
	exit 1
fi

echo "Build perlmod ${PERLMOD_VERSION}"
build_perlmod "${PERLMOD_VERSION}"

git_clone_or_fetch https://git.proxmox.com/git/proxmox.git

echo "Build libpmg-rs-perl ${LIBPMG_RS_PERL_VERSION}"
build_libpmg_rs_perl "${LIBPMG_RS_PERL_VERSION}"

echo "Build libxdgmime-perl ${LIBXDGMIME_PERL_VERSION}"
build_make_deb_package \
	https://git.proxmox.com/git/libxdgmime-perl.git \
	libxdgmime-perl \
	"${LIBXDGMIME_PERL_VERSION}"

echo "Repackage pmg-mobile-quarantine-ui ${PMG_MOBILE_QUARANTINE_UI_VERSION}"
repackage_static_package_as_arch \
	pmg-mobile-quarantine-ui \
	"${PMG_MOBILE_QUARANTINE_UI_VERSION}"

echo "Download architecture-independent Proxmox dependencies"

download_dependency_package "${PMG_API_DEB}" libjs-qrcodejs all
download_dependency_package "${PMG_API_DEB}" libproxmox-acme-perl all
download_dependency_package "${PMG_API_DEB}" libproxmox-acme-plugins all
download_dependency_package "${PMG_API_DEB}" libproxmox-rs-perl all
download_dependency_package "${PMG_API_DEB}" libpve-apiclient-perl all
download_dependency_package "${PMG_API_DEB}" libpve-common-perl all
download_dependency_package "${PMG_API_DEB}" libpve-http-server-perl all
download_dependency_package "${PMG_API_DEB}" proxmox-enterprise-support-keyring all

download_dependency_package "${PMG_GUI_DEB}" libjs-extjs all
download_dependency_package "${PMG_GUI_DEB}" libjs-qrcodejs all
download_dependency_package "${PMG_GUI_DEB}" proxmox-widget-toolkit all

download_dependency_package "${PMG_DOCS_DEB}" libjs-extjs all
download_dependency_package "${PMG_API_DEB}" pve-xtermjs all

PBS_CONSTRAINT=$(get_dependency_constraint "${PMG_API_DEB}" proxmox-backup-client || true)

if [ -z "${PBS_CONSTRAINT}" ]; then
	PBS_CONSTRAINT=$(get_dependency_constraint "${PMG_META_DEB}" proxmox-backup-client || true)
fi

PBS_MIN_VERSION=$(dependency_version "${PBS_CONSTRAINT}")
PBS_MIN_VERSION=${PBS_MIN_VERSION%-*}

if [ -z "${PBS_MIN_VERSION}" ]; then
	echo "Could not resolve minimum proxmox-backup-client version" >&2
	exit 1
fi

PBS_ASSET="$(
	latest_github_release_asset \
		qemus/proxmox-backup-arm64 \
		proxmox-backup-client \
		"${PBS_MIN_VERSION}"
)"

if [ -z "${PBS_ASSET}" ]; then
	echo "Could not find proxmox-backup-client arm64 release >= ${PBS_MIN_VERSION}" >&2
	exit 1
fi

PBS_CLIENT_VERSION="${PBS_ASSET%%;*}"
PBS_ASSET_REST="${PBS_ASSET#*;}"
PBS_RELEASE_TAG="${PBS_ASSET_REST%%;*}"
PBS_ASSET_REST="${PBS_ASSET_REST#*;}"
PBS_CLIENT_URL="${PBS_ASSET_REST%%;*}"
PBS_CLIENT_FILE="${PBS_ASSET_REST#*;}"

echo "Resolved proxmox-backup-client:"
echo "  minimum required: ${PBS_MIN_VERSION}"
echo "  selected package: ${PBS_CLIENT_VERSION}"
echo "  release tag:      ${PBS_RELEASE_TAG}"
echo "  asset file:       ${PBS_CLIENT_FILE}"

download_external_package "${PBS_CLIENT_URL}"

JOURNALREADER_VERSION="1.6-1"
TERMPROXY_VERSION="2.1.0"

download_external_package \
	"https://github.com/qemus/proxmox-backup-arm64/releases/download/${PBS_RELEASE_TAG}/proxmox-mini-journalreader_${JOURNALREADER_VERSION}_arm64.deb"

download_external_package \
	"https://github.com/qemus/proxmox-backup-arm64/releases/download/${PBS_RELEASE_TAG}/proxmox-termproxy_${TERMPROXY_VERSION}_arm64.deb"

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
