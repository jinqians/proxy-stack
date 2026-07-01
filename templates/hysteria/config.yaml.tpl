# Hysteria2 server config — PSM managed

listen: :443

tls:
  cert: {{CERT_DIR}}/fullchain.pem
  key:  {{CERT_DIR}}/privkey.pem

auth:
  type: password
  password: "{{PASSWORD}}"

masquerade:
  type: proxy
  proxy:
    url: https://{{DOMAIN}}
    rewriteHost: true

bandwidth:
  up:   {{UP_BW}}
  down: {{DOWN_BW}}

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow:  26843545
  initConnReceiveWindow:   67108864
  maxConnReceiveWindow:    67108864

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: "80,443,8000-9000"
  udpPorts: "all"
