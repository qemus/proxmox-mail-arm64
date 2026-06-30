ARG baseimage=debian:trixie-slim

FROM ${baseimage} AS builder-stage

ARG buildoptions
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential \
	ca-certificates \
	curl \
	devscripts \
	dpkg-dev \
	equivs \
	faketime \
	git \
	lintian \
	pkg-config \
	rsync \
	sudo \
	jq \
	dh-cargo \
	&& rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN echo "deb http://download.proxmox.com/debian/devel trixie main" \
	> /etc/apt/sources.list.d/proxmox-devel.list && \
	apt-get update

COPY . /build/
WORKDIR /build

SHELL ["/bin/bash", "-c"]

RUN chmod +x ./build.sh
RUN source ~/.cargo/env && ./build.sh ${buildoptions}
RUN touch /build/build.log

FROM scratch

COPY --from=builder-stage /build/*.log /build/packages/* /
