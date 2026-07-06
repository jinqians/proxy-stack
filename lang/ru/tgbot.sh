# ru/tgbot.sh — Telegram Bot module Russian messages (assign MSG[...] only; do not declare).
MSG[tgbot.notify.traffic_warn]="⚠️ *Traffic Warning*

Your node (port \`%s\`) has used *%d%%* of its traffic quota.
📊 Used: %s / Limit: %s

Contact the administrator to renew before service is interrupted."
MSG[tgbot.notify.traffic_paused]="🚫 *Service Paused*

Your node (port \`%s\`) has exhausted its traffic quota.
📊 Used: %s / Limit: %s

Contact the administrator to reset the quota before service can resume."
MSG[tgbot.expiry.header_1d]="🔴 *Urgent Expiry Reminder*"
MSG[tgbot.expiry.header_3d]="🟡 *Node Expiry Reminder*"
MSG[tgbot.expiry.header_default]="🟢 *Node Expiry Reminder*"
MSG[tgbot.expiry.warn]="%s

Your node (port \`%s\`) will expire in *%d day(s)*.
🕐 Expiry time (Hong Kong): \`%s\`

Contact the administrator to renew before service is interrupted."
MSG[tgbot.expiry.expired]="🚫 *Node Expired and Paused*

Your node (port \`%s\`) expired at \`%s\` (Hong Kong Time), and service has been paused automatically.

Contact the administrator to renew before service can resume."
MSG[tgbot.expiry.renewed]="✅ *Renewal Successful*

Your node (port \`%s\`) has been renewed.
📅 New expiry time (Hong Kong): \`%s\`

Thank you for using the service."

# ── Health report ────────────────────────────────────────────────────────────
MSG[tgbot.hr.traffic_paused_line]="\n  🚫 %s (port %s) paused"
MSG[tgbot.hr.traffic_warn_line]="\n  ⚠️ %s (port %s) %s%%"
MSG[tgbot.hr.traffic_section]="*🚦 Traffic*\n%d node(s), %d at ≥90%%, %d paused%b\n"
MSG[tgbot.hr.expired_line]="\n  🔴 %s expired"
MSG[tgbot.hr.expiring_line]="\n  🟡 %s has %s day(s) left (%s)"
MSG[tgbot.hr.expiry_section]="*📅 Expiry*\n%d node(s) have expiry times, %d expired, %d expiring within 7 days%b\n"
MSG[tgbot.hr.reality_switch_line]="\n  🔁 %s switched camouflage target within 24 hours → %s"
MSG[tgbot.hr.reality_section]="*🛡 Reality Health*\n%d node(s) enabled health switching, %d switched within 24 hours%b\n"
MSG[tgbot.hr.ssh_pw_disabled]="\nSSH: password login ✅ disabled"
MSG[tgbot.hr.ssh_pw_enabled]="\nSSH: password login ⚠️ still enabled"
MSG[tgbot.hr.ssh_pending]="\n  ⏳ Unconfirmed SSH change; automatic rollback in about %s seconds"
MSG[tgbot.hr.bbr_enabled]="\nBBR: ✅ enabled"
MSG[tgbot.hr.bbr_disabled]="\nBBR: ❌ disabled"
MSG[tgbot.hr.fail2ban_banned]="\nFail2ban: SSH rule currently bans %s IP(s)"
MSG[tgbot.hr.honeypot_banned]="\nHoneypot: currently bans %s IP(s)"
MSG[tgbot.hr.honeypot_hits]="\nHoneypot: %s new hit(s) today"
MSG[tgbot.hr.security_section]="*🔒 Security*%b\n"
MSG[tgbot.hr.warp_applied]="✅ outbound active"
MSG[tgbot.hr.warp_not_applied]="⚠️ registered but outbound not applied"
MSG[tgbot.hr.warp_section]="*🌐 WARP*\n%s\n"
MSG[tgbot.hr.empty]="No monitoring data to summarize yet (modules are not enabled).\n\n"
MSG[tgbot.hr.report]="📋 *PSM Daily Health Report*\n━━━━━━━━━━━━━━━━━━━━\n🗓 %s\n\n%b━━━━━━━━━━━━━━━━━━━━\n_See each menu for more details_"
MSG[tgbot.hr.enabled]="Daily health report enabled; sends every day at %s:00"
MSG[tgbot.hr.disabled]="Daily health report disabled"
MSG[tgbot.hr.setup_title]="Daily Health Report Setup"
MSG[tgbot.hr.ask_hour]="Hour to send each day (0-23, server local time)"
MSG[tgbot.hr.invalid_hour]="Invalid hour"
MSG[tgbot.hr.status_title]="Daily Health Report Status"
MSG[tgbot.hr.status_enabled]="Status: enabled, sends every day at %s:00"
MSG[tgbot.hr.status_disabled]="Status: disabled"
MSG[tgbot.hr.menu.title]="Daily Health Report"
MSG[tgbot.hr.menu.setup]="Enable / change send time"
MSG[tgbot.hr.menu.send_now]="Send once now (test)"
MSG[tgbot.hr.menu.disable]="Disable"
MSG[tgbot.hr.sending]="Sending..."
MSG[tgbot.hr.sent]="Sent. If nothing arrives, check whether Telegram Bot admins are configured."

# ── Relay status report ──────────────────────────────────────────────────────
MSG[tgbot.rs.service_not_installed]="*🔁 realm Service*\n❌ not installed\n"
MSG[tgbot.rs.uptime]="%d day(s) %d hour(s) %d min"
MSG[tgbot.rs.service_running]="*🔁 realm Service*\n✅ running (%s)%s\n"
MSG[tgbot.rs.service_uptime_suffix]=" · up for %s"
MSG[tgbot.rs.service_stopped]="*🔁 realm Service*\n⚠️ not running (%s)\n"
MSG[tgbot.rs.proc_line]="CPU %s%% · memory %s%% (%.1f MB)"
MSG[tgbot.rs.resources_title]="*📟 Resource Usage*\n"
MSG[tgbot.rs.cpu_line]="CPU: %s%%  ·  load: %s\n"
MSG[tgbot.rs.mem_line]="Memory: %s\n"
MSG[tgbot.rs.disk_line]="Disk /: %s\n"
MSG[tgbot.rs.realm_proc_line]="realm process: %s\n"
MSG[tgbot.rs.net_title]="\n*📶 Real-time Network* (%s)\n"
MSG[tgbot.rs.net_line]="↓ inbound %s  ·  ↑ outbound %s\n"
MSG[tgbot.rs.rules_title]="*🛰 Relay Rules* (%d)\n"
MSG[tgbot.rs.no_rules]="No relay rules configured\n"
MSG[tgbot.rs.status_unreachable]="❌ target unreachable"
MSG[tgbot.rs.lat_fail]="connection failed (%s/%s timed out)"
MSG[tgbot.rs.status_loss]="⚠️ packet loss"
MSG[tgbot.rs.status_good]="✅ excellent"
MSG[tgbot.rs.status_ok]="✅ good"
MSG[tgbot.rs.status_slow]="⚠️ high latency"
MSG[tgbot.rs.lat_ok]="latency %sms · jitter %sms · success %s/%s"
MSG[tgbot.rs.rule_line]="\n\\[%s] \`:%s\` → \`%s:%s\` (%s)\n"
MSG[tgbot.rs.current_conn]="current connections: %s\n"
MSG[tgbot.rs.skipped]="\n_(%d more rule(s) were not probed to keep the report fast)_\n"
MSG[tgbot.rs.report]="🔁 *Relay Server Status*\n━━━━━━━━━━━━━━━━━━━━\n🖥 %s\n🗓 %s\n\n%b━━━━━━━━━━━━━━━━━━━━"

# ── Telegram bot main daemon / menu ─────────────────────────────────────────
MSG[tgbot.cfg.not_configured]="Telegram Bot is not configured. Run \"Configure Telegram Bot\" first."
MSG[tgbot.cfg.token_unset]="TG_BOT_TOKEN is not set"
MSG[tgbot.kb.admin.nodes]="📋 All nodes"
MSG[tgbot.kb.admin.users]="👥 Tenants"
MSG[tgbot.kb.admin.relay]="🔁 Relay status"
MSG[tgbot.kb.admin.help]="ℹ️ Help"
MSG[tgbot.kb.tenant.traffic]="📊 My traffic"
MSG[tgbot.kb.tenant.refresh]="🔄 Refresh"
MSG[tgbot.relay.module_failed]="⚠️ Relay status module failed to load"
MSG[tgbot.relay.collecting]="⏳ Collecting relay server status (resources / speed / latency). This takes a few seconds..."
MSG[tgbot.help.callback_admin]="ℹ️ *Help*  🔑 Admin
━━━━━━━━━━━━━━━━━━━━
*Traffic query*
› Send a port number directly
› \`/traffic <port>\`
› \`/list\`  all nodes

*Tenant management*
› \`/token <port>\`  generate bind token
› \`/bind <ID> <port>\`  bind manually
› \`/unbind <ID>\`  unbind
› \`/users\`  view list

*Relay (realm)*
› \`/relay\`  relay server status

*Other*
› \`/id\`  show your ID"
MSG[tgbot.next_reset.today]="%d-%02d-%02d (today)"
MSG[tgbot.query.no_data_enabled]="❌ No traffic statistics yet (traffic monitoring is not enabled)"
MSG[tgbot.query.port_not_monitored]="❌ Port *%s* is not in traffic monitoring
💡 Send /list to view monitored nodes"
MSG[tgbot.query.unknown]="unknown"
MSG[tgbot.query.status_paused]="paused"
MSG[tgbot.query.status_warn]="near limit"
MSG[tgbot.query.status_running]="running"
MSG[tgbot.query.port_line]="%s *%s*   port \`%s\`\n\n"
MSG[tgbot.query.used]="📤 Used      *%s*\n"
MSG[tgbot.query.limit]="📦 Limit     *%s*\n"
MSG[tgbot.query.remaining]="💾 Remaining *%s*\n"
MSG[tgbot.query.reset_line]="🔄 Resets on day *%s* monthly  ·  next *%s*\n"
MSG[tgbot.query.updated_at]="🕐 Updated at *%s*\n"
MSG[tgbot.list.no_data]="❌ No traffic statistics yet"
MSG[tgbot.list.empty]="📭 No nodes in traffic monitoring"
MSG[tgbot.list.title]="📊 *Traffic Overview*\n"
MSG[tgbot.list.paused_extra]="  *paused*"
MSG[tgbot.list.detail_hint]="💡 \`/traffic <port>\` for details\n"
MSG[tgbot.token.usage]="⚠️ Usage:
\`/token <port>\`  view or generate bind token
\`/token <port> reset\`  regenerate"
MSG[tgbot.token.action_reset]="regenerated"
MSG[tgbot.token.action_created]="generated"
MSG[tgbot.token.generated]="🔑 *Bind token %s*
━━━━━━━━━━━━━━━━━━━━
Port   \`%s\`
Token  \`%s\`
━━━━━━━━━━━━━━━━━━━━
Send this to the tenant, then ask them to send the Bot:
\`%s %s\`"
MSG[tgbot.token.unbound]="unbound"
MSG[tgbot.token.tenant_id_line]="
Tenant ID  \`%s\`"
MSG[tgbot.token.tenant_id_line_bound]="
Tenant ID  \`%s\`  (%s)"
MSG[tgbot.token.existing]="🔑 *Bind token*
━━━━━━━━━━━━━━━━━━━━
Port   \`%s\`
Token  \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
Send this to the tenant, then ask them to send the Bot:
\`%s %s\`

_\`/token %s reset\` to regenerate_"
MSG[tgbot.bind.usage]="⚠️ Usage: \`/bind <userID> <port>\`"
MSG[tgbot.bind.success]="✅ *Bind successful*
━━━━━━━━━━━━━━━━━━━━
User  \`%s\`
Port  \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
💡 Ask the tenant to send /start to begin querying"
MSG[tgbot.unbind.usage]="⚠️ Usage: \`/unbind <userID>\`"
MSG[tgbot.unbind.not_bound]="❌ User \`%s\` is not bound to any port"
MSG[tgbot.unbind.success]="✅ *Unbind successful*
━━━━━━━━━━━━━━━━━━━━
User \`%s\` removed"
MSG[tgbot.users.empty]="📭 *No tenants*
━━━━━━━━━━━━━━━━━━━━
\`/bind <ID> <port>\` to add a tenant"
MSG[tgbot.users.title]="👥 *Tenant List*"
MSG[tgbot.users.port_line]="   port \`%s\`"
MSG[tgbot.users.manage_hint]="\`/bind\` · \`/unbind\` manage bindings"
MSG[tgbot.expiry.module_missing]="⚠️ Expiry module is not loaded"
MSG[tgbot.expiry.status_title]="📅 *Node Expiry Status*
━━━━━━━━━━━━━━━━━━━━"
MSG[tgbot.expiry.days_left]="%s day(s) left"
MSG[tgbot.expiry.days_expired]="expired %s day(s) ago"
MSG[tgbot.expiry.status_line]="
%s *%s*  port \`%s\`
   Expiry: \`%s\` (%s)"
MSG[tgbot.expiry.none_set]="
_No node expiry time has been set_"
MSG[tgbot.renew.usage]="⚠️ Usage: \`/renew <port> <months>\`
Example: \`/renew 49123 3\`"
MSG[tgbot.renew.port_missing]="❌ Port \`%s\` has no expiry record
Set the expiry time first under Traffic Management -> Expiry Management."
MSG[tgbot.renew.success]="✅ *Renewal successful*
━━━━━━━━━━━━━━━━━━━━
Node: \`%s\`  Port: \`%s\`
Renewal: +%s month(s)
New expiry time (Hong Kong):
\`%s\`"
MSG[tgbot.help.admin_start]="*PSM Traffic Management*  🔑 Admin
━━━━━━━━━━━━━━━━━━━━
*Traffic query*
› Send a port number directly
› \`/traffic <port>\`  specific port
› \`/list\`  all nodes overview

*Tenant management*
› \`/token <port>\`  generate bind token
› \`/bind <ID> <port>\`  bind manually
› \`/unbind <ID>\`  unbind
› \`/users\`  view list

*Expiry management*
› \`/expiry\`  view all node expiry status
› \`/renew <port> <months>\`  renew a node

*Relay (realm)*
› \`/relay\`  relay server status (resources / speed / latency)

_Automatically updates every minute_"
MSG[tgbot.traffic.usage]="⚠️ Usage: \`/traffic <port>\`"
MSG[tgbot.id_card]="🪪 *Your Telegram ID*
━━━━━━━━━━━━━━━━━━━━
\`%s\`"
MSG[tgbot.help.tenant_start]="*PSM Traffic Query*
━━━━━━━━━━━━━━━━━━━━
Your port: \`%s\`

👇 Tap the button to view real-time traffic usage
_Automatically updates every minute_"
MSG[tgbot.permission_denied]="⛔ Permission denied for this operation"
MSG[tgbot.bind_token.required]="🔐 Port \`%s\` requires a bind token
━━━━━━━━━━━━━━━━━━━━
Send the Bot:
\`%s <bind-token>\`

_The bind token is provided by the administrator_"
MSG[tgbot.bind_token.wrong]="❌ Bind token is incorrect. Check it and try again"
MSG[tgbot.notify.new_tenant]="🔔 *New tenant bound*
━━━━━━━━━━━━━━━━━━━━
User ID  \`%s\`
Port     \`%s\`%s
━━━━━━━━━━━━━━━━━━━━
\`/unbind %s\`  unbind"
MSG[tgbot.tenant.bind_success]="✅ *Bind successful*  ·  port \`%s\`
━━━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━━━
_Send any message later to refresh traffic_"
MSG[tgbot.access_restricted]="⛔ *Access restricted*
━━━━━━━━━━━━━━━━━━━━
Send \`<port> <bind-token>\` to complete binding.

Your ID: \`%s\`
_The bind token is provided by the administrator_"
MSG[tgbot.service.started]="Telegram Bot service started"
MSG[tgbot.service.deleted]="Telegram Bot service deleted"
MSG[tgbot.service.stopped]="Bot stopped"
MSG[tgbot.service.restarted]="Bot restarted"
MSG[tgbot.setup.title]="══ Telegram Bot Setup Wizard ══════════════════════"
MSG[tgbot.setup.step1]="  1. Search for %s in Telegram"
MSG[tgbot.setup.step2]="  2. Send /newbot and follow the prompts to create a bot"
MSG[tgbot.setup.step3]="  3. Copy the Token from BotFather (format: 123456:ABC...)"
MSG[tgbot.setup.token_keep]="Bot Token (press Enter to keep current)"
MSG[tgbot.setup.token_empty]="Token cannot be empty"
MSG[tgbot.setup.validating]="Validating Token..."
MSG[tgbot.setup.invalid]="Token is invalid or network is unavailable. Check it and try again"
MSG[tgbot.setup.verified]="Bot verified: @%s"
MSG[tgbot.setup.admin_title]="Admin permissions (can query all nodes / manage tenant bindings):"
MSG[tgbot.setup.admin_any]="Leave empty = everyone is an admin (suitable for personal use)"
MSG[tgbot.setup.admin_only]="Set IDs = only specified users are admins (recommended for multi-tenant use)"
MSG[tgbot.setup.admin_id_hint]="Do not know your ID? Start the Bot and send /id"
MSG[tgbot.setup.ask_admin_ids]="Admin Telegram IDs (comma-separated; leave empty for unrestricted)"
MSG[tgbot.setup.saved]="Config saved: %s"
MSG[tgbot.setup.ask_restart]="Bot service is running. Restart it to apply the new config?"
MSG[tgbot.setup.ask_start]="Start the Telegram Bot service now?"
MSG[tgbot.tenant_menu.title]="══ Tenant Binding Management ═══════════════"
MSG[tgbot.tenant_menu.current]="Current bindings:"
MSG[tgbot.tenant_menu.current_line]="  🔑 User %-15s -> port %-8s %s\n"
MSG[tgbot.tenant_menu.empty]="No tenant bindings"
MSG[tgbot.tenant_menu.menu_title]="Tenant Binding Management"
MSG[tgbot.tenant_menu.bind]="Bind tenant to port"
MSG[tgbot.tenant_menu.unbind]="Unbind tenant"
MSG[tgbot.tenant_menu.list]="View all bindings"
MSG[tgbot.tenant_menu.ask_uid]="Tenant Telegram user ID"
MSG[tgbot.tenant_menu.ask_port]="Port to bind"
MSG[tgbot.tenant_menu.uid_port_required]="User ID and port cannot be empty"
MSG[tgbot.tenant_menu.bound]="Bound user %s -> port %s%s"
MSG[tgbot.tenant_menu.ask_unbind_uid]="Tenant Telegram user ID to unbind"
MSG[tgbot.tenant_menu.not_bound]="User %s is not bound to any port"
MSG[tgbot.tenant_menu.unbound]="Unbound user %s"
MSG[tgbot.tenant_menu.details]="Binding details:"
MSG[tgbot.tenant_menu.detail_line]="  %s  ->  port %s  %s\n"
MSG[tgbot.menu.running]="running"
MSG[tgbot.menu.not_running]="not running"
MSG[tgbot.menu.header]="══ Telegram Bot Management"
MSG[tgbot.menu.service_status]="service status: %s"
MSG[tgbot.menu.config]="Configure Bot Token / admin permissions"
MSG[tgbot.menu.tenants]="Manage tenant bindings (bind/unbind/view)"
MSG[tgbot.menu.start]="Start Bot service"
MSG[tgbot.menu.stop]="Stop Bot service"
MSG[tgbot.menu.restart]="Restart Bot service"
MSG[tgbot.menu.logs]="View Bot service logs"
MSG[tgbot.menu.uninstall]="Uninstall Bot service"
MSG[tgbot.menu.health_report]="Daily health report"
MSG[tgbot.menu.ask_uninstall]="Uninstall Telegram Bot service?"
