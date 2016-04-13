#!/usr/bin/bash
#
# Install juju and make it work.
# Joey <joey.mcdonald@nokia.com>

# Pull in admin credentials
source /root/keystonerc_admin || exit 255

VM='juju-master'
key='/root/.ssh/juju_id_rsa'
guest_vlan='48'
service='epdg'

function verify_creds() {

   # Test to check for admin creds.
   echo -n "Verifying admin credentials: "
   env | grep -q OS_AUTH_URL
   check_exit_code
}

function create_sec_group() {

   echo -n "Creating a security group: "
   neutron security-group-create smssh &> /dev/null

   # Wide open for now..
   nova secgroup-add-rule smssh tcp 1 65535 0.0.0.0/0 &> /dev/null

   #for port in 22 80 443; do
      #neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol \
           #tcp --port-range-min $port --port-range-max $port smssh 
   #done

   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
      --protocol icmp smssh &> /dev/null

   neutron security-group-list | grep -q smssh
   check_exit_code
}

function create_provider_network() {

   echo -n "Checking for provider network: "
   neutron net-list | grep -q floating

   if [ $? != '0' ]; then

      # This is our 'public' network used for either floating IP's and a virtual router
      # or just create VM's with a nic here for direct access (easier).
      net=$(ifconfig br1 | perl -lane 'print $1 if /inet (.*?)\s/' | cut -d'.' -f1-3);
      start="$net.100"
      end="$net.120"
      gateway=$(route -n |grep '^0.0.0.0' |awk '{print $2}')
      mask=$(ifconfig br1|perl -lane 'print $1 if /netmask (.*?)\s/')
      prefix=$(/bin/ipcalc -p $start $mask | awk -F\= '{print $2}')

      echo "Installing ($net.0/$prefix)"

      neutron net-create floating --provider:network_type flat \
          --provider:physical_network RegionOne --router:external=True  &> /dev/null

      neutron subnet-create --name floating-subnet --allocation-pool \
          start=$start,end=$end --gateway $gateway floating $net.0/24 \
          --dns_nameservers list=true 8.8.8.8  &> /dev/null

   else
      echo "Ok"
   fi
}

function create_virtual_router() {

   echo -n "Checking for a virtual router: "

   neutron router-list | grep -q router1
   if [ $? != '0' ]; then
      echo "Installing"

      neutron router-create router1  &> /dev/null
      neutron router-gateway-set router1 floating  &> /dev/null
      neutron router-interface-add router1 subnet1  &> /dev/null
   else
      echo "Ok"
   fi
}

function create_tenant_networks() {

   echo -n "Checking for guest networks: "
   neutron net-list | grep -q smnet1

   if [ $? != '0' ]; then

      echo "Installing"
      neutron net-create --provider:physical_network RegionOne \
         --provider:network_type vlan --provider:segmentation_id $guest_vlan smnet1  &> /dev/null
      neutron subnet-create smnet1 10.10.10.0/24 --name subnet1  &> /dev/null

   else
      echo "Ok"
   fi
}

function boot_vm() {

   echo -n "Checking for management VM: "

   nova list --all-tenants | grep -q juju-management

   if [ $? != '0' ]; then
      echo "Booting Up"
      # Management VM
      nova boot --image $(nova image-list | grep ubuntu1404 | awk '{print $2}') --flavor m1.large \
          --nic net-id=$(neutron net-list | grep floating | awk '{print $2}')  \
          --key_name juju-key --security_groups smssh $VM &> /dev/null

   else
      echo "Ok" 
   fi
}

function create_flavors() {

   echo -n "Checking for m1.medium flavor: "
   nova flavor-list|grep -q m1.medium
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.medium auto 4096 40 2 &> /dev/null
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.large flavor: "
   nova flavor-list|grep -q m1.large
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.large auto 8192 80 4 &> /dev/null
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.xlarge flavor: "
   nova flavor-list|grep -q m1.xlarge
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.xlarge auto 16384 160 8 &> /dev/null
   else
      echo "Ok"
   fi
}

function create_ssh_key() {

   echo -n "Checking for crypto keys: "
   if [ ! -f $key ]; then
      echo "Installing"
      nova keypair-add juju-key > $key
      chmod 400 $key
      nova keypair-show juju-key|grep ^Public|awk -F': ' '{print $2}' > ${key}.pub
   else
      echo "Ok"
   fi
}


function wait_for_running() {

   echo -n "Waiting for (${num_of_vms}) VM 'Running' status: "
   sleep 5

   # If we don't get this far, boot failure occured.
   nova list | grep -q juju
   if [ $? -ne 0 ]; then
      echo "Failed to boot VM."
      clean_up
      exit 255
   fi
}

function clean_up() {

   ip=$(get_vm_ip)
   cat ~/.ssh/known_hosts | grep -v $ip > /tmp/known_hosts &> /dev/null
   mv /tmp/known_hosts /root/.ssh/

   for uuid in `nova list |egrep "$VM|juju-juju-os-machine" |awk '{print $2}'`
   do
      nova delete $uuid
   done

   sleep 5

   for router in `neutron router-list|grep router1|awk '{print $2}'`
      do
         for subnet in `neutron router-port-list ${router} -c fixed_ips -f csv | egrep -o '[0-9a-z\-]{36}'`
            do
               neutron router-interface-delete ${router} ${subnet}
            done
         neutron router-gateway-clear ${router}
         neutron router-delete ${router}
      done


   for net in `neutron net-list|egrep 'smnet|floating'|awk '{print $2}'`
   do
      neutron net-delete $net
   done

   for uuid in `nova secgroup-list | grep smssh|awk '{print $2}'`
   do
      nova secgroup-delete $uuid &> /dev/null
   done

   for uuid in `nova flavor-list | egrep 'm1.small|m1.medium|m1.large|m1.xlarge' |awk '{print $2}'`
   do 
      nova flavor-delete $uuid &> /dev/null
   done

   rm -rf $key ${key}.pub

   nova keypair-delete juju-key &> /dev/null
}

function check_exit_code() {

   if [ $? -ne 0 ]; then
      $SMOKE_RES = false
      echo "Failed"
      echo "Running clean up"
      clean_up
      exit 255
   fi
   echo "Success"
}

function get_vm_ip() {

   ip=$(nova list|grep $VM|perl -lane 'print $1 if (/floating=(.*?)[;|\s]/)')
   echo $ip
}

function install_juju() {


   echo -n "Installing juju software and OS updates: "
   ip=$(get_vm_ip)

   run_cmd_jr="ssh -q -l ubuntu $ip -i $key"
   run_cmd_rt="ssh -q -l root $ip -i $key"

   $run_cmd_jr "sudo sed -n 's/^.*ssh-rsa/ssh-rsa/p' /root/.ssh/authorized_keys > /tmp/authorized_keys" &> /dev/null
   $run_cmd_jr "sudo mv /tmp/authorized_keys /root/.ssh/" &> /dev/null
   $run_cmd_jr "sudo chmod 600 /root/.ssh/authorized_keys" &> /dev/null
   $run_cmd_jr "sudo chown root:root /root/.ssh/authorized_keys" &> /dev/null

   # sudo isn't happy with out this, amateurs.
   $run_cmd_rt "echo '127.0.0.1 $VM' >> /etc/hosts"

   # Ubuntu LTS 14.04 doesn't automatically start a second interface. 
   # Not using this right now but might need it later.

   # echo -n "Starting second network interface on ($ip):"
   # $run_cmd_rt "echo -e 'auto eth1\niface eth1 inet dhcp' > /etc/network/interfaces.d/eth1.cfg"
   # $run_cmd_rt 'ifup eth1' 
   # echo "Ok"

   $run_cmd_rt 'add-apt-repository ppa:juju/stable' &> /dev/null
   $run_cmd_rt 'apt-get update && apt-get -y dist-upgrade' &> /dev/null
   $run_cmd_rt 'apt-get -y install apache2 git juju-core python-novaclient python-glanceclient python-neutronclient' &> /dev/null

   echo "Ok"
}

function create_env_yaml() {

   echo -n "Generating juju environment yaml: "

   ip=$(get_vm_ip)
   run_cmd_rt="ssh -q -l root $ip -i $key"

   admin_endpoint=$(openstack endpoint show keystone|grep adminurl|awk '{print $4}')
   admin_password=$(grep OS_P /root/keystonerc_admin|awk -F= '{print $2}')
   admin_token=$(grep TOKEN /root/keystonerc_admin|awk -F= '{print $2}')
   region=$(openstack endpoint list|grep neutron |awk '{print $4}')

   cat << EOF > ./environments.yaml
default: juju-os
environments:
  juju-os:
    auth-mode: userpass
    auth-url: $admin_endpoint
    default-series: trusty
    password: $admin_password
    region: $region
    tenant-name: admin
    type: openstack
    username: admin
    admin-secret: $admin_token
    agent-metadata-url: https://streams.canonical.com/juju/tools/
    network: floating
    image-metadata-url: http://$ip/metadata/images/
EOF

   $run_cmd_rt "mkdir -p /root/.juju/environments/" &> /dev/null
   $run_cmd_rt "mkdir -p /root/.juju/ssh/" &> /dev/null

   scp -q -i $key environments.yaml $ip:/root/.juju/
   scp -q -i $key $key $ip:/root/.juju/ssh/
   scp -q -i $key $key.pub $ip:/root/.juju/ssh/
   echo "Ok"
}

function create_service_yaml() {

   echo -n "Creating service YAML for $service deployment: "

   ip=$(get_vm_ip)
   run_cmd_rt="ssh -q -l root $ip -i $key"

   admin_endpoint=$(openstack endpoint show keystone|grep adminurl|awk '{print $4}')
   admin_password=$(grep OS_P /root/keystonerc_admin|awk -F= '{print $2}')
   admin_token=$(grep TOKEN /root/keystonerc_admin|awk -F= '{print $2}')
   floating=$(neutron net-list|grep floating|awk '{print $2}')

   cat << EOF > ./${service}.yaml
---
$service:
  keystone_admin_token: $admin_token
  os_auth_url: $admin_endpoint
  os_password: $admin_password
  os_tenant_name: admin
  os_username: admin
  public_network: $floating
EOF

   scp -q -i $key ${service}.yaml $ip: 
   echo "Ok"

}

function bootstrap_juju() {

   # This was nearly impossible to get right.
   # https://jujucharms.com/docs/stable/howto-privatecloud#deploying-private-clouds

   echo -n "Bootstraping juju: "
   ip=$(get_vm_ip)
   run_cmd_rt="ssh -q -l root $ip -i $key"

   $run_cmd_rt 'service apache2 start' &> /dev/null
   scp -q -i $key /root/keystonerc_admin $ip:/root/
   $run_cmd_rt 'mkdir -p /var/www/html/metadata/'

   image_uuid=$(glance image-list|grep ubuntu1404 |awk '{print $2}')
   meta_cmd="juju metadata generate-image -d /var/www/html/metadata -s trusty -i $image_uuid -a amd64"
   $run_cmd_rt "$meta_cmd" &> /dev/null
   $run_cmd_rt "chown -R www-data:www-data /var/www/html/metadata/"
   $run_cmd_rt 'juju bootstrap --constraints instance-type=m1.medium --debug' &> /dev/null
   echo "Ok"
}

function deploy_juju_gui() {

   echo -n "Deploying juju-gui: "

   ip=$(get_vm_ip)
   run_cmd_rt="ssh -q -l root $ip -i $key"

   $run_cmd_rt 'juju deploy juju-gui' &> /dev/null

   #$run_cmd_rt 'juju deploy mysql' &> /dev/null
   #$run_cmd_rt 'juju deploy wordpress' &> /dev/null
   #$run_cmd_rt 'juju add-relation wordpress mysql' &> /dev/null
   #$run_cmd_rt 'juju expose wordpress' &> /dev/null
   #wp_ip=$($run_cmd_rt 'juju status wordpress|grep public'|  awk '{print $2}')
   #sleep 120; echo "http://$wp_ip/"
   echo "Ok"

}


function deploy_service() {

   echo -n "Deploying $service: "

   ip=$(get_vm_ip)
   run_cmd_rt="ssh -q -l root $ip -i $key"

   $run_cmd_rt 'echo "export JUJU_CLI_VERSION=2" >> /root/.bashrc' # makes juju status a lot nicer
   $run_cmd_rt 'git clone https://github.com/jmcdice/juju-bootstrap.git' &> /dev/null
   $run_cmd_rt "juju deploy --config=/root/${service}.yaml --repository=/root/juju-bootstrap/charms/ local:trusty/$service" &> /dev/null

   echo "Ok"
   #$run_cmd_rt 'juju deploy mysql' &> /dev/null
   #$run_cmd_rt 'juju deploy wordpress' &> /dev/null
   #$run_cmd_rt 'juju add-relation wordpress mysql' &> /dev/null
   #$run_cmd_rt 'juju expose wordpress' &> /dev/null
   #wp_ip=$($run_cmd_rt 'juju status wordpress|grep public'|  awk '{print $2}')
   #sleep 120; echo "http://$wp_ip/"
}

function wait_for_running() {

   sleep 15
   ip=$(get_vm_ip)
   echo -n "Waiting for $VM ($ip): "

   ssh -q -l ubuntu -i $key $ip 'date &> /dev/null'
   while test $? -gt 0; do
      sleep 5
      ssh -q -l ubuntu -i $key $ip 'date &> /dev/null'
   done
   echo "Ok"
}


# clean_up

function start_up() {

   verify_creds
   create_sec_group
   create_ssh_key
   create_provider_network
   create_tenant_networks
   create_flavors
   create_virtual_router
   boot_vm
   wait_for_running
   install_juju
   create_env_yaml
   bootstrap_juju
   create_service_yaml
   deploy_juju_gui
   deploy_service
   echo "Deployment Complete"
}

function shutdown() {

   clean_up
}

clean_up
start_up

