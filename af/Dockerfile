# The AF shim: the piece that lets the P-CSCF act as an Application Function.
#
# It exists because the two sides speak different protocols. Kamailio's ims_qos
# module talks Rx -- Diameter, the 4G interface -- and free5gc has no Rx at all;
# its PCF exposes Npcf_PolicyAuthorization over the 5G SBI, which is HTTP/2
# without TLS (h2c). Kamailio's http_client is libcurl and does not do h2c with
# prior knowledge, so nothing in kamailio can reach the PCF directly.
#
# This service bridges exactly that gap and nothing else: plain HTTP/1.1 on the
# side kamailio calls, h2c on the side that calls the PCF.
FROM golang:alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download golang.org/x/net || true
COPY main.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -o /out/af .

FROM alpine:3.21
RUN apk add --no-cache curl
COPY --from=builder /out/af /usr/local/bin/af
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/af"]
