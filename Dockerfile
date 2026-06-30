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
	git \
	lintian \
	pkg-config \
	rsync \
	sudo \
	jq \
	&& rm -rf /var/lib/apt/lists/*

COPY . /build/
WORKDIR /build

SHELL ["/bin/bash", "-c"]

RUN chmod +x ./build.sh
RUN ./build.sh ${buildoptions}
RUN touch /build/build.log

FROM scratch

COPY --from=builder-stage /build/*.log /build/packages/* /
