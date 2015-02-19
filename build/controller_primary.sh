echo -n "%%PRIVATE_KEY%%" > .ssh/id_rsa
chmod 600 .ssh/*

if [ ! -e /root/os-ansible-deployment ]; then
  git clone -b %%RPC_GIT_VERSION%% %%RPC_GIT_REPO%% os-ansible-deployment
fi

cd os-ansible-deployment

if [ -d etc/openstack_deploy ]; then
  etc_dir="openstack_deploy"
  rpc_user_config="/etc/${etc_dir}/openstack_user_config.yml"
  rpc_environment="/etc/${etc_dir}/openstack_environment.yml"
else
  etc_dir="rpc_deploy"
  rpc_user_config="/etc/${etc_dir}/rpc_user_config.yml"
  rpc_environment="/etc/${etc_dir}/rpc_environment.yml"
fi

swift_config="/etc/${etc_dir}/conf.d/swift.yml"
user_variables="/etc/${etc_dir}/user_variables.yml"

pip install -r requirements.txt
cp -a etc/${etc_dir}/ /etc/

scripts/pw-token-gen.py --file $user_variables
echo "nova_virt_type: qemu" >> $user_variables
echo "lb_name: %%CLUSTER_PREFIX%%-node3" >> $user_variables

sed -i "s#\(rackspace_cloud_auth_url\): .*#\1: %%RACKSPACE_CLOUD_AUTH_URL%%#g" $user_variables
sed -i "s/\(rackspace_cloud_tenant_id\): .*/\1: %%RACKSPACE_CLOUD_TENANT_ID%%/g" $user_variables
sed -i "s/\(rackspace_cloud_username\): .*/\1: %%RACKSPACE_CLOUD_USERNAME%%/g" $user_variables
sed -i "s/\(rackspace_cloud_password\): .*/\1: %%RACKSPACE_CLOUD_PASSWORD%%/g" $user_variables
sed -i "s/\(rackspace_cloud_api_key\): .*/\1: %%RACKSPACE_CLOUD_API_KEY%%/g" $user_variables
sed -i "s/\(glance_default_store\): .*/\1: %%GLANCE_DEFAULT_STORE%%/g" $user_variables
sed -i "s/\(maas_notification_plan\): .*/\1: npTechnicalContactsEmail/g" $user_variables

if [ $SWIFT_ENABLED -eq 1 ]; then
  sed -i "s/\(glance_swift_store_auth_address\): .*/\1: '{{ auth_identity_uri }}'/" $user_variables
  sed -i "s/\(glance_swift_store_key\): .*/\1: '{{ glance_service_password }}'/" $user_variables
  sed -i "s/\(glance_swift_store_region\): .*/\1: RegionOne/" $user_variables
  sed -i "s/\(glance_swift_store_user\): .*/\1: 'service:glance'/" $user_variables
else
  sed -i "s/\(glance_swift_store_region\): .*/\1: %%GLANCE_SWIFT_STORE_REGION%%/g" $user_variables
fi

environment_version=$(md5sum $rpc_environment | awk '{print $1}')

# if %%HEAT_GIT_REPO%% has .git at end (https://github.com/mattt416/rpc_heat.git),
# strip it off otherwise curl will 404
raw_url=$(echo %%HEAT_GIT_REPO%% | sed -e 's/\.git$//g' -e 's/github.com/raw.githubusercontent.com/g')

curl -o $rpc_user_config "${raw_url}/%%HEAT_GIT_VERSION%%/rpc_user_config.yml"
sed -i "s/__ENVIRONMENT_VERSION__/$environment_version/g" $rpc_user_config
sed -i "s/__EXTERNAL_VIP_IP__/%%EXTERNAL_VIP_IP%%/g" $rpc_user_config
sed -i "s/__CLUSTER_PREFIX__/%%CLUSTER_PREFIX%%/g" $rpc_user_config

if [ $SWIFT_ENABLED -eq 1 ]; then
  curl -o $swift_config "${raw_url}/%%HEAT_GIT_VERSION%%/swift.yml"
  sed -i "s/__CLUSTER_PREFIX__/%%CLUSTER_PREFIX%%/g" $swift_config
fi

# here we create a separate script incase run_ansible paramater is false and
# you want to re-run the correct set of playbooks at a later time
cat >> run_ansible.sh << "EOF"
#!/bin/bash

set -e

function retry()
{
  local n=1
  local try=$1
  local cmd="${@: 2}"

  until [[ $n -gt $try ]]
  do
    echo "attempt number $n:"
    $cmd && break || {
      echo "Command Failed..."
      ((n++))
      sleep 1;
    }
  done
}

user_variables=${user_variables:-"/etc/${etc_dir}/user_variables.yml"}

timeout=$(($(date +%s) + 300))

until ansible hosts -m ping > /dev/null 2>&1; do
  if [ $(date +%s) -gt $timeout ]; then
    echo "Timed out waiting for nodes to become accessible ..."
    exit 1
  fi
done

if [ -d rpc_deployment ]; then
  cd rpc_deployment
  prefix="playbooks"
else
  cd playbooks
  prefix="."
fi

retry 3 ansible-playbook -e @${user_variables} ${prefix}/setup/host-setup.yml
retry 3 ansible-playbook -e @${user_variables} ${prefix}/infrastructure/haproxy-install.yml
EOF

if [ $LOGGING_ENABLED -eq 1 ]; then
  cat >> run_ansible.sh << "EOF"
retry 3 ansible-playbook -e @${user_variables} ${prefix}/infrastructure/infrastructure-setup.yml \
                                               ${prefix}/openstack/openstack-setup.yml
EOF
else
  cat >> run_ansible.sh << "EOF"
egrep -v 'rpc-support-all.yml|rsyslog-config.yml' ${prefix}/openstack/openstack-setup.yml > \
                                                  ${prefix}/openstack/openstack-setup-no-logging.yml
retry 3 ansible-playbook -e @${user_variables} ${prefix}/infrastructure/memcached-install.yml \
                                               ${prefix}/infrastructure/galera-install.yml \
                                               ${prefix}/infrastructure/rabbit-install.yml
retry 3 ansible-playbook -e @${user_variables} ${prefix}/openstack/openstack-setup-no-logging.yml
EOF
fi

if [ $SWIFT_ENABLED -eq 1 ]; then
  cat >> run_ansible.sh << "EOF"
retry 3 ansible-playbook -e @${user_variables} ${prefix}/openstack/swift-all.yml
EOF
fi

if [ $TEMPEST_ENABLED -eq 1 ]; then
  cat >> run_ansible.sh << "EOF"
retry 3 ansible-playbook -e @${user_variables} ${prefix}/openstack/tempest.yml
EOF
fi

if [ $MONITORING_ENABLED -eq 1 ]; then
  cat >> run_ansible.sh << "EOF"
retry 3 ansible-playbook -e @${user_variables} ${prefix}/monitoring/raxmon-all.yml
retry 3 ansible-playbook -e @${user_variables} ${prefix}/monitoring/maas_local.yml
# We do not run these as remote checks fail due to self-signed SSL certificate
#retry 3 ansible-playbook -e @${user_variables} ${prefix}/monitoring/maas_remote.yml
EOF
fi

if [ $RUN_ANSIBLE -eq 1 ]; then
  bash run_ansible.sh
fi
