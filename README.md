# AWS Emulator Docker Image

Recently AWS released their new
[Emulator](https://docs.aws.amazon.com/emulator/). It is an excellent
[project fully built by 
agents](https://www.aboutamazon.com/news/aws/how-autonomous-ai-agents-built-aws-emulator). 
RIP LocalStack! 🪦

There were a few problem with how the emulator is distributed. This project
sets out to solve them.

## Prebuilt Docker Image

AWS chose not to provide prebuilt images via the [ECR public container
repository](https://public.ecr.aws/). This means users on macOS and Windows
need to build their own image before they can start to use the emulator. Not
the best experience.

Images are published to GHCR for `linux/amd64` and `linux/arm64`:

```sh
docker pull ghcr.io/skwashd/aws-emulator:latest
```

Tags:

* `<emulator-version>` (e.g. `1.0.485`): that emulator version in the
  newest release of this repo.
* `<emulator-version>-<release>` (e.g. `1.0.485-2.1.0`): immutable.
* `latest`: the newest emulator version in the newest release.

Each image carries SLSA provenance and an SBOM.

## Security Could be Better

If you talk to anyone from AWS long enough you'll hear the phrase "Security
is day zero". The [docker
docs](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html)
missed that memo. The default instructions skip validating the signature of
the download. Yes, it is more effort, but it should be the default.

A lot of this could be avoided if the team offer a package repository. Then
the emulator would be a `apt`/`dnf`/`yum` install away. The distro packages
are available, but the manifest files are missing.

## Debian Images

The instructions recommend using Amazon Linux 2023. I like Amazon Linux, but
Debian slim has become my go to base image these days. It also saves a few
megabytes over AL23.

These images are based on the latest version of trixie-slim.

## Run the Image

```sh
PORT="9297"
docker run --rm \
  --memory=2g \
  --memory-swap=2g \
  -p "127.0.0.1:$PORT:$PORT" \
  -e HOME="$HOME" \
  -v "$HOME/.aws/emulator:/home/emulator/.aws/emulator" \
  skwashd/aws-emulator -p $PORT
```
