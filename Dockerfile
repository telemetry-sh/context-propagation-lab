FROM dart:3.12.2 AS build

WORKDIR /source
COPY pubspec.yaml analysis_options.yaml ./
COPY bin ./bin
COPY lib ./lib
RUN dart compile exe bin/server.dart -o /out/context-propagation-lab

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 lab

WORKDIR /app
COPY --from=build /out/context-propagation-lab /app/context-propagation-lab
COPY public /app/public

ENV HOST=0.0.0.0
ENV PORT=8080
EXPOSE 8080
USER lab

HEALTHCHECK --interval=5s --timeout=2s --start-period=2s --retries=12 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/context-propagation-lab"]
