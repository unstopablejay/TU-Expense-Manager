# The self-hosted half of TU Expense Tracker: the API and the web UI, in one
# image, on one port.
#
#   docker build -t tu-expense-server .
#   docker run -p 8099:8099 -v expense-data:/data \
#     -e EXPENSE_ADMIN_USER=jay -e EXPENSE_ADMIN_PASSWORD='...' tu-expense-server
#
# Two stages. The builder is large and cached; the runtime is a slim Debian with
# a static-ish binary and the web assets, and nothing else — no Flutter, no Dart
# SDK, no shell utilities brought in just for a healthcheck.

# -----------------------------------------------------------------------------
# Stage 1 — build the web bundle and compile the server
# -----------------------------------------------------------------------------
#
# One builder for both, because the Flutter SDK bundles the Dart SDK: a separate
# dart:stable stage would download a second toolchain to do what this one already
# can.
#
# Flutter is installed from git at an exact tag rather than from a published
# image. ghcr.io/cirruslabs/flutter stops at 3.44.0, and this project is pinned to
# 3.47.0 in .github/workflows/release.yml — building the web bundle with a
# different Flutter than the APK is built with is the kind of skew that produces a
# bug nobody can reproduce. Tag 3.47.0 is revision 4cf2416426, which is exactly
# what .metadata records.
FROM debian:bookworm-slim AS builder

ARG FLUTTER_VERSION=3.47.0

# Flutter's own dependencies. `--no-install-recommends` keeps this from pulling in
# a hundred megabytes of suggestions that never get used.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      unzip \
      xz-utils \
      zip \
    && rm -rf /var/lib/apt/lists/*

# A non-root user to build as. Flutter is unhappy being run as root, and a build
# that emits warnings nobody reads is a build whose real warnings get missed.
RUN useradd --create-home --shell /bin/bash builder
USER builder
WORKDIR /home/builder

ENV FLUTTER_HOME=/home/builder/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"

# --depth 1 at the tag: the full history is about a gigabyte and none of it is
# needed to run the tool.
# precache --web rather than letting the first `flutter` command decide: the
# default fetches engine artifacts for every platform it thinks it might need,
# which is hundreds of megabytes of Android and desktop material this stage will
# never compile.
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
      https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
 && flutter config --no-analytics --no-cli-animations \
 && flutter precache --web --universal \
 && flutter --version

WORKDIR /src

# Dependencies before sources, so editing a Dart file does not re-resolve the
# whole pub cache on every build.
COPY --chown=builder:builder pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY --chown=builder:builder server/pubspec.yaml server/pubspec.lock ./server/
RUN cd server && dart pub get

COPY --chown=builder:builder analysis_options.yaml ./
COPY --chown=builder:builder lib ./lib
COPY --chown=builder:builder web ./web
COPY --chown=builder:builder server ./server

# --no-web-resources-cdn is load-bearing, not a preference.
#
# Without it a release build fetches ~36 MB of CanvasKit from gstatic.com at
# runtime. On a NAS with no internet — which is the whole point of self-hosting —
# that means a permanently blank page that looks exactly like a broken app. With
# it, the wasm ships in build/web/canvaskit/ and the generated buildConfig carries
# "useLocalCanvasKit":true, which is what makes the bundled copy the one used.
RUN flutter build web --release --no-web-resources-cdn -t lib/main_web.dart

# A native binary rather than `dart run`: it starts in milliseconds, needs no SDK
# in the runtime image, and cannot be affected by a stray pub cache.
RUN cd server && dart compile exe bin/server.dart -o /home/builder/server

# -----------------------------------------------------------------------------
# Stage 2 — the runtime
# -----------------------------------------------------------------------------
#
# `dart compile exe` output is not fully static: it links against glibc, so slim
# is the floor here and `scratch` or a static-only distroless will not run it.
FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="TU Expense Tracker server"
LABEL org.opencontainers.image.description="Self-hosted snapshot store and web UI for TU Expense Tracker"
LABEL org.opencontainers.image.source="https://github.com/unstopablejay/TU-Expense-Manager"
LABEL org.opencontainers.image.licenses="NOASSERTION"

# No ca-certificates on purpose: this server makes no outbound requests except a
# plain-HTTP healthcheck to itself. Adding a trust store would be adding an
# attack surface to solve a problem that does not exist here.
RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin expense \
 && mkdir -p /data /app \
 && chown -R expense:expense /data /app

COPY --from=builder --chown=expense:expense /home/builder/server /app/server
COPY --from=builder --chown=expense:expense /src/build/web /app/web

USER expense
WORKDIR /app

ENV PORT=8099
ENV DATA_DIR=/data
ENV WEB_ROOT=/app/web

# Declared so `docker run` without an explicit mount still keeps its data across
# a container replacement, which is the mistake everyone makes once.
VOLUME ["/data"]
EXPOSE 8099

# The binary is its own healthcheck, so the image needs no curl. That utility's
# only job here would have been this one request.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/server", "--healthcheck"]

ENTRYPOINT ["/app/server"]
