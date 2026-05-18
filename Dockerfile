# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

################################################################################

FROM --platform=${BUILDPLATFORM} golang:1.26 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.sum ./
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -o /workspace ./...

################################################################################

FROM --platform=${BUILDPLATFORM} golang:1.26 AS debug-builder
ARG TARGETOS
ARG TARGETARCH
ARG DELVE_VERSION=latest

WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go install github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}

COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -gcflags=all="-N -l" -o /workspace ./...

################################################################################

# Ref: https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot AS scheduler
WORKDIR /
COPY --from=builder /workspace/scheduler .
USER 65532:65532
ENTRYPOINT ["/scheduler"]

################################################################################

# Ref: https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot AS controllers
WORKDIR /
COPY --from=builder /workspace/controllers .
USER 65532:65532
ENTRYPOINT ["/controllers"]

################################################################################

# Ref: https://github.com/GoogleContainerTools/distroless
FROM gcr.io/distroless/static:nonroot AS admission
WORKDIR /
COPY --from=builder /workspace/admission .
USER 65532:65532
ENTRYPOINT ["/admission"]

################################################################################

FROM gcr.io/distroless/static:debug-nonroot AS debug-base
WORKDIR /
ENV PATH="/busybox:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
COPY --from=debug-builder /go/bin/dlv .
COPY hack/debug/dlv-reload-wrapper.sh /dlv-reload-wrapper
COPY --chown=65532:65532 hack/debug/keep /workspace/next/.keep
COPY --chown=65532:65532 hack/debug/keep /tmp/skaffold-sync/.keep
USER 65532:65532
ENTRYPOINT ["/dlv-reload-wrapper"]

################################################################################

FROM debug-base AS scheduler-debug
COPY --chown=65532:65532 --from=debug-builder /workspace/scheduler /workspace/scheduler

################################################################################

FROM debug-base AS controllers-debug
COPY --chown=65532:65532 --from=debug-builder /workspace/controllers /workspace/controllers

################################################################################

FROM debug-base AS admission-debug
COPY --chown=65532:65532 --from=debug-builder /workspace/admission /workspace/admission
