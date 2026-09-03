# gNB and UE simulator, plus a SIP user agent for the UE side.
#
# free-ran-ue replaces UERANSIM here. Two things about it matter for this PoC:
#
#   * It does GTP-U in user space (a TUN device driven from Go), so nothing on
#     the RAN/UE side needs the gtp5g kernel module. Only the UPF does.
#   * It brings the tunnel up with an address but sets NO routes, so the
#     entrypoint below still has to steer traffic into it -- same as before.
#
# Upstream ships no image and deploys with host network namespaces; this builds
# a container instead so the RAN sits inside the same two-network topology as
# the rest of the PoC.

FROM golang:1.26-bookworm AS builder

ARG FRU_VERSION=v2.5.0
WORKDIR /src

RUN git clone --depth 1 --branch ${FRU_VERSION} \
      https://github.com/free-ran-ue/free-ran-ue.git . \
 && go build -trimpath -o /out/free-ran-ue main.go

FROM debian:trixie-slim

# sip-tester is SIPp: the UE runs it *inside* the container so the SIP traffic
# is bound to the tunnel interface and has to travel over the user plane.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      iproute2 \
      iputils-ping \
      iptables \
      tcpdump \
      sip-tester \
      procps \
      ncat \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/free-ran-ue /usr/local/bin/free-ran-ue
COPY entrypoint-gnb.sh /entrypoint-gnb.sh
COPY entrypoint-ue.sh  /entrypoint-ue.sh
COPY sipp /sipp
RUN chmod +x /entrypoint-gnb.sh /entrypoint-ue.sh

WORKDIR /ran
