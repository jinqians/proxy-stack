# ko/cert.sh — SSL certificate module Korean messages (assign MSG[...] only; do not declare).

MSG[cert.acme.already_installed]="acme.sh가 이미 설치되어 있습니다."
MSG[cert.acme.ask_email]="인증서 등록 이메일"
MSG[cert.acme.install_failed]="acme.sh 설치 실패. 실행 파일을 찾을 수 없습니다: %s"
MSG[cert.acme.installed]="acme.sh 설치 완료, 자동 갱신 cron 작업이 설정되었습니다."
MSG[cert.ca.menu]="  CA:
  1. Let's Encrypt (기본값)
  2. ZeroSSL
  3. Google Trust Services"
MSG[cert.ca.select]="선택 [1]: "

MSG[cert.rate.limit_error]="%s가 Let's Encrypt rate limit에 도달했습니다(rateLimited / 인증서 과다)."
MSG[cert.rate.rule_same_set]="이 제한은 정확히 같은 도메인 집합 기준으로 계산됩니다: 7일에 최대 5개 인증서,"
MSG[cert.rate.no_dns_bypass]="검증 방식과 무관합니다. DNS-01로도 우회할 수 없으므로 자동 재시도하지 않습니다."
MSG[cert.rate.retry_time]="Let's Encrypt 재시도 가능 시각: %s"
MSG[cert.rate.options]="
  두 가지 선택:
    A. 위 재시도 시각까지 기다린 뒤 다시 발급
    B. 다른 CA로 전환(ZeroSSL / Google Trust Services는 별도 할당량)
"
MSG[cert.rate.ask_zerossl]="ZeroSSL로 전환하고 지금 다시 시도할까요?"
MSG[cert.rate.switch_zerossl_failed]="기본 CA를 ZeroSSL로 전환하지 못했습니다."
MSG[cert.rate.zerossl_failed]="ZeroSSL 발급 실패."
MSG[cert.rate.zerossl_need_email]="ZeroSSL은 등록된 계정 이메일이 필요합니다. 다음을 실행할 수 있습니다:"
MSG[cert.rate.zerossl_register_cmd]="    acme.sh --register-account -m <your-email> --server zerossl"
MSG[cert.rate.zerossl_retry_after_register]="등록 후 인증서를 다시 발급하세요."

MSG[cert.http.standalone]="Nginx가 실행 중이 아닙니다. standalone 모드를 사용합니다..."
MSG[cert.http.check_points]="다음을 확인하세요. 그렇지 않으면 발급이 실패합니다:"
MSG[cert.http.need_port80_cloud]="    1. 클라우드 보안 그룹 / 콘솔 방화벽이 인바운드 TCP 80을 허용"
MSG[cert.http.need_port80_local]="    2. 다른 로컬 프로세스가 포트 80을 사용하지 않음
"
MSG[cert.http.fw_opened]="로컬 방화벽 포트 80을 임시로 열었습니다(%s)"
MSG[cert.http.fw_restored]="방화벽 규칙을 복원했습니다(%s)"
MSG[cert.cached.installing]="인증서가 이미 acme.sh 캐시에 있습니다. %s에 설치합니다."
MSG[cert.issue.failed_domain]="%s 인증서 발급 실패."
MSG[cert.http.conn_refused_hint]="오류가 'Connection refused'라면 클라우드 보안 그룹이 네트워크 계층에서 포트 80을 차단 중입니다,"
MSG[cert.http.iptables_cannot_fix]="로컬 iptables로는 해결할 수 없습니다. 선택지:"
MSG[cert.http.solution_open80]="    A. 클라우드 콘솔에서 인바운드 TCP 80을 허용하고 발급 후 닫기"
MSG[cert.http.solution_dns01]="    B. 대신 DNS-01 사용(포트 개방 불필요)
"
MSG[cert.http.cf_token_detected]="Cloudflare API Token이 이미 설정되어 있습니다. DNS-01을 바로 재시도할 수 있습니다."
MSG[cert.http.ask_dns_retry]="DNS-01(Cloudflare)로 전환해 지금 다시 발급할까요?"
MSG[cert.http.dns_failed_cf]="DNS-01도 실패했습니다. Cloudflare Token 권한을 확인하세요(Zone:DNS:Edit 필요)."

MSG[cert.ask_domain]="도메인"
MSG[cert.invalid_domain]="잘못된 도메인"
MSG[cert.ask_domain_wildcard]="도메인(와일드카드 지원, 예: *.example.com)"
MSG[cert.dns_api.menu5]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. CloudXNS
  5. 수동"
MSG[cert.dns_api.menu4]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. 수동"
MSG[cert.dns_provider.select]="DNS 공급자 [1]: "
MSG[cert.ask_ali_key]="Alibaba Cloud Access Key ID"
MSG[cert.ask_ali_secret]="Alibaba Cloud Access Key Secret"
MSG[cert.ask_ali_key_short]="Alibaba Cloud Key ID"
MSG[cert.ask_ali_secret_short]="Alibaba Cloud Secret"
MSG[cert.invalid_option]="잘못된 옵션"
MSG[cert.issue.failed]="발급 실패"

MSG[cert.import.ask_cert_file]="전체 인증서 파일 경로(fullchain.pem)"
MSG[cert.import.ask_key_file]="개인 키 파일 경로(privkey.pem)"
MSG[cert.import.ask_ca_file]="CA 체인 파일 경로(선택 사항, 건너뛰려면 Enter)"
MSG[cert.import.cert_not_found]="인증서 파일을 찾을 수 없습니다"
MSG[cert.import.key_not_found]="개인 키 파일을 찾을 수 없습니다"
MSG[cert.import.cert_not_found_path]="인증서 파일을 찾을 수 없습니다: %s"
MSG[cert.import.key_not_found_path]="개인 키 파일을 찾을 수 없습니다: %s"
MSG[cert.import.imported_to]="인증서를 %s로 가져왔습니다"
MSG[cert.install.installed]="인증서 설치됨: %s"
MSG[cert.install.installed_to]="인증서가 %s에 설치되었습니다"

MSG[cert.renew.ask_domain]="도메인(비워두면 전체 갱신)"
MSG[cert.renew.ask_force]="강제 갱신할까요? (유효 기간을 무시하며 Let's Encrypt rate limit에 걸릴 수 있음)"
MSG[cert.renew.not_due]="인증서 갱신 시점이 아니므로 건너뜁니다. 필요하면 강제 갱신할 수 있습니다."
MSG[cert.renew.failed]="갱신 실패"
MSG[cert.auto_renew.installed]="자동 갱신 cron 작업이 설치되었습니다."

MSG[cert.delete.ask_domain]="삭제할 도메인"
MSG[cert.domain_required]="도메인은 비워둘 수 없습니다."
MSG[cert.delete.ask_local]="%s 아래 로컬 파일도 삭제할까요?"
MSG[cert.delete.deleted]="인증서가 삭제되었습니다."
MSG[cert.cf.ask_token]="Cloudflare API Token(Zone DNS 편집 권한 포함)"

MSG[cert.ensure.default_reason]="이 도메인에는 TLS 인증서가 필요합니다."
MSG[cert.ensure.found]="%s 인증서를 찾았습니다."
MSG[cert.ensure.missing]="도메인 %s의 인증서를 찾을 수 없습니다"
MSG[cert.ensure.menu]="  1. HTTP-01로 발급  (도메인 DNS가 이 호스트를 가리켜야 하며 포트 80이 열려 있어야 함)
  2. DNS-01로 발급   (와일드카드 지원, 포트 80 불필요)
  3. 기존 인증서 가져오기
  0. 건너뛰기"
MSG[cert.ensure.acme_unavailable]="acme.sh를 사용할 수 없어 인증서를 발급할 수 없습니다."
MSG[cert.ensure.skipped]="인증서를 건너뛰었습니다."

MSG[cert.deps.acme_missing]="acme.sh가 설치되어 있지 않습니다."
MSG[cert.deps.ask_install]="지금 acme.sh를 설치할까요?"
MSG[cert.deps.required]="자동 인증서 발급에는 acme.sh가 필요합니다."

MSG[cert.menu.title]="SSL 인증서 관리"
MSG[cert.menu.install_acme]="acme.sh 설치"
MSG[cert.menu.issue_http]="인증서 발급(HTTP-01)"
MSG[cert.menu.issue_dns]="인증서 발급(DNS-01 / 와일드카드)"
MSG[cert.menu.import]="인증서 수동 가져오기"
MSG[cert.menu.renew]="인증서 갱신"
MSG[cert.menu.auto_renew]="자동 갱신 활성화"
MSG[cert.menu.list]="인증서 목록"
MSG[cert.menu.delete]="인증서 삭제"
