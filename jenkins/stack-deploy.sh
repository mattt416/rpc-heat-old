#!/bin/bash

set -e

source ~/.openrc

ip=$(heat output-show rpc-${CLUSTER_PREFIX} controller1_ip | sed -e 's/"//g')
checkout="/root/os-ansible-deployment/"
ssh_key=~/.ssh/jenkins
ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Here we set pipefail so that we get the exit code of run_anasible.sh and not the successful exit code of tee itself
ssh -l root -i $ssh_key $ssh_options $ip "set -o pipefail; cd ${checkout} && bash run_ansible.sh 2>&1 | tee -a run_ansible.log"

ssh -l root -i $ssh_key $ssh_options $ip "ifconfig br-vlan 10.1.13.1 netmask 255.255.255.0"

if [ $DEPLOY_TEMPEST = "true" ]; then
  ssh -l root -i $ssh_key $ssh_options $ip "lxc-attach -n \$(lxc-ls | grep utility) -- sh -c 'cd /opt/tempest_*/ && ./run_tempest.sh --smoke -N || true'"
fi

if [ $DEPLOY_MONITORING = "true" ]; then
  echo "Testing MaaS checks ..."
  ssh -l root -i $ssh_key $ssh_options $ip "cd ${checkout}/scripts && python rpc_maas_tool.py check --prefix ${CLUSTER_PREFIX}"
  echo "Done."
fi
