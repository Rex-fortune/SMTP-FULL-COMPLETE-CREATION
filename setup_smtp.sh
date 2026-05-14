#!/usr/bin/env bash
#
# setup-smtp-corrected.sh — Postfix + OpenDKIM + SMTP AUTH + MTA-STS/TLS-RPT helper
# Targets: Ubuntu 22.04 / 24.04 LTS
# Run: sudo bash setup-smtp-corrected.sh
#
# IMPORTANT:
# 1) Edit DOMAIN and ADMIN_EMAIL first.
# 2) Create DNS A records before running certbot parts:
#      mail.DOMAIN    -> this server IP
#      mta-sts.DOMAIN -> this server IP
# 3) Set VPS rDNS/PTR to mail.DOMAIN in your provider panel.
#
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────
# CONFIGURATION — EDIT THESE BEFORE RUNNING
# ──────────────────────────────────────────────────────────────────────
DOMAIN="panwestconsultant.net"
HOSTNAME="mail.${DOMAIN}"
MTA_STS_HOST="mta-sts.${DOMAIN}"
SELECTOR="mail"
ADMIN_EMAIL="contact@${DOMAIN}"
SMTP_USER="smtpuser"
SMTP_PASSWORD="CHANGE_ME_STRONG_PASSWORD_NOW"
MTA_STS_MODE="enforce"       # use testing first if you are unsure; enforce after validation
MTA_STS_MAX_AGE="86400"      # 1 day initially; later use 31557600
ENABLE_NGINX_MTA_STS="yes"   # yes/no
ENABLE_465="yes"             # yes/no. 587 is the recommended main submission port.
# ──────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SERVER_IP="$(ip route get 1 | awk '{print $7; exit}')"

log(){ echo -e "\n${YELLOW}$*${NC}"; }
ok(){ echo -e "${GREEN}$*${NC}"; }
fail(){ echo -e "${RED}$*${NC}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"
[[ "$SMTP_PASSWORD" != "CHANGE_ME_STRONG_PASSWORD_NOW" ]] || fail "Edit SMTP_PASSWORD in the script before running. Do not use the default."

ok "========================================"
ok " SMTP Server Setup for ${DOMAIN}"
ok " IP: ${SERVER_IP}"
ok "========================================"

# ── 1. Hostname and packages ─────────────────────────────────────────
log "[1/11] Setting hostname and installing packages..."
hostnamectl set-hostname "${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
if ! grep -qE "\s${HOSTNAME}(\s|$)" /etc/hosts; then
  echo "${SERVER_IP} ${HOSTNAME} ${DOMAIN}" >> /etc/hosts
fi

export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

apt-get update -y
apt-get install -y postfix postfix-policyd-spf-python opendkim opendkim-tools \
  sasl2-bin libsasl2-modules bind9-dnsutils mailutils certbot nginx python3-certbot-nginx \
  ca-certificates openssl ufw fail2ban

# ── 2. Certificates ──────────────────────────────────────────────────
log "[2/11] Getting/validating Let's Encrypt certificates..."
# Certbot standalone needs port 80 free if nginx has no working site yet.
if [[ ! -d "/etc/letsencrypt/live/${HOSTNAME}" ]]; then
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone --non-interactive --agree-tos -m "${ADMIN_EMAIL}" -d "${HOSTNAME}" || \
    fail "Could not issue cert for ${HOSTNAME}. Make sure DNS A record points to ${SERVER_IP} and port 80 is reachable."
  systemctl start nginx 2>/dev/null || true
fi

# ── 3. Postfix main.cf ───────────────────────────────────────────────
log "[3/11] Writing Postfix main.cf..."
cp -a /etc/postfix/main.cf "/etc/postfix/main.cf.bak.$(date +%s)" 2>/dev/null || true
cat > /etc/postfix/main.cf <<EOF_MAIN
# Basic
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 3.6

# Identity
myhostname = ${HOSTNAME}
mydomain = ${DOMAIN}
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost
inet_interfaces = all
inet_protocols = ipv4
relayhost =

# TLS outbound delivery
smtp_tls_security_level = may
smtp_tls_loglevel = 1
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_ciphers = medium

# TLS inbound/submission
smtpd_tls_cert_file = /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/${HOSTNAME}/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_protocols = >=TLSv1.2
smtpd_tls_mandatory_protocols = >=TLSv1.2
smtpd_tls_loglevel = 1

# SMTP AUTH — this exact combo fixed Gammadyne auth
smtpd_sasl_type = cyrus
smtpd_sasl_path = smtpd
smtpd_sasl_auth_enable = yes
broken_sasl_auth_clients = yes
smtpd_sasl_mechanism_filter = plain, login
smtpd_sasl_security_options = noanonymous
smtpd_sasl_tls_security_options = noanonymous

# Message limits
message_size_limit = 25600000

# DKIM milter
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = inet:127.0.0.1:8891

# Recipient restrictions / anti-open-relay
policyd-spf_time_limit = 3600
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, check_policy_service unix:private/policyd-spf

# Conservative outbound rate controls for warm-up; adjust later carefully
initial_destination_concurrency = 2
default_destination_concurrency_limit = 10
default_destination_recipient_limit = 20
smtp_destination_concurrency_limit = 5
smtp_destination_rate_delay = 2s
smtp_extra_recipient_limit = 20
anvil_rate_time_unit = 60s
smtpd_client_connection_rate_limit = 30
smtpd_client_message_rate_limit = 60

# Hide local username leaks less often
local_header_rewrite_clients = static:all
EOF_MAIN

# ── 4. Postfix master.cf — clean service definitions ─────────────────
log "[4/11] Writing safe Postfix master.cf..."
cp -a /etc/postfix/master.cf "/etc/postfix/master.cf.bak.$(date +%s)" 2>/dev/null || true
cat > /etc/postfix/master.cf <<'EOF_MASTER'
# service type  private unpriv  chroot  wakeup  maxproc command + args
smtp      inet  n       -       y       -       -       smtpd
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
postlog   unix-dgram n  -       n       -       1       postlogd

# Port 587: authenticated mail submission. chroot = n so it can access /run/saslauthd/mux.
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Port 465: optional SMTPS. Some providers block this externally; 587 is the main port.
smtps     inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# SPF policy agent
policyd-spf  unix  -       n       n       -       0       spawn
    user=policyd-spf argv=/usr/bin/policyd-spf
EOF_MASTER

if [[ "${ENABLE_465}" != "yes" ]]; then
  sed -i '/^smtps /,/^$/ s/^/#/' /etc/postfix/master.cf
fi

# ── 5. Cyrus SASL / saslauthd ────────────────────────────────────────
log "[5/11] Configuring Cyrus SASL and saslauthd..."
cat > /etc/default/saslauthd <<'EOF_SASLAUTHD'
START=yes
DESC="SASL Authentication Daemon"
NAME="saslauthd"
MECHANISMS="pam"
MECH_OPTIONS=""
THREADS=5
OPTIONS="-c -m /run/saslauthd"
EOF_SASLAUTHD

# This was the final fix: Postfix/Cyrus was trying /etc/sasldb2 until this file existed here.
mkdir -p /usr/lib/sasl2 /etc/postfix/sasl
cat > /usr/lib/sasl2/smtpd.conf <<'EOF_SASL'
pwcheck_method: saslauthd
mech_list: PLAIN LOGIN
saslauthd_path: /run/saslauthd/mux
EOF_SASL
cp /usr/lib/sasl2/smtpd.conf /etc/postfix/sasl/smtpd.conf
chmod 644 /usr/lib/sasl2/smtpd.conf /etc/postfix/sasl/smtpd.conf

mkdir -p /run/saslauthd
chown root:sasl /run/saslauthd || true
chmod 710 /run/saslauthd || true

if id "${SMTP_USER}" >/dev/null 2>&1; then
  echo "${SMTP_USER}:${SMTP_PASSWORD}" | chpasswd
else
  adduser "${SMTP_USER}" --disabled-password --gecos "SMTP User"
  echo "${SMTP_USER}:${SMTP_PASSWORD}" | chpasswd
fi

systemctl enable saslauthd
systemctl restart saslauthd

testsaslauthd -u "${SMTP_USER}" -p "${SMTP_PASSWORD}" || fail "saslauthd test failed"

# ── 6. SPF policyd minimal config ────────────────────────────────────
log "[6/11] Configuring SPF policy agent..."
cat > /etc/postfix-policyd-spf-python/policyd-spf.conf <<'EOF_SPF'
HELO_reject = False
Mail_From_reject = False
SPF_Not_Pass = False
SPF_Pass_Good_Enough = True
SPF_Log_Level = 1
EOF_SPF

# ── 7. OpenDKIM ─────────────────────────────────────────────────────
log "[7/11] Configuring OpenDKIM..."
mkdir -p "/etc/opendkim/keys/${DOMAIN}"
cat > /etc/opendkim.conf <<'EOF_DKIMCONF'
Syslog                  yes
UMask                   002
LogWhy                  yes
Mode                    sv
SubDomains              no
OversignHeaders         From
AutoRestart             yes
AutoRestartRate         10/1M
Background              yes
Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
SignatureAlgorithm      rsa-sha256
Socket                  inet:8891@127.0.0.1
PidFile                 /run/opendkim/opendkim.pid
EOF_DKIMCONF

if [[ ! -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" ]]; then
  opendkim-genkey -D "/etc/opendkim/keys/${DOMAIN}/" -d "${DOMAIN}" -s "${SELECTOR}" -b 2048
fi

cat > /etc/opendkim/KeyTable <<EOF_KEYTABLE
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private
EOF_KEYTABLE

cat > /etc/opendkim/SigningTable <<EOF_SIGNING
*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}
EOF_SIGNING

cat > /etc/opendkim/TrustedHosts <<EOF_TRUSTED
127.0.0.1
::1
localhost
${DOMAIN}
${HOSTNAME}
EOF_TRUSTED

# DKIM permissions discovered during debugging:
# parent dirs root-owned; private key root-owned when opendkim runs as uid 0 on this build.
chown root:root /etc/opendkim /etc/opendkim/keys "/etc/opendkim/keys/${DOMAIN}" /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts /etc/opendkim.conf
chmod 755 /etc/opendkim /etc/opendkim/keys "/etc/opendkim/keys/${DOMAIN}"
chmod 644 /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts /etc/opendkim.conf
chown root:root "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
chmod 600 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
[[ -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" ]] && chmod 644 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"

systemctl enable opendkim
systemctl restart opendkim

# ── 8. MTA-STS policy site ──────────────────────────────────────────
if [[ "${ENABLE_NGINX_MTA_STS}" == "yes" ]]; then
  log "[8/11] Configuring MTA-STS policy website..."
  mkdir -p /var/www/mta-sts/.well-known
  cat > /var/www/mta-sts/.well-known/mta-sts.txt <<EOF_STS
version: STSv1
mode: ${MTA_STS_MODE}
mx: ${HOSTNAME}
max_age: ${MTA_STS_MAX_AGE}
EOF_STS

  cat > /etc/nginx/sites-available/mta-sts.conf <<EOF_NGINX
server {
    listen 80;
    server_name ${MTA_STS_HOST};
    root /var/www/mta-sts;
    location /.well-known/mta-sts.txt {
        default_type text/plain;
        try_files \$uri =404;
    }
}
EOF_NGINX
  ln -sfn /etc/nginx/sites-available/mta-sts.conf /etc/nginx/sites-enabled/mta-sts.conf
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  if [[ ! -d "/etc/letsencrypt/live/${MTA_STS_HOST}" ]]; then
    certbot --nginx --non-interactive --agree-tos -m "${ADMIN_EMAIL}" -d "${MTA_STS_HOST}" || \
      echo -e "${YELLOW}MTA-STS cert failed. Add DNS A record mta-sts.${DOMAIN} -> ${SERVER_IP}, then run certbot again.${NC}"
  fi
fi

# ── 9. Firewall + fail2ban ──────────────────────────────────────────
log "[9/11] Opening firewall ports and enabling fail2ban..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 25/tcp || true
  ufw allow 587/tcp || true
  [[ "${ENABLE_465}" == "yes" ]] && ufw allow 465/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi
systemctl enable fail2ban || true
systemctl restart fail2ban || true

# ── 10. Restart and verify ──────────────────────────────────────────
log "[10/11] Restarting services and verifying..."
postfix check
systemctl restart postfix
systemctl restart opendkim
systemctl restart saslauthd

opendkim-testkey -d "${DOMAIN}" -s "${SELECTOR}" -vvv || true
ss -tulpn | grep -E ':25|:587|:465' || true

# ── 11. Future feature helper files ─────────────────────────────────
log "[11/11] Creating optional future feature notes..."
cat > /root/mailserver-next-steps.txt <<EOF_NEXT
Future features to add later:

1) DKIM key rotation
   - Generate new selector, e.g. mail2026q3:
     opendkim-genkey -D /etc/opendkim/keys/${DOMAIN}/ -d ${DOMAIN} -s mail2026q3 -b 2048
   - Publish mail2026q3._domainkey TXT.
   - Update /etc/opendkim/KeyTable and SigningTable to new selector.
   - Keep old DNS selector for a few days before deleting.

2) DANE/TLSA
   - Only do this if your DNS zone uses DNSSEC.
   - Generate TLSA for _25._tcp.${HOSTNAME}, then publish it.
   - Without DNSSEC, DANE does not help.

3) Outbound rate limits
   - Already started in main.cf with conservative smtp_destination_rate_delay and concurrency limits.
   - Increase slowly only after good reputation.

4) Bounce processing
   - Use Return-Path/bounce mailbox or VERP.
   - Parse DSNs from /var/mail or a dedicated bounce@ mailbox.
   - Suppress hard bounces immediately.

5) Feedback loop handling
   - Register with supported providers where available.
   - Gmail does not offer traditional FBL for normal senders; use Postmaster Tools.

6) VERP
   - Use sender addresses like bounce+USERID@${DOMAIN} for list mail.
   - Requires app-level sender generation plus catch-all/bounce processing.

7) List-Unsubscribe headers
   - Add in your sending app:
     List-Unsubscribe: <mailto:unsubscribe@${DOMAIN}>, <https://${DOMAIN}/unsubscribe?id=USERID>
     List-Unsubscribe-Post: List-Unsubscribe=One-Click
EOF_NEXT

ok "========================================"
ok " SETUP COMPLETE"
ok "========================================"
echo "Hostname:      ${HOSTNAME}"
echo "Domain:        ${DOMAIN}"
echo "Server IP:     ${SERVER_IP}"
echo "SMTP user:     ${SMTP_USER}"
echo "SMTP host:     ${HOSTNAME}"
echo "SMTP port:     587 STARTTLS Required"
echo ""
echo -e "${YELLOW}DNS RECORDS TO ADD / VERIFY:${NC}"
echo "A      mail        ${SERVER_IP}"
echo "MX     @           10 ${HOSTNAME}"
echo "TXT    @           v=spf1 mx a ip4:${SERVER_IP} ~all"
echo "TXT    mail        v=spf1 a -all"
echo "TXT    _dmarc      v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}; ruf=mailto:${ADMIN_EMAIL}; fo=1"
echo "TXT    _mta-sts    v=STSv1; id=$(date +%Y%m%d)"
echo "TXT    _smtp._tls  v=TLSRPTv1; rua=mailto:${ADMIN_EMAIL}"
echo "A      mta-sts     ${SERVER_IP}"
echo "PTR/rDNS in VPS panel: ${HOSTNAME}"
echo ""
echo -e "${YELLOW}DKIM TXT — publish this cleanly as one TXT value, no tabs/escaped \\009:${NC}"
cat "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"
echo ""
echo -e "${YELLOW}Verify:${NC}"
echo "dig A ${HOSTNAME}"
echo "dig MX ${DOMAIN}"
echo "dig TXT ${DOMAIN}"
echo "dig TXT mail.${DOMAIN}"
echo "dig TXT ${SELECTOR}._domainkey.${DOMAIN}"
echo "dig TXT _dmarc.${DOMAIN}"
echo "dig TXT _mta-sts.${DOMAIN}"
echo "dig TXT _smtp._tls.${DOMAIN}"
echo "curl -s https://${MTA_STS_HOST}/.well-known/mta-sts.txt"
echo "openssl s_client -starttls smtp -connect ${HOSTNAME}:587 -servername ${HOSTNAME}"
echo ""
echo -e "${YELLOW}Client SMTP settings:${NC}"
echo "Host: ${HOSTNAME}"
echo "Port: 587"
echo "Encryption: Required / STARTTLS"
echo "Username: ${SMTP_USER}"
echo "Password: [the password you set in this script]"
echo ""
echo "Future notes saved to: /root/mailserver-next-steps.txt"
