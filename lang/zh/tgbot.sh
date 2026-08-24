# zh/tgbot.sh — Telegram Bot 模块中文文案（仅赋值 MSG[...]，勿 declare）。
MSG[tgbot.notify.traffic_warn]="⚠️ *流量预警*

您的节点（端口 \`%s\`）流量已用 *%d%%*
📊 已用：%s　／　上限：%s

请及时联系管理员续费，避免服务中断。"
MSG[tgbot.notify.traffic_paused]="🚫 *服务已暂停*

您的节点（端口 \`%s\`）流量已耗尽
📊 已用：%s　／　上限：%s

请联系管理员重置配额后方可恢复使用。"
MSG[tgbot.expiry.header_1d]="🔴 *紧急到期提醒*"
MSG[tgbot.expiry.header_3d]="🟡 *节点临期提醒*"
MSG[tgbot.expiry.header_default]="🟢 *节点到期提醒*"
MSG[tgbot.expiry.warn]="%s

您的节点（端口 \`%s\`）将在 *%d 天后* 到期
🕐 到期时间（香港）：\`%s\`

请及时联系管理员续费，避免服务中断。"
MSG[tgbot.expiry.expired]="🚫 *节点已到期暂停*

您的节点（端口 \`%s\`）已于 \`%s\`（香港时间）到期，服务已自动暂停。

请联系管理员续费后方可恢复使用。"
MSG[tgbot.expiry.renewed]="✅ *续期成功*

您的节点（端口 \`%s\`）已成功续期。
📅 新到期时间（香港）：\`%s\`

感谢您的使用！"

# ── Health report ────────────────────────────────────────────────────────────
MSG[tgbot.hr.services_section]="*🧩 核心服务*\n已安装 %d 个，运行中 %d 个，异常 %d 个%b\n"
MSG[tgbot.hr.svc_down_line]="\n  ❌ %s（%s）未运行"
MSG[tgbot.hr.traffic_paused_line]="\n  🚫 %s（端口 %s）已暂停"
MSG[tgbot.hr.traffic_warn_line]="\n  ⚠️ %s（端口 %s）%s%%"
MSG[tgbot.hr.traffic_section]="*🚦 流量*\n共 %d 个节点，%d 个 ≥90%%，%d 个已暂停%b\n"
MSG[tgbot.hr.expired_line]="\n  🔴 %s 已过期"
MSG[tgbot.hr.expiring_line]="\n  🟡 %s 剩 %s 天（%s）"
MSG[tgbot.hr.expiry_section]="*📅 到期*\n共 %d 个节点设置了到期时间，%d 个已过期，%d 个 7 天内到期%b\n"
MSG[tgbot.hr.reality_switch_line]="\n  🔁 %s 24 小时内切换过伪装目标 → %s"
MSG[tgbot.hr.reality_section]="*🛡 Reality 测活*\n共 %d 个节点启用测活，%d 个 24 小时内发生过切换%b\n"
MSG[tgbot.hr.ssh_pw_disabled]="\nSSH：密码登录 ✅ 已禁用"
MSG[tgbot.hr.ssh_pw_enabled]="\nSSH：密码登录 ⚠️ 仍启用"
MSG[tgbot.hr.ssh_pending]="\n  ⏳ 有未确认的 SSH 变更，约 %s 秒后自动回滚"
MSG[tgbot.hr.bbr_enabled]="\nBBR：✅ 已启用"
MSG[tgbot.hr.bbr_disabled]="\nBBR：❌ 未启用"
MSG[tgbot.hr.fail2ban_banned]="\nFail2ban：SSH 规则当前封禁 %s 个 IP"
MSG[tgbot.hr.honeypot_banned]="\n蜜罐：当前封禁 %s 个 IP"
MSG[tgbot.hr.honeypot_hits]="\n蜜罐：今日新增 %s 次命中"
MSG[tgbot.hr.security_section]="*🔒 安全*%b\n"
MSG[tgbot.hr.warp_applied]="✅ 出站已生效"
MSG[tgbot.hr.warp_not_applied]="⚠️ 已注册但出站未应用"
MSG[tgbot.hr.warp_section]="*🌐 WARP*\n%s\n"
MSG[tgbot.hr.empty]="暂无可汇总的监控数据（各功能模块尚未启用）。\n\n"
MSG[tgbot.hr.report]="📋 *PSM 每日体检报告*\n━━━━━━━━━━━━━━━━━━━━\n🗓 %s\n\n%b━━━━━━━━━━━━━━━━━━━━\n_更多详情请到各自菜单查看_"
MSG[tgbot.hr.enabled]="每日体检报告已启用，每天 %s:00 推送"
MSG[tgbot.hr.disabled]="每日体检报告已停用"
MSG[tgbot.hr.setup_title]="每日体检报告配置"
MSG[tgbot.hr.ask_hour]="每天几点推送（0-23，服务器本地时间）"
MSG[tgbot.hr.invalid_hour]="小时无效"
MSG[tgbot.hr.status_title]="每日体检报告状态"
MSG[tgbot.hr.status_enabled]="状态：已启用，每天 %s:00 推送"
MSG[tgbot.hr.status_disabled]="状态：未启用"
MSG[tgbot.hr.menu.title]="每日体检报告"
MSG[tgbot.hr.menu.setup]="启用 / 修改推送时间"
MSG[tgbot.hr.menu.send_now]="立即发送一次（测试）"
MSG[tgbot.hr.menu.disable]="停用"
MSG[tgbot.hr.sending]="正在发送..."
MSG[tgbot.hr.sent]="已发送（若未收到，请检查 Telegram Bot 是否已配置管理员）"

# ── Relay status report ──────────────────────────────────────────────────────
MSG[tgbot.rs.service_not_installed]="*🔁 realm 服务*\n❌ 未安装\n"
MSG[tgbot.rs.uptime]="%d 天 %d 小时 %d 分"
MSG[tgbot.rs.service_running]="*🔁 realm 服务*\n✅ 运行中（%s）%s\n"
MSG[tgbot.rs.service_uptime_suffix]=" · 已运行 %s"
MSG[tgbot.rs.service_stopped]="*🔁 realm 服务*\n⚠️ 未运行（%s）\n"
MSG[tgbot.rs.proc_line]="CPU %s%% · 内存 %s%% (%.1f MB)"
MSG[tgbot.rs.resources_title]="*📟 资源消耗*\n"
MSG[tgbot.rs.cpu_line]="CPU：%s%%  ·  负载：%s\n"
MSG[tgbot.rs.mem_line]="内存：%s\n"
MSG[tgbot.rs.disk_line]="磁盘 /：%s\n"
MSG[tgbot.rs.realm_proc_line]="realm 进程：%s\n"
MSG[tgbot.rs.net_title]="\n*📶 实时网速*（%s）\n"
MSG[tgbot.rs.net_line]="↓ 入站 %s  ·  ↑ 出站 %s\n"
MSG[tgbot.rs.rules_title]="*🛰 中转规则*（%d 条）\n"
MSG[tgbot.rs.no_rules]="未配置中转规则\n"
MSG[tgbot.rs.status_unreachable]="❌ 落地不可达"
MSG[tgbot.rs.lat_fail]="连接失败（%s/%s 超时）"
MSG[tgbot.rs.status_loss]="⚠️ 有丢包"
MSG[tgbot.rs.status_good]="✅ 优"
MSG[tgbot.rs.status_ok]="✅ 良"
MSG[tgbot.rs.status_slow]="⚠️ 延迟偏高"
MSG[tgbot.rs.lat_ok]="延迟 %sms · 抖动 %sms · 成功 %s/%s"
MSG[tgbot.rs.rule_line]="\n\\[%s] \`:%s\` → \`%s:%s\`（%s）\n"
MSG[tgbot.rs.current_conn]="当前连接：%s\n"
MSG[tgbot.rs.skipped]="\n_（其余 %d 条规则未探测，避免报告耗时过长）_\n"
MSG[tgbot.rs.report]="🔁 *中转服务器状态*\n━━━━━━━━━━━━━━━━━━━━\n🖥 %s\n🗓 %s\n\n%b━━━━━━━━━━━━━━━━━━━━"

# ── Telegram bot main daemon / menu ─────────────────────────────────────────
MSG[tgbot.cfg.not_configured]="Telegram Bot 未配置，请先运行「配置 Telegram Bot」"
MSG[tgbot.cfg.token_unset]="TG_BOT_TOKEN 未设置"
MSG[tgbot.kb.admin.nodes]="📋 所有节点"
MSG[tgbot.kb.admin.users]="👥 租客列表"
MSG[tgbot.kb.admin.relay]="🔁 中转状态"
MSG[tgbot.kb.admin.help]="ℹ️ 使用说明"
MSG[tgbot.kb.tenant.traffic]="📊 查看我的流量"
MSG[tgbot.kb.tenant.refresh]="🔄 刷新"
MSG[tgbot.relay.module_failed]="⚠️ 中转状态模块加载失败"
MSG[tgbot.relay.collecting]="⏳ 正在采集中转服务器状态（资源 / 网速 / 延迟），约需几秒..."
MSG[tgbot.help.callback_admin]="ℹ️ *使用说明*  🔑 管理员
━━━━━━━━━━━━━━━━━━━━
*流量查询*
› 直接发送端口号
› \`/traffic <端口>\`
› \`/list\`  所有节点

*租客管理*
› \`/token <端口>\`  生成绑定码
› \`/bind <ID> <端口>\`  手动绑定
› \`/unbind <ID>\`  解绑
› \`/users\`  查看列表

*中转（realm）*
› \`/relay\`  中转服务器状态

*其他*
› \`/id\`  查看自己的 ID"
MSG[tgbot.next_reset.today]="%d-%02d-%02d（今日）"
MSG[tgbot.query.no_data_enabled]="❌ 暂无流量统计数据（流量监控未启用）"
MSG[tgbot.query.port_not_monitored]="❌ 端口 *%s* 未在流量监控中
💡 发送 /list 查看已监控节点"
MSG[tgbot.query.unknown]="未知"
MSG[tgbot.query.status_paused]="已暂停"
MSG[tgbot.query.status_warn]="即将达限"
MSG[tgbot.query.status_running]="运行中"
MSG[tgbot.query.port_line]="%s *%s*   端口 \`%s\`\n\n"
MSG[tgbot.query.used]="📤 已用   *%s*\n"
MSG[tgbot.query.limit]="📦 限额   *%s*\n"
MSG[tgbot.query.remaining]="💾 剩余   *%s*\n"
MSG[tgbot.query.reset_line]="🔄 每月 *%s* 日重置  ·  下次 *%s*\n"
MSG[tgbot.query.updated_at]="🕐 更新于 *%s*\n"
MSG[tgbot.list.no_data]="❌ 暂无流量统计数据"
MSG[tgbot.list.empty]="📭 尚无节点在流量监控中"
MSG[tgbot.list.title]="📊 *流量总览*\n"
MSG[tgbot.list.paused_extra]="  *已暂停*"
MSG[tgbot.list.detail_hint]="💡 \`/traffic <端口>\` 查看详情\n"
MSG[tgbot.token.usage]="⚠️ 用法：
\`/token <端口>\`  查看或生成绑定码
\`/token <端口> reset\`  重新生成"
MSG[tgbot.token.action_reset]="已重新生成"
MSG[tgbot.token.action_created]="已生成"
MSG[tgbot.token.generated]="🔑 *绑定码 %s*
━━━━━━━━━━━━━━━━━━━━
端口    \`%s\`
绑定码  \`%s\`
━━━━━━━━━━━━━━━━━━━━
发给租客，让他向 Bot 发送：
\`%s %s\`"
MSG[tgbot.token.unbound]="未绑定"
MSG[tgbot.token.tenant_id_line]="
租客 ID  \`%s\`"
MSG[tgbot.token.tenant_id_line_bound]="
租客 ID  \`%s\`  (%s)"
MSG[tgbot.token.existing]="🔑 *绑定码*
━━━━━━━━━━━━━━━━━━━━
端口    \`%s\`
绑定码  \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
发给租客，让他向 Bot 发送：
\`%s %s\`

_\`/token %s reset\` 重新生成_"
MSG[tgbot.bind.usage]="⚠️ 用法：\`/bind <用户ID> <端口>\`"
MSG[tgbot.bind.success]="✅ *绑定成功*
━━━━━━━━━━━━━━━━━━━━
用户  \`%s\`
端口  \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
💡 让租客发送 /start 开始查询"
MSG[tgbot.unbind.usage]="⚠️ 用法：\`/unbind <用户ID>\`"
MSG[tgbot.unbind.not_bound]="❌ 用户 \`%s\` 未绑定任何端口"
MSG[tgbot.unbind.success]="✅ *解绑成功*
━━━━━━━━━━━━━━━━━━━━
用户 \`%s\` 已移除"
MSG[tgbot.users.empty]="📭 *暂无租客*
━━━━━━━━━━━━━━━━━━━━
\`/bind <ID> <端口>\` 添加租客"
MSG[tgbot.users.title]="👥 *租客列表*"
MSG[tgbot.users.port_line]="   端口 \`%s\`"
MSG[tgbot.users.manage_hint]="\`/bind\` · \`/unbind\` 管理绑定"
MSG[tgbot.expiry.module_missing]="⚠️ 到期模块未加载"
MSG[tgbot.expiry.status_title]="📅 *节点到期状态*
━━━━━━━━━━━━━━━━━━━━"
MSG[tgbot.expiry.days_left]="剩 %s 天"
MSG[tgbot.expiry.days_expired]="已过期 %s 天"
MSG[tgbot.expiry.status_line]="
%s *%s*  端口 \`%s\`
   到期：\`%s\`（%s）"
MSG[tgbot.expiry.none_set]="
_尚未设置任何节点到期时间_"
MSG[tgbot.renew.usage]="⚠️ 用法：\`/renew <端口> <月数>\`
例如：\`/renew 49123 3\`"
MSG[tgbot.renew.port_missing]="❌ 端口 \`%s\` 未配置到期记录
请先在「流量管理 → 到期管理」中设置到期时间。"
MSG[tgbot.renew.success]="✅ *续期成功*
━━━━━━━━━━━━━━━━━━━━
节点：\`%s\`　端口：\`%s\`
续期：+%s 个月
新到期时间（香港）：
\`%s\`"
MSG[tgbot.help.admin_start]="*PSM 流量管理*  🔑 管理员
━━━━━━━━━━━━━━━━━━━━
*流量查询*
› 直接发送端口号查询
› \`/traffic <端口>\`  指定端口
› \`/list\`  所有节点概览

*租客管理*
› \`/token <端口>\`  生成绑定码
› \`/bind <ID> <端口>\`  手动绑定
› \`/unbind <ID>\`  解绑
› \`/users\`  查看列表

*到期管理*
› \`/expiry\`  查看所有节点到期状态
› \`/renew <端口> <月数>\`  为节点续期

*中转（realm）*
› \`/relay\`  中转服务器状态（资源 / 网速 / 延迟）

_每分钟自动更新_"
MSG[tgbot.traffic.usage]="⚠️ 用法：\`/traffic <端口号>\`"
MSG[tgbot.id_card]="🪪 *您的 Telegram ID*
━━━━━━━━━━━━━━━━━━━━
\`%s\`"
MSG[tgbot.help.tenant_start]="*PSM 流量查询*
━━━━━━━━━━━━━━━━━━━━
您的端口：\`%s\`

👇 点击按钮查看实时流量用量
_每分钟自动更新_"
MSG[tgbot.permission_denied]="⛔ 权限不足，无法执行此操作"
MSG[tgbot.bind_token.required]="🔐 端口 \`%s\` 需要绑定码
━━━━━━━━━━━━━━━━━━━━
请向 Bot 发送：
\`%s <绑定码>\`

_绑定码由管理员提供_"
MSG[tgbot.bind_token.wrong]="❌ 绑定码错误，请检查后重试"
MSG[tgbot.notify.new_tenant]="🔔 *新租客绑定*
━━━━━━━━━━━━━━━━━━━━
用户 ID  \`%s\`
端口      \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
\`/unbind %s\`  解除绑定"
MSG[tgbot.tenant.bind_success]="✅ *绑定成功*  ·  端口 \`%s\`
━━━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━━━
_后续直接发消息可刷新流量_"
MSG[tgbot.access_restricted]="⛔ *访问受限*
━━━━━━━━━━━━━━━━━━━━
发送 \`<端口> <绑定码>\` 完成绑定。

您的 ID：\`%s\`
_绑定码由管理员提供_"
MSG[tgbot.service.started]="Telegram Bot 服务已启动"
MSG[tgbot.service.deleted]="Telegram Bot 服务已删除"
MSG[tgbot.service.stopped]="Bot 已停止"
MSG[tgbot.service.restarted]="Bot 已重启"
MSG[tgbot.setup.title]="══ Telegram Bot 配置向导 ═══════════════════════════"
MSG[tgbot.setup.step1]="  1. 在 Telegram 中搜索 %s"
MSG[tgbot.setup.step2]="  2. 发送 /newbot，按提示创建机器人"
MSG[tgbot.setup.step3]="  3. 复制 BotFather 给出的 Token（格式：123456:ABC...）"
MSG[tgbot.setup.token_keep]="Bot Token（回车保留现有）"
MSG[tgbot.setup.token_empty]="Token 不能为空"
MSG[tgbot.setup.validating]="正在验证 Token..."
MSG[tgbot.setup.invalid]="Token 无效或网络不通，请检查后重试"
MSG[tgbot.setup.verified]="Bot 验证成功：@%s"
MSG[tgbot.setup.admin_title]="管理员权限（可查所有节点 / 管理租客绑定）："
MSG[tgbot.setup.admin_any]="留空 = 任何人均为管理员（适合个人独用）"
MSG[tgbot.setup.admin_only]="填写 ID = 仅指定用户为管理员（多租户推荐）"
MSG[tgbot.setup.admin_id_hint]="不知道自己的 ID？启动 Bot 后发送 /id 查看"
MSG[tgbot.setup.ask_admin_ids]="管理员 Telegram ID（多个用逗号分隔，留空不限制）"
MSG[tgbot.setup.saved]="配置已保存：%s"
MSG[tgbot.setup.ask_restart]="Bot 服务正在运行，是否重启以应用新配置？"
MSG[tgbot.setup.ask_start]="是否现在启动 Telegram Bot 服务？"
MSG[tgbot.tenant_menu.title]="══ 租客绑定管理 ══════════════════════════"
MSG[tgbot.tenant_menu.current]="当前绑定："
MSG[tgbot.tenant_menu.current_line]="  🔑 用户 %-15s → 端口 %-8s %s\n"
MSG[tgbot.tenant_menu.empty]="暂无租客绑定"
MSG[tgbot.tenant_menu.menu_title]="租客绑定管理"
MSG[tgbot.tenant_menu.bind]="绑定租客到端口"
MSG[tgbot.tenant_menu.unbind]="解除租客绑定"
MSG[tgbot.tenant_menu.list]="查看所有绑定"
MSG[tgbot.tenant_menu.ask_uid]="租客的 Telegram 用户 ID"
MSG[tgbot.tenant_menu.ask_port]="绑定的端口号"
MSG[tgbot.tenant_menu.uid_port_required]="用户 ID 和端口不能为空"
MSG[tgbot.tenant_menu.bound]="已绑定用户 %s → 端口 %s%s"
MSG[tgbot.tenant_menu.ask_unbind_uid]="要解绑的租客 Telegram 用户 ID"
MSG[tgbot.tenant_menu.not_bound]="用户 %s 未绑定任何端口"
MSG[tgbot.tenant_menu.unbound]="已解绑用户 %s"
MSG[tgbot.tenant_menu.details]="绑定详情："
MSG[tgbot.tenant_menu.detail_line]="  %s  →  端口 %s  %s\n"
MSG[tgbot.menu.running]="运行中"
MSG[tgbot.menu.not_running]="未运行"
MSG[tgbot.menu.header]="══ Telegram Bot 管理"
MSG[tgbot.menu.service_status]="服务状态: %s"
MSG[tgbot.menu.config]="配置 Bot Token / 管理员权限"
MSG[tgbot.menu.tenants]="管理租客绑定（绑定/解绑/查看）"
MSG[tgbot.menu.start]="启动 Bot 服务"
MSG[tgbot.menu.stop]="停止 Bot 服务"
MSG[tgbot.menu.restart]="重启 Bot 服务"
MSG[tgbot.menu.logs]="查看 Bot 服务日志"
MSG[tgbot.menu.uninstall]="卸载 Bot 服务"
MSG[tgbot.menu.health_report]="每日体检报告"
MSG[tgbot.menu.ask_uninstall]="确认卸载 Telegram Bot 服务？"
MSG[tgbot.token.gen_failed]="绑定 token 生成失败，未写入。空 token 会让该端口的绑定校验被跳过，因此宁可失败也不写。"
