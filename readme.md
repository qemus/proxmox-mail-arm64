# proxmox-mail-gateway-arm64

[![Build]][build_url]
[![Version]][release_url]
[![Size]][release_url]

Script for building Proxmox Mail Gateway **9.x** for ARM64.

## Download pre-built packages

You can find unofficial Debian packages that are created with the build.sh script at [https://github.com/qemus/proxmox-mail-arm64/releases](https://github.com/qemus/proxmox-mail-arm64/releases).

With the script you can also download or install all packages of the latest release automatically.

**Download and install**

`./build.sh install` or a specific version `./build.sh install=9.1`

**Download only**

`./build.sh download` or a specific version `./build.sh download=9.1`

## Build manually

### Install build essentials and dependencies

```bash
apt-get install -y --no-install-recommends \
	build-essential curl ca-certificates sudo git lintian fakeroot jq rsync \
	pkg-config libudev-dev libssl-dev libapt-pkg-dev libclang-dev \
	libpam0g-dev libcrypt-dev libacl1-dev libsystemd-dev \
	libfuse3-dev libldap2-dev libzstd-dev \
	zlib1g-dev nettle-dev uuid-dev
```

### Install `rustup`

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s
source ~/.cargo/env
```

### Start build script

```bash
./build.sh
```

The compilation will take about 10 minutes.  
After that you can find the finished packages in the folder `packages/`.

## Build using Docker

You can build ARM64 `.deb` packages using the provided Dockerfile and docker buildx:

```bash
docker buildx build -o packages --platform linux/arm64 .
```

You can also set build arguments for base image and build.sh options:

```bash
docker buildx build -o packages --build-arg buildoptions="debug" --build-arg baseimage=debian:trixie-slim --platform linux/arm64 .
```

Once the Docker build is completed, packages will be copied from the docker build image to a folder named `packages` in the root folder.

### Start build script

```bash
./build.sh cross
```

## Install packages

```bash
sudo apt install ./*.deb
```

## Help section

### Debugging

You can add the debug option to redirect the complete build process output also to a file (`build.log`):

```bash
./build.sh debug
```

## Stars 🌟
[![Stargazers](https://raw.githubusercontent.com/star-stats/stars/refs/heads/data/charts/qemus-proxmox-mail-arm64.svg)](https://github.com/qemus/proxmox-mail-arm64/stargazers)

[build_url]: https://github.com/qemus/proxmox-mail-arm64/
[release_url]: https://github.com/qemus/proxmox-mail-arm64/releases/

[Build]: https://github.com/qemus/proxmox-mail-arm64/actions/workflows/release.yml/badge.svg
[Size]: https://img.shields.io/badge/size-20.3_MB-steelblue?style=flat&color=066da5
[Version]: https://img.shields.io/github/v/tag/qemus/proxmox-mail-arm64?label=version&sort=semver&color=066da5
