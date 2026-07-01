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
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "{{DEST}}",
      "xver": 0,
      "serverNames": ["{{SERVER_NAME}}"],
      "privateKey": "{{PRIVATE_KEY}}",
      "shortIds": ["{{SHORT_ID}}"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
