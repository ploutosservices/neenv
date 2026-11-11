# The drill's throwaway host: Debian with step-ca from Smallstep's repository, sshd with a user whose login shell is
# /bin/sh (dash) and passwordless sudo (the ssh transport is drilled through it), and two stand-ins: systemctl.sh for
# the one unit, cp.sh to fail a database copy on demand. Nothing here holds a real key.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl python3 procps \
      openssh-server sudo \
 && curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o /etc/apt/keyrings/smallstep.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/smallstep.asc] https://packages.smallstep.com/stable/debian debs main" > /etc/apt/sources.list.d/smallstep.list \
 && apt-get update && apt-get install -y --no-install-recommends step-cli step-ca && rm -rf /var/lib/apt/lists/* \
 && useradd --system --shell /usr/sbin/nologin --home-dir /etc/step-ca --no-create-home step \
 && useradd --create-home --shell /bin/sh ca && echo 'ca ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ca \
 && mkdir -p /run/sshd /home/ca/.ssh && chown ca:ca /home/ca/.ssh && chmod 700 /home/ca/.ssh
COPY systemctl.sh /usr/local/bin/systemctl
COPY cp.sh /usr/local/bin/cp
CMD ["/usr/sbin/sshd", "-D", "-e"]
