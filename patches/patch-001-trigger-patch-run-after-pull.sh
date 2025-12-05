#!/bin/bash
#
# Patch 001 — Ensure patch runner always triggers after networkr-companion is updated
#
# This patch adjusts the cron job so that:
# 1. networkr-companion pulls the latest code daily
# 2. IMMEDIATELY AFTER the pull, run-patches.sh executes
#
# This guarantees that any new patches committed to Git run on the next cron cycle
# without waiting for anything else.

CRON_FILE="/etc/cron.daily/networkr-companion-update"
PATCH_RUNNER="/home/pressilion/networkr-companion/scripts/run-patches.sh"

echo "Applying Patch 001: Ensuring patch runner triggers after git pull …"

# Rebuild the cron script completely to guarantee correct behaviour
cat <<EOF | sudo tee $CRON_FILE >/dev/null
#!/bin/bash

# Update networkr-companion
cd /home/pressilion/networkr-companion
sudo -u pressilion git pull --rebase >/dev/null 2>&1

# Run patches immediately after pull
sudo $PATCH_RUNNER >/dev/null 2>&1

exit 0
EOF

# Set correct permissions just in case
sudo chmod 755 $CRON_FILE

echo "Patch 001 applied successfully."
exit 0