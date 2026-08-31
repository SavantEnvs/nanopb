# syntax=docker/dockerfile:1.7
# Commit-image Dockerfile (SMALL form) — builds on the org C/C++ base image.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# nanopb's own build/test tooling (tests/SConstruct + tests/fuzztest/ossfuzz.sh, the harness this
# port reuses verbatim) is scons-driven and regenerates its .pb.c message sources at build time via
# protoc + the in-tree nanopb generator (needs the protobuf python bindings). None of this touches
# the network at build.sh time — everything is resolved from these apt packages, baked in now.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        scons protobuf-compiler python3-protobuf \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
