# en/cert.sh — SSL certificate module English messages (assign MSG[...] only; do not declare).

MSG[cert.acme.already_installed]="acme.sh is already installed."
MSG[cert.acme.ask_email]="Certificate registration email"
MSG[cert.acme.install_failed]="acme.sh installation failed; executable not found: %s"
MSG[cert.acme.installed]="acme.sh installed, and the automatic renewal cron job is set."
MSG[cert.ca.menu]="  CA:
  1. Let's Encrypt (default)
  2. ZeroSSL
  3. Google Trust Services"
MSG[cert.ca.select]="Select [1]: "

MSG[cert.rate.limit_error]="%s hit the Let's Encrypt rate limit (rateLimited / too many certificates)."
MSG[cert.rate.rule_same_set]="This limit is calculated for the exact same set of domains: up to 5 certificates per 7 days,"
MSG[cert.rate.no_dns_bypass]="and is independent of the validation method. DNS-01 cannot bypass it, so validation will not be retried automatically."
MSG[cert.rate.retry_time]="Let's Encrypt retry time: %s"
MSG[cert.rate.options]="
  Two options:
    A. Wait until the retry time above and issue again
    B. Switch to another CA (ZeroSSL / Google Trust Services have independent quotas)
"
MSG[cert.rate.ask_zerossl]="Switch to ZeroSSL and retry now?"
MSG[cert.rate.switch_zerossl_failed]="Failed to switch the default CA to ZeroSSL."
MSG[cert.rate.zerossl_failed]="ZeroSSL issuance failed."
MSG[cert.rate.zerossl_need_email]="ZeroSSL requires a registered account email. You can run:"
MSG[cert.rate.zerossl_register_cmd]="    acme.sh --register-account -m <your-email> --server zerossl"
MSG[cert.rate.zerossl_retry_after_register]="After registration, issue the certificate again."

MSG[cert.http.standalone]="Nginx is not running; using standalone mode..."
MSG[cert.http.check_points]="Confirm the following, otherwise issuance will fail:"
MSG[cert.http.need_port80_cloud]="    1. Cloud security group / console firewall allows inbound TCP 80"
MSG[cert.http.need_port80_local]="    2. No other local process is using port 80
"
MSG[cert.http.fw_opened]="Temporarily opened local firewall port 80 (%s)"
MSG[cert.http.fw_restored]="Restored firewall rule (%s)"
MSG[cert.cached.installing]="Certificate is already in the acme.sh cache; installing to %s."
MSG[cert.issue.failed_domain]="Certificate issuance for %s failed."
MSG[cert.http.conn_refused_hint]="If the error is 'Connection refused', the cloud security group is blocking port 80 at the network layer,"
MSG[cert.http.iptables_cannot_fix]="and local iptables cannot fix it. Options:"
MSG[cert.http.solution_open80]="    A. Allow inbound TCP 80 in the cloud console, then close it after issuance"
MSG[cert.http.solution_dns01]="    B. Use DNS-01 instead (no open port required)
"
MSG[cert.http.cf_token_detected]="Cloudflare API Token is already configured; DNS-01 can be retried directly."
MSG[cert.http.ask_dns_retry]="Switch to DNS-01 (Cloudflare) and issue again now?"
MSG[cert.http.dns_failed_cf]="DNS-01 also failed. Check Cloudflare Token permissions (requires Zone:DNS:Edit)."

MSG[cert.ask_domain]="Domain"
MSG[cert.invalid_domain]="Invalid domain"
MSG[cert.ask_domain_wildcard]="Domain (wildcard supported, e.g. *.example.com)"
MSG[cert.dns_api.menu5]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. CloudXNS
  5. Manual"
MSG[cert.dns_api.menu4]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. Manual"
MSG[cert.dns_provider.select]="DNS provider [1]: "
MSG[cert.ask_ali_key]="Alibaba Cloud Access Key ID"
MSG[cert.ask_ali_secret]="Alibaba Cloud Access Key Secret"
MSG[cert.ask_ali_key_short]="Alibaba Cloud Key ID"
MSG[cert.ask_ali_secret_short]="Alibaba Cloud Secret"
MSG[cert.invalid_option]="Invalid option"
MSG[cert.issue.failed]="Issuance failed"

MSG[cert.import.ask_cert_file]="Full certificate file path (fullchain.pem)"
MSG[cert.import.ask_key_file]="Private key file path (privkey.pem)"
MSG[cert.import.ask_ca_file]="CA chain file path (optional, press Enter to skip)"
MSG[cert.import.cert_not_found]="Certificate file not found"
MSG[cert.import.key_not_found]="Private key file not found"
MSG[cert.import.cert_not_found_path]="Certificate file not found: %s"
MSG[cert.import.key_not_found_path]="Private key file not found: %s"
MSG[cert.import.imported_to]="Certificate imported to %s"
MSG[cert.install.installed]="Certificate installed: %s"
MSG[cert.install.installed_to]="Certificate installed to %s"

MSG[cert.renew.ask_domain]="Domain (leave empty to renew all)"
MSG[cert.renew.ask_force]="Force renewal? (ignores validity period and may hit Let's Encrypt rate limits)"
MSG[cert.renew.not_due]="Certificate is not due for renewal; skipped. Force renewal is optional if needed."
MSG[cert.renew.failed]="Renewal failed"
MSG[cert.auto_renew.installed]="Automatic renewal cron job installed."

MSG[cert.delete.ask_domain]="Domain to delete"
MSG[cert.domain_required]="Domain cannot be empty."
MSG[cert.delete.ask_local]="Also delete local files under %s?"
MSG[cert.delete.deleted]="Certificate deleted."
MSG[cert.cf.ask_token]="Cloudflare API Token (with Zone DNS edit permission)"

MSG[cert.ensure.default_reason]="This domain requires a TLS certificate."
MSG[cert.ensure.found]="Found certificate for %s."
MSG[cert.ensure.missing]="No certificate found for domain %s"
MSG[cert.ensure.menu]="  1. Issue with HTTP-01  (domain DNS must point to this host; port 80 must be open)
  2. Issue with DNS-01   (supports wildcard; port 80 is not required)
  3. Import existing certificate
  0. Skip"
MSG[cert.ensure.acme_unavailable]="acme.sh is unavailable; cannot issue certificate."
MSG[cert.ensure.skipped]="Certificate skipped."

MSG[cert.deps.acme_missing]="acme.sh is not installed."
MSG[cert.deps.ask_install]="Install acme.sh now?"
MSG[cert.deps.required]="acme.sh is required for automatic certificate issuance."

MSG[cert.menu.title]="SSL Certificate Management"
MSG[cert.menu.install_acme]="Install acme.sh"
MSG[cert.menu.issue_http]="Issue certificate (HTTP-01)"
MSG[cert.menu.issue_dns]="Issue certificate (DNS-01 / wildcard)"
MSG[cert.menu.import]="Import certificate manually"
MSG[cert.menu.renew]="Renew certificates"
MSG[cert.menu.auto_renew]="Enable automatic renewal"
MSG[cert.menu.list]="List certificates"
MSG[cert.menu.delete]="Delete certificate"
