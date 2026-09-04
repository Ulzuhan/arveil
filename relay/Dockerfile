# The relay as a single static binary on a base with nothing else in it.
# Build from the repository root:  docker build -f relay/Dockerfile -t arveil-relay .
FROM golang:1.27-bookworm AS build
WORKDIR /src
COPY relay/go.mod relay/go.sum ./relay/
RUN cd relay && go mod download
COPY relay ./relay
ARG REVISION=""
# CGO off: modernc.org/sqlite is pure Go, so the result runs on a base with
# no libc and no shell (ADR-004's single binary, taken literally).
RUN cd relay && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/Ulzuhan/arveil/relay/internal/version.Revision=${REVISION}" \
      -o /out/arveil-relay ./cmd/arveil-relay

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/arveil-relay /arveil-relay
# The data directory holds realm.db, the realm's keys and the blobs. Mount a
# volume here or the realm is new on every restart.
VOLUME ["/data"]
EXPOSE 8447 9090
USER nonroot:nonroot
ENTRYPOINT ["/arveil-relay"]
CMD ["-data-dir", "/data", "-listen", "0.0.0.0:8447", "-admin-listen", "127.0.0.1:9090"]
