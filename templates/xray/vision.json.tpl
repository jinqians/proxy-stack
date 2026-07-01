{
  "tag": "{{TAG}}",
  "listen": "127.0.0.1",
  "port": {{PORT}},
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "{{UUID}}",
        "flow": "{{FLOW}}"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "{{CERT_DIR}}/fullchain.pem",
          "keyFile": "{{CERT_DIR}}/privkey.pem"
        }
      ],
      "minVersion": "1.2",
      "alpn": ["h2", "http/1.1"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
