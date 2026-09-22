FROM golang:1.25-bookworm AS build
WORKDIR /build
COPY go.mod go.sum ./
COPY cmd ./cmd
COPY db ./db
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /memento ./cmd/memento

FROM debian:bookworm-slim AS api
COPY --from=build /memento /usr/local/bin/memento
RUN useradd --create-home --uid 10001 memento
USER memento
EXPOSE 8067
ENTRYPOINT ["memento"]
CMD ["api"]

FROM docker:27-cli AS worker
COPY --from=build /memento /usr/local/bin/memento
ENTRYPOINT ["memento"]
CMD ["worker"]
