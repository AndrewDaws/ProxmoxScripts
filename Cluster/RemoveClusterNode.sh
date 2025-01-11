#!/bin/bash
#
# RemoveClusterNode.sh
#
# Safely remove a node from a Proxmox cluster by:
#   - Checking if the node has VMs/containers, and refusing removal unless --force is given.
#   - Calling 'pvecm delnode' to remove the node from the cluster membership.
#   - Removing SSH references and /etc/pve/nodes/<NODE_NAME> directories from all remaining nodes.
#   - Allowing a future re-add of a node with the same name without leftover SSH conflicts.
#
# Usage:
#   ./RemoveClusterNode.sh [--force] <node_name>
#
# Examples:
#   # Normal removal, will refuse if the node has VMs/LXCs:
#   ./RemoveClusterNode.sh node3
#
#   # Force removal, ignoring the presence of VMs/LXCs:
#   ./RemoveClusterNode.sh --force node3
#

source "$UTILITIES"

###############################################################################
# Preliminary Checks
###############################################################################
check_root
check_proxmox

# 'jq' is not installed by default on Proxmox 8; prompt user to install if missing.
install_or_prompt "jq"

# Verify this node is part of a cluster.
check_cluster_membership

###############################################################################
# Usage Function
###############################################################################
usage() {
  echo "Usage: $0 [--force] <node_name>"
  echo "  --force   Allow removal even if the node has VMs/containers."
  exit 1
}

###############################################################################
# Argument Parsing
###############################################################################
FORCE=0
if [[ "$1" == "--force" ]]; then
  FORCE=1
  shift
fi

NODE_NAME="$1"
if [[ -z "${NODE_NAME}" ]]; then
  usage
fi

###############################################################################
# Check for VMs or containers on this node (unless --force)
###############################################################################
if [[ "${FORCE}" -ne 1 ]]; then
  echo "Checking for VMs/containers on node \"${NODE_NAME}\"..."

  # Query cluster resources for type=vm (includes QEMU + LXC) and filter by node name
  VMS_ON_NODE=$(
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | jq -r --arg N "${NODE_NAME}" '.[] | select(.node == $N) | "\(.type) \(.vmid)"'
  )

  if [[ -n "${VMS_ON_NODE}" ]]; then
    echo "Error: The following VMs/containers still reside on node \"${NODE_NAME}\":"
    echo "${VMS_ON_NODE}"
    echo
    echo "Please migrate or remove them first, or re-run with --force to override."
    exit 3
  fi
fi

###############################################################################
# Main Script Logic
###############################################################################
echo "=== Removing node \"${NODE_NAME}\" from the cluster ==="

HOST=$(get_ip_from_name ${NODE_NAME}) || true

(ssh -t -o StrictHostKeyChecking=no root@${HOST} \
"systemctl stop pve-cluster corosync \
  && pmxcfs -l \
  && rm -r /etc/corosync/* \
  && rm -r /etc/pve/corosync.conf \
  && killall pmxcfs \
  && systemctl start pve-cluster") || true

# 1) Remove node from the Corosync membership
echo "Running: pvecm delnode ${NODE_NAME}"
if ! pvecm delnode "${NODE_NAME}"; then
  echo "Warning: 'pvecm delnode' may fail if the node isn't recognized or is already removed."
  echo "Continuing with SSH cleanup..."
fi

node_count="$(get_number_of_cluster_nodes)"
if  [ "$node_count" -le 2 ]; then
  wait_spin 15

  echo "Restarting Corosync to ensure updated config is reloaded..."
  systemctl restart corosync
  sleep 2
  echo "Setting expected nodes to 1..."
  pvecm expected 1
  sleep 2
  echo "Attempting delete on ${NODE_NAME}, will run until completed, use CTRL+C to cancel..."
  while ! pvecm delnode "${NODE_NAME}"; do
    echo "pvecm delnode failed. Retrying in 5 seconds..."
    sleep 5
  done
fi

# 2) Clean SSH references on remaining cluster nodes
ONLINE_NODES=$(pvecm nodes | awk '!/Name/ {print $3}')
echo "Cleaning SSH references on other cluster nodes..."
for host in ${ONLINE_NODES}; do
  # Skip if it's the removed node or blank
  [[ "${host}" == "${NODE_NAME}" ]] && continue
  [[ -z "${host}" ]] && continue

  echo ">>> On node \"${host}\"..."
  ssh "root@${host}" "ssh-keygen -R '${NODE_NAME}' >/dev/null 2>&1 || true"
  ssh "root@${host}" "ssh-keygen -R '${NODE_NAME}.local' >/dev/null 2>&1 || true"
  ssh "root@${host}" "sed -i '/${NODE_NAME}/d' /etc/ssh/ssh_known_hosts 2>/dev/null || true"
  ssh "root@${host}" "rm -rf /etc/pve/nodes/${NODE_NAME} 2>/dev/null || true"
done

echo
echo "=== Done ==="
echo "Node \"${NODE_NAME}\" has been removed from the cluster."
echo "All known SSH references on remaining cluster nodes have been cleaned."
echo
echo "You may now safely re-add a new server with the same name (\"${NODE_NAME}\") in the future."


# At script exit, optionally remove newly installed packages.
prompt_keep_installed_packages

###############################################################################
# Testing status
###############################################################################
# Tested single-node
# Tested multi-node