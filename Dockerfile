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
	gcc-aarch64-linux-gnu \
	qemu-user \
	qemu-user-binfmt \
	&& rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

COPY . /build/
WORKDIR /build

SHELL ["/bin/bash", "-c"]

RUN chmod +x ./build.sh
RUN ./build.sh ${buildoptions}
RUN touch /build/build.log

FROM scratch

COPY --from=builder-stage /build/*.log /build/packages/* /
