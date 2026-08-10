# shellcheck shell=sh
# PINS first-run wizard hook.  POSIX sh: /etc/profile.d is sourced by dash too.
# No shebang on purpose - this file is sourced, never executed.
#
# Only for interactive shells of the appliance user, and only while the flag
# exists. scp/sftp and non-interactive ssh commands never source profile.d, and
# the -t 0 test keeps the wizard out of anything that slips through.
#
# Deliberately NOT `exec sudo ...`: with exec, a broken sudoers snippet or a
# wizard crash would end the session immediately and the operator would sit in a
# login loop with no shell. The password change is enforced by PAM (chage -d 0)
# before the shell even starts; the wizard is the guided path, not the security
# barrier. The hook runs again on every login for as long as the flag is there.
if [ -f /var/lib/pins/firstrun ] && [ -t 0 ] && [ "$(id -un)" = "pins" ] \
   && [ -x /usr/lib/pins/firstrun-wizard ]; then
    sudo -n /usr/lib/pins/firstrun-wizard || \
        echo "PINS setup could not start. Run 'sudo /usr/lib/pins/firstrun-wizard' manually."
fi
