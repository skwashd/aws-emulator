# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#
# AWS Emulator on Debian 13 (trixie) slim.
#
# Supply chain controls:
#   * The .deb is downloaded and GPG-verified in a throwaway stage; only the
#     verified package is copied into the final image.
#   * The signing key's primary fingerprint is pinned below. The build fails
#     unless gpg reports VALIDSIG made by exactly that key, so a swapped key
#     file or a signature from any other key is rejected.
#   * Optional EMULATOR_SHA256 pins the exact package bytes as well.
#   * Downloads are HTTPS-only (no protocol downgrade on redirect).
#   * Runtime runs as a non-root user with no download/verification tooling.
#
# Build (pinned version recommended — see versions.json):
#   docker build --build-arg EMULATOR_VERSION=<x.y.z> -t aws-emulator .
# Multi-arch:
#   docker buildx build --platform linux/amd64,linux/arm64 -t aws-emulator .
#
# Run (publish on loopback only):
#   docker run --rm --memory=2g --memory-swap=2g \
#     -p 127.0.0.1:9297:9297 \
#     -v "$HOME/.aws/emulator:/home/emulator/.aws/emulator" \
#     aws-emulator

# Base image pinned by digest, in one place, as a literal FROM so Dependabot
# can see and bump it. Both stages below build from this.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS base

############################
# Stage 1: download + verify
############################
FROM base AS verify

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
WORKDIR /work

# Tooling first, before any ARGs: build args are part of every later RUN's
# cache key, so declaring them after this keeps the layer cached when the
# version/hash changes.
RUN apt update \
 && apt install -y --no-install-recommends ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# "latest" or a specific release from
# https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json
ARG EMULATOR_VERSION=latest
# Optional: expected sha256 of the .deb. Strongly recommended with a pinned version.
ARG EMULATOR_SHA256=""
# Per-arch pins (take precedence over EMULATOR_SHA256) for multi-arch builds,
# since each architecture's .deb has different bytes.
ARG EMULATOR_SHA256_AMD64=""
ARG EMULATOR_SHA256_ARM64=""
# AWS publishing key fingerprint, per the AWS Emulator user guide.
ARG AWS_SIGNING_KEY_FPR=98BCF336A3BE53B734E967C52E5BF49BD940F624
# Set automatically by BuildKit (amd64 / arm64).
ARG TARGETARCH

ARG BASE_URL=https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS
ARG KEY_URL=https://downloads.aws.com/keys/gpg/current.asc

RUN <<'EOF'
case "${TARGETARCH:-$(dpkg --print-architecture)}" in
  amd64) arch=amd64 ;;
  arm64) arch=arm64 ;;
  *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
esac

if [ "${EMULATOR_VERSION}" = "latest" ]; then
  url="${BASE_URL}/latest/aws-emulator_${arch}.deb"
  echo "WARNING: building from 'latest'; pin EMULATOR_VERSION for reproducible builds." >&2
else
  # Reject anything that isn't a plain MAJOR.MINOR.PATCH to keep the URL sane.
  [[ "${EMULATOR_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "Invalid EMULATOR_VERSION: ${EMULATOR_VERSION}" >&2; exit 1; }
  url="${BASE_URL}/aws-emulator_${EMULATOR_VERSION}-1_${arch}.deb"
fi

dl() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"; }
dl "${url}"      aws-emulator.deb
dl "${url}.sig"  aws-emulator.deb.sig
dl "${KEY_URL}"  aws-publishing.asc

export GNUPGHOME="$(mktemp -d)"
chmod 700 "${GNUPGHOME}"
gpg --batch --quiet --import aws-publishing.asc

# 1. The pinned key must be present in the downloaded key file.
gpg --batch --with-colons --fingerprint "${AWS_SIGNING_KEY_FPR}" \
  | awk -F: '$1=="fpr"{print $10}' | grep -qx "${AWS_SIGNING_KEY_FPR}" \
  || { echo "Signing key fingerprint mismatch — refusing to continue." >&2; exit 1; }

# 2. The signature must be valid AND made by the pinned key (primary fpr is
#    the last field of VALIDSIG, so subkey signatures are handled too).
gpg --batch --status-fd 3 --verify aws-emulator.deb.sig aws-emulator.deb \
    3>gpg-status 2>gpg-output \
  || { cat gpg-output >&2; echo "BAD signature — refusing to continue." >&2; exit 1; }
awk -v fpr="${AWS_SIGNING_KEY_FPR}" \
    '$1=="[GNUPG:]" && $2=="VALIDSIG" && ($3==fpr || $NF==fpr){ok=1} END{exit !ok}' gpg-status \
  || { cat gpg-status >&2; echo "Signature not made by pinned AWS key." >&2; exit 1; }
cat gpg-output

# 3. Optional byte-level pin (per-arch value wins over the generic one).
case "${arch}" in
  amd64) expected="${EMULATOR_SHA256_AMD64:-${EMULATOR_SHA256}}" ;;
  arm64) expected="${EMULATOR_SHA256_ARM64:-${EMULATOR_SHA256}}" ;;
esac
if [ -n "${expected}" ]; then
  echo "${expected}  aws-emulator.deb" | sha256sum -c -
fi

# 4. Sanity-check the package metadata.
[ "$(dpkg-deb -f aws-emulator.deb Package)" = "aws-emulator" ]
[ "$(dpkg-deb -f aws-emulator.deb Architecture)" = "${arch}" ]
dpkg-deb -f aws-emulator.deb Package Version Architecture Depends

mkdir -p /out && mv aws-emulator.deb /out/
rm -rf "${GNUPGHOME}"
EOF

############################
# Stage 2: runtime
############################
FROM base

ARG EMULATOR_UID=1000

LABEL org.opencontainers.image.title="aws-emulator" \
      org.opencontainers.image.description="AWS Emulator on Debian trixie-slim (GPG-verified package)" \
      org.opencontainers.image.base.name="debian:trixie-slim" \
      org.opencontainers.image.source="https://github.com/skwashd/aws-emulator" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install only the verified package (apt resolves its declared dependencies)
# and pick up any pending Debian security updates.
RUN --mount=type=bind,from=verify,source=/out,target=/pkg \
    apt update \
 && apt upgrade -y --no-install-recommends \
 && apt install -y --no-install-recommends ca-certificates /pkg/aws-emulator.deb \
 && apt clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/apt/* /var/log/dpkg.log \
 && useradd --uid "${EMULATOR_UID}" --user-group --home-dir /home/emulator \
      --create-home --shell /usr/sbin/nologin emulator \
 && aws-emulator -v

USER ${EMULATOR_UID}
# Telemetry is opt-out upstream; default it off here. Override with
# -e EMULATOR_TELEMETRY=on if you want to send usage data to AWS.
ENV HOME=/home/emulator \
    EMULATOR_TELEMETRY=off
WORKDIR /home/emulator

EXPOSE 9297

# Bind all interfaces inside the container so Docker can forward the port.
# Publish it on 127.0.0.1 only (-p 127.0.0.1:9297:9297), never -p 9297:9297.
ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]
