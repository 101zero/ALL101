# builder: يبني nuclei و notify باستخدام go
FROM golang:1.24-bullseye AS builder

ENV CGO_ENABLED=0
ENV GO111MODULE=on
ENV GOPATH=/go

WORKDIR /build

RUN go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
RUN go install -v github.com/projectdiscovery/notify/cmd/notify@latest

# runtime
FROM debian:bookworm-slim

RUN mkdir -p /data /secrets /nuclei-templates

# انسخ البايناري من البيلدر
COPY --from=builder /go/bin/nuclei /usr/local/bin/nuclei
COPY --from=builder /go/bin/notify /usr/local/bin/notify

# أدوات تشغيل بسيطة
RUN apt-get update -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wget unzip ca-certificates curl jq && \
    rm -rf /var/lib/apt/lists/*

COPY run.sh /usr/local/bin/run-nuclei.sh
RUN chmod +x /usr/local/bin/run-nuclei.sh

WORKDIR /data
ENTRYPOINT [ "/usr/local/bin/run-nuclei.sh" ]
