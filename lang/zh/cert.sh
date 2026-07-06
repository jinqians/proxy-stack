# zh/cert.sh — SSL 证书模块中文文案（仅赋值 MSG[...]，勿 declare）。

MSG[cert.acme.already_installed]="acme.sh 已安装。"
MSG[cert.acme.ask_email]="证书注册邮箱"
MSG[cert.acme.install_failed]="acme.sh 安装失败——未找到可执行文件：%s"
MSG[cert.acme.installed]="acme.sh 已安装，自动续期定时任务已设置。"
MSG[cert.ca.menu]="  CA:
  1. Let's Encrypt（默认）
  2. ZeroSSL
  3. Google Trust Services"
MSG[cert.ca.select]="请选择 [1]: "

MSG[cert.rate.limit_error]="%s 触发 Let's Encrypt 限流（rateLimited / too many certificates）。"
MSG[cert.rate.rule_same_set]="这是按「完全相同域名集合」计算的签发限制：同一组域名 7 天内最多 5 张，"
MSG[cert.rate.no_dns_bypass]="与验证方式无关——改用 DNS-01 也无法绕过，因此不再自动切换验证方式重试。"
MSG[cert.rate.retry_time]="Let's Encrypt 解封时间：%s"
MSG[cert.rate.options]="
  两条出路：
    A. 等待上述解封时间后再签发
    B. 换一家 CA（ZeroSSL / Google Trust Services 配额独立）
"
MSG[cert.rate.ask_zerossl]="是否立即切换到 ZeroSSL 重试？"
MSG[cert.rate.switch_zerossl_failed]="切换默认 CA 到 ZeroSSL 失败。"
MSG[cert.rate.zerossl_failed]="ZeroSSL 签发失败。"
MSG[cert.rate.zerossl_need_email]="ZeroSSL 需要已注册的账户邮箱，可先运行："
MSG[cert.rate.zerossl_register_cmd]="    acme.sh --register-account -m <你的邮箱> --server zerossl"
MSG[cert.rate.zerossl_retry_after_register]="注册后重新签发即可。"

MSG[cert.http.standalone]="Nginx 未运行，使用独立模式..."
MSG[cert.http.check_points]="请确认以下两点，否则签发会失败："
MSG[cert.http.need_port80_cloud]="    1. 云服务商安全组 / 控制台防火墙 已放行 TCP 80"
MSG[cert.http.need_port80_local]="    2. 本机没有其他程序占用端口 80
"
MSG[cert.http.fw_opened]="已临时开放本机防火墙端口 80（%s）"
MSG[cert.http.fw_restored]="已还原防火墙规则（%s）"
MSG[cert.cached.installing]="证书已在 acme.sh 缓存中——正在安装到 %s。"
MSG[cert.issue.failed_domain]="%s 的证书签发失败。"
MSG[cert.http.conn_refused_hint]="如果错误是 'Connection refused'，说明云安全组在网络层封锁了端口 80，"
MSG[cert.http.iptables_cannot_fix]="本机 iptables 无法解决此问题。解决方法："
MSG[cert.http.solution_open80]="    A. 登录云控制台将 TCP 80 入方向放行，申请完再关闭"
MSG[cert.http.solution_dns01]="    B. 改用 DNS-01 方式（无需开放任何端口）
"
MSG[cert.http.cf_token_detected]="检测到已配置 Cloudflare API Token，可直接用 DNS-01 方式重试。"
MSG[cert.http.ask_dns_retry]="是否立即切换 DNS-01（Cloudflare）重新签发？"
MSG[cert.http.dns_failed_cf]="DNS-01 签发同样失败，请检查 Cloudflare Token 权限（需 Zone:DNS:Edit）。"

MSG[cert.ask_domain]="域名"
MSG[cert.invalid_domain]="无效的域名"
MSG[cert.ask_domain_wildcard]="域名（支持通配符 *.example.com）"
MSG[cert.dns_api.menu5]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. 阿里云
  4. CloudXNS
  5. 手动"
MSG[cert.dns_api.menu4]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. 阿里云
  4. 手动"
MSG[cert.dns_provider.select]="DNS 提供商 [1]: "
MSG[cert.ask_ali_key]="阿里云 Access Key ID"
MSG[cert.ask_ali_secret]="阿里云 Access Key Secret"
MSG[cert.ask_ali_key_short]="阿里云 Key ID"
MSG[cert.ask_ali_secret_short]="阿里云 Secret"
MSG[cert.invalid_option]="无效选项"
MSG[cert.issue.failed]="签发失败"

MSG[cert.import.ask_cert_file]="证书文件完整路径（fullchain.pem）"
MSG[cert.import.ask_key_file]="私钥文件完整路径（privkey.pem）"
MSG[cert.import.ask_ca_file]="CA 链文件完整路径（可选，直接回车跳过）"
MSG[cert.import.cert_not_found]="证书文件未找到"
MSG[cert.import.key_not_found]="私钥文件未找到"
MSG[cert.import.cert_not_found_path]="证书文件未找到：%s"
MSG[cert.import.key_not_found_path]="私钥文件未找到：%s"
MSG[cert.import.imported_to]="证书已导入到 %s"
MSG[cert.install.installed]="证书已安装：%s"
MSG[cert.install.installed_to]="证书已安装到 %s"

MSG[cert.renew.ask_domain]="域名（留空则续期全部）"
MSG[cert.renew.ask_force]="是否强制续期（忽略有效期，注意 Let's Encrypt 限流）？"
MSG[cert.renew.not_due]="证书未到续期时间，已跳过（需要可选强制续期）。"
MSG[cert.renew.failed]="续期失败"
MSG[cert.auto_renew.installed]="自动续期定时任务已安装。"

MSG[cert.delete.ask_domain]="要删除的域名"
MSG[cert.domain_required]="域名不能为空。"
MSG[cert.delete.ask_local]="同时删除本地文件 %s？"
MSG[cert.delete.deleted]="证书已删除。"
MSG[cert.cf.ask_token]="Cloudflare API Token（含 Zone DNS 编辑权限）"

MSG[cert.ensure.default_reason]="此域名需要 TLS 证书。"
MSG[cert.ensure.found]="已找到 %s 的证书。"
MSG[cert.ensure.missing]="未找到域名 %s 的证书"
MSG[cert.ensure.menu]="  1. HTTP-01 签发  （域名 DNS 需指向本机，端口 80 必须开放）
  2. DNS-01 签发   （支持通配符，无需开放端口 80）
  3. 导入已有证书
  0. 跳过"
MSG[cert.ensure.acme_unavailable]="acme.sh 不可用，无法签发证书。"
MSG[cert.ensure.skipped]="已跳过证书。"

MSG[cert.deps.acme_missing]="acme.sh 未安装。"
MSG[cert.deps.ask_install]="是否现在安装 acme.sh？"
MSG[cert.deps.required]="acme.sh 是自动签发证书的必要工具。"

MSG[cert.menu.title]="SSL 证书管理"
MSG[cert.menu.install_acme]="安装 acme.sh"
MSG[cert.menu.issue_http]="签发证书（HTTP-01）"
MSG[cert.menu.issue_dns]="签发证书（DNS-01 / 通配符）"
MSG[cert.menu.import]="手动导入证书"
MSG[cert.menu.renew]="续期证书"
MSG[cert.menu.auto_renew]="启用自动续期"
MSG[cert.menu.list]="列出证书"
MSG[cert.menu.delete]="删除证书"
