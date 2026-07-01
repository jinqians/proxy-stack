{
  "type": "vless",
  "tag": "PSM-{{TAG}}",
  "server": "{{SERVER_IP}}",
  "server_port": 443,
  "uuid": "{{UUID}}",
  "flow": "{{FLOW}}",
  "tls": {
    "enabled": true,
    "server_name": "{{SERVER_NAME}}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "{{PUBLIC_KEY}}",
      "short_id": "{{SHORT_ID}}"
    }
  }
}
