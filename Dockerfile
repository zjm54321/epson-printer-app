FROM --platform=linux/amd64 ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b AS runtime-base
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Ordinary Noble security updates are intentional. Record the resolved packages;
# this is source-traceable, not a claim of bit-identical apt reproduction.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates libcap2-bin \
    && mkdir -p /usr/share/epson-printer-app \
    && dpkg-query -W -f='${Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
       > /usr/share/epson-printer-app/base-packages.tsv \
    && rm -rf /var/lib/apt/lists/*

FROM runtime-base AS discovery-build
COPY scripts/discovery-entrypoint.sh /usr/local/bin/epson-discovery-entrypoint
COPY discovery/ /etc/epson-discovery/
COPY scripts/build-discovery.sh /recipe/scripts/build-discovery.sh
RUN bash /recipe/scripts/build-discovery.sh

FROM runtime-base AS build
COPY Dockerfile .dockerignore sources.lock.json THIRD_PARTY.md /recipe/
COPY scripts/build-*.sh scripts/entrypoint.sh scripts/discovery-entrypoint.sh scripts/verify-image.sh /recipe/scripts/
COPY patches/ /recipe/patches/
COPY discovery/ /recipe/discovery/
COPY tests/ /recipe/tests/
RUN bash /recipe/scripts/build-dependencies.sh
RUN bash /recipe/scripts/build-fetch.sh
RUN bash /recipe/scripts/build-stack.sh
RUN bash /recipe/scripts/build-ppds.sh
RUN bash /recipe/scripts/build-runtime.sh

FROM build AS source-collection
COPY --from=discovery-build /discovery-source/manifests/discovery-packages.tsv /corresponding-source/manifests/discovery-packages.tsv
COPY --from=discovery-build /discovery-source/licenses/ /corresponding-source/licenses/discovery/
RUN bash /recipe/scripts/build-sources.sh

FROM scratch AS sources
COPY --from=source-collection /corresponding-source/ /

FROM runtime-base AS runtime
COPY --from=build /runtime/ /
RUN ldconfig \
    && groupadd --gid 584792 printer \
    && useradd --uid 584792 --gid 584792 --home-dir /state --no-create-home --shell /usr/sbin/nologin printer \
    && install -d -m 0700 -o 584792 -g 584792 /state \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} + \
    && getcap -r / 2>/dev/null | while read -r path _; do setcap -r "$path"; done
ENV HOME=/state \
    LD_LIBRARY_PATH=/usr/lib \
    STATE_DIR=/state/state \
    SPOOL_DIR=/state/spool \
    BACKEND_DIR=/usr/lib/ghostscript-printer-app/backend \
    FILTER_DIR=/usr/lib/ghostscript-printer-app/filter \
    PPD_PATHS=/usr/share/ppd/epson \
    TMPDIR=/tmp \
    LANG=C.UTF-8
USER 584792:584792
WORKDIR /state
# Deliberately no VOLUME, EXPOSE, healthcheck or automatic server/discovery.
ENTRYPOINT ["/usr/local/bin/epson-entrypoint"]
CMD ["help"]

FROM discovery-build AS discovery
USER 584792:584792
ENV HOME=/tmp AVAHI_INTERFACES=eth0 AVAHI_HOST_NAME=epson-printer
ENTRYPOINT ["/usr/local/bin/epson-discovery-entrypoint"]
CMD ["help"]
