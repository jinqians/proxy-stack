# ru/cert.sh — SSL certificate module Russian messages (assign MSG[...] only; do not declare).

MSG[cert.acme.already_installed]="acme.sh уже установлен."
MSG[cert.acme.ask_email]="Email для регистрации сертификата"
MSG[cert.acme.install_failed]="Установка acme.sh не удалась; исполняемый файл не найден: %s"
MSG[cert.acme.installed]="acme.sh установлен, cron-задача автоматического продления настроена."
MSG[cert.ca.menu]="  CA:
  1. Let's Encrypt (по умолчанию)
  2. ZeroSSL
  3. Google Trust Services"
MSG[cert.ca.select]="Выбор [1]: "

MSG[cert.rate.limit_error]="%s достиг лимита Let's Encrypt (rateLimited / слишком много сертификатов)."
MSG[cert.rate.rule_same_set]="Этот лимит рассчитывается для точно такого же набора доменов: до 5 сертификатов за 7 дней,"
MSG[cert.rate.no_dns_bypass]="и не зависит от метода проверки. DNS-01 не обходит его, поэтому автоматического повторения не будет."
MSG[cert.rate.retry_time]="Время повторной попытки Let's Encrypt: %s"
MSG[cert.rate.options]="
  Два варианта:
    A. Дождаться времени повторной попытки выше и выпустить снова
    B. Переключиться на другой CA (ZeroSSL / Google Trust Services имеют независимые квоты)
"
MSG[cert.rate.ask_zerossl]="Переключиться на ZeroSSL и повторить сейчас?"
MSG[cert.rate.switch_zerossl_failed]="Не удалось переключить CA по умолчанию на ZeroSSL."
MSG[cert.rate.zerossl_failed]="Выпуск через ZeroSSL не удался."
MSG[cert.rate.zerossl_need_email]="ZeroSSL требует email зарегистрированного аккаунта. Можно выполнить:"
MSG[cert.rate.zerossl_register_cmd]="    acme.sh --register-account -m <your-email> --server zerossl"
MSG[cert.rate.zerossl_retry_after_register]="После регистрации выпустите сертификат снова."

MSG[cert.http.standalone]="Nginx не запущен; используется standalone-режим..."
MSG[cert.http.check_points]="Подтвердите следующее, иначе выпуск не удастся:"
MSG[cert.http.need_port80_cloud]="    1. Cloud security group / firewall консоли разрешает inbound TCP 80"
MSG[cert.http.need_port80_local]="    2. Другой локальный процесс не использует порт 80
"
MSG[cert.http.fw_opened]="Локальный firewall временно открыл порт 80 (%s)"
MSG[cert.http.fw_restored]="Правило firewall восстановлено (%s)"
MSG[cert.cached.installing]="Сертификат уже есть в кэше acme.sh; установка в %s."
MSG[cert.issue.failed_domain]="Выпуск сертификата для %s не удался."
MSG[cert.http.conn_refused_hint]="Если ошибка — 'Connection refused', cloud security group блокирует порт 80 на сетевом уровне,"
MSG[cert.http.iptables_cannot_fix]="и локальный iptables не может это исправить. Варианты:"
MSG[cert.http.solution_open80]="    A. Разрешить inbound TCP 80 в облачной консоли, затем закрыть после выпуска"
MSG[cert.http.solution_dns01]="    B. Использовать DNS-01 вместо этого (открытый порт не требуется)
"
MSG[cert.http.cf_token_detected]="Cloudflare API Token уже настроен; DNS-01 можно повторить напрямую."
MSG[cert.http.ask_dns_retry]="Переключиться на DNS-01 (Cloudflare) и выпустить снова сейчас?"
MSG[cert.http.dns_failed_cf]="DNS-01 тоже не удался. Проверьте права Cloudflare Token (требуется Zone:DNS:Edit)."

MSG[cert.ask_domain]="Домен"
MSG[cert.invalid_domain]="Недопустимый домен"
MSG[cert.ask_domain_wildcard]="Домен (поддерживается wildcard, например *.example.com)"
MSG[cert.dns_api.menu5]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. CloudXNS
  5. Вручную"
MSG[cert.dns_api.menu4]="
  DNS API:
  1. Cloudflare
  2. DNSPod
  3. Alibaba Cloud
  4. Вручную"
MSG[cert.dns_provider.select]="DNS-провайдер [1]: "
MSG[cert.ask_ali_key]="Alibaba Cloud Access Key ID"
MSG[cert.ask_ali_secret]="Alibaba Cloud Access Key Secret"
MSG[cert.ask_ali_key_short]="Alibaba Cloud Key ID"
MSG[cert.ask_ali_secret_short]="Alibaba Cloud Secret"
MSG[cert.invalid_option]="Недопустимый вариант"
MSG[cert.issue.failed]="Выпуск не удался"

MSG[cert.import.ask_cert_file]="Полный путь к файлу сертификата (fullchain.pem)"
MSG[cert.import.ask_key_file]="Путь к файлу приватного ключа (privkey.pem)"
MSG[cert.import.ask_ca_file]="Путь к файлу цепочки CA (необязательно, Enter = пропустить)"
MSG[cert.import.cert_not_found]="Файл сертификата не найден"
MSG[cert.import.key_not_found]="Файл приватного ключа не найден"
MSG[cert.import.cert_not_found_path]="Файл сертификата не найден: %s"
MSG[cert.import.key_not_found_path]="Файл приватного ключа не найден: %s"
MSG[cert.import.imported_to]="Сертификат импортирован в %s"
MSG[cert.install.installed]="Сертификат установлен: %s"
MSG[cert.install.installed_to]="Сертификат установлен в %s"

MSG[cert.renew.ask_domain]="Домен (пусто = продлить все)"
MSG[cert.renew.ask_force]="Принудительно продлить? (игнорирует срок действия и может попасть под лимиты Let's Encrypt)"
MSG[cert.renew.not_due]="Сертификат еще не требует продления; пропущено. При необходимости можно принудительно продлить."
MSG[cert.renew.failed]="Продление не удалось"
MSG[cert.auto_renew.installed]="Cron-задача автоматического продления установлена."

MSG[cert.delete.ask_domain]="Домен для удаления"
MSG[cert.domain_required]="Домен не может быть пустым."
MSG[cert.delete.ask_local]="Также удалить локальные файлы в %s?"
MSG[cert.delete.deleted]="Сертификат удален."
MSG[cert.cf.ask_token]="Cloudflare API Token (с правом редактирования Zone DNS)"

MSG[cert.ensure.default_reason]="Для этого домена требуется TLS-сертификат."
MSG[cert.ensure.found]="Найден сертификат для %s."
MSG[cert.ensure.missing]="Сертификат для домена %s не найден"
MSG[cert.ensure.menu]="  1. Выпустить через HTTP-01  (DNS домена должен указывать на этот хост; порт 80 должен быть открыт)
  2. Выпустить через DNS-01   (поддерживает wildcard; порт 80 не требуется)
  3. Импортировать существующий сертификат
  0. Пропустить"
MSG[cert.ensure.acme_unavailable]="acme.sh недоступен; невозможно выпустить сертификат."
MSG[cert.ensure.skipped]="Сертификат пропущен."

MSG[cert.deps.acme_missing]="acme.sh не установлен."
MSG[cert.deps.ask_install]="Установить acme.sh сейчас?"
MSG[cert.deps.required]="acme.sh требуется для автоматического выпуска сертификатов."

MSG[cert.menu.title]="Управление SSL-сертификатами"
MSG[cert.menu.install_acme]="Установить acme.sh"
MSG[cert.menu.issue_http]="Выпустить сертификат (HTTP-01)"
MSG[cert.menu.issue_dns]="Выпустить сертификат (DNS-01 / wildcard)"
MSG[cert.menu.import]="Импортировать сертификат вручную"
MSG[cert.menu.renew]="Продлить сертификаты"
MSG[cert.menu.auto_renew]="Включить автоматическое продление"
MSG[cert.menu.list]="Список сертификатов"
MSG[cert.menu.delete]="Удалить сертификат"
