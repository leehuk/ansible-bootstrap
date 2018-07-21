#!/bin/bash

# devenv.sh
# Bootstraps an ansible setup for the windows-devenv provisioned environment.
# Uses a private gitlab repo which contain various ansible configuration files,
# which are combined with a public github repo of tasks and helpers.
# 
# This script runs an initial set of ansible recipes:
# - apply network configuration
# - manage user accounts and sudo
# - apply any disk/lvm/mounting
# 
# For the devenv, there should always be a second storage disk attached which is
# persistent.  We bootstrap ansible to a point where it can run all the roles
# and playbooks, which can then bind mount from persistent storage into the proper
# location we want ansible in.

server=$1
apikey=$2
user=$3

ansible_dir="/store/ansible"
ansible_scripts='/.ansible/ansible-scripts'
ansible_private='/.ansible/ansible-private'
ssh_dir="/store/ssh/$user"

fail() {
    echo "Error: $*"
    exit 1
}

dosym() {
    src="$1"
    dst="$2"

    if [[ ! -L "$dst" ]]; then
        ln -s "$src" "$dst"
    fi
}

if [ -z "$server" ] || [ -z "$apikey" ] || [ -z "$user" ]; then
    fail "Usage: $0 <servername> <apikey> <user>"
fi

# Bootstrap ansible repos
if [[ ! -d "$ansible_private" ]]; then
    git clone -q https://leehuk:${apikey}@gitlab.com/leehuk/ansible-private.git "$ansible_private" || fail
fi

if [[ ! -f "$ansible_private/hosts/$server" ]]; then
    fail "Unable to find ansible hosts file for $server"
fi

if [[ ! -d "$ansible_private/host_vars/$server" ]]; then
    fail "Unable to find ansible host_vars directory for $server"
fi

if [[ ! -d "$ansible_scripts" ]]; then
    git clone -q https://github.com/leehuk/ansible-scripts.git "$ansible_scripts" || fail
fi

# Setup our ansible bootstrapping directory
mkdir -p /.ansible/bootstrap/
dosym "$ansible_private/hosts/$server" /.ansible/bootstrap/hosts
dosym "$ansible_private/host_vars" /.ansible/bootstrap/host_vars
dosym "$ansible_scripts/scripts" /.ansible/bootstrap/playbooks
dosym "$ansible_scripts/roles" /.ansible/bootstrap/playbooks/roles

# Now run our bootstrapping
cd /.ansible/bootstrap
ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_network
ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_users
ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_sudo
ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_diskmgmt

# Provision our hosts file into its proper location.
cp "$ansible_private/hosts/$server" /etc/ansible/hosts

# At this point, our behaviour depends on whether this is the first ever run or not.
# 
# If this is *not* the first run, then our persistent storage disk should already have
# everything we need -- so the ansible runs above should already have bind mounted
# everything else to setup the proper ansible directory.  Otherwise, we need to go through
# and setup ssh keys, and create these checkouts.

# Validate we have persistent storage -- if we dont, we dont proceed
[[ -d "/store" ]] || fail "/store persistent storage does not exist"

# Now, setup a basic ssh configuration, with keys for both github and gitlab
if [[ ! -d "$ssh_dir" ]]; then
	mkdir -p $ssh_dir || fail "Failed to create $ssh_dir"
	chown $user: $ssh_dir || fail "Failed to set ownership of $ssh_dir"
	chmod 700 $ssh_dir || fail "Failed to chmod $ssh_dir"

	# Now we've created the .ssh directory, we need to re-run ansibles disk provisioning
	# in order to bind mount this under the users .ssh folder.
	ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_diskmgmt
fi

if [[ ! -f "$ssh_dir/config" ]]; then
	echo -e "Host github.com\n\tIdentityFile /home/$user/.ssh/id_github\n\nHost gitlab.com\n\tIdentityFile /home/$user/.ssh/id_gitlab" > $ssh_dir/config || fail "Failed to create ssh config"
fi

if [[ ! -f "$ssh_dir/id_github" ]]; then
	echo "Generating github ssh key"
	ssh-keygen -qt ed25519 -f "$ssh_dir/id_github" || fail "Failed to generate github ssh key"
	echo "Public key for github:"
	cat $ssh_dir/id_github.pub
	echo
	echo "In order to proceed, this key needs to be valid on github."
	read -s -p "Press enter to continue."
	echo
fi

if [[ ! -f "$ssh_dir/id_gitlab" ]]; then
	echo "Generating gitlab ssh key"
	ssh-keygen -qt ed25519 -f "$ssh_dir/id_gitlab" || fail "Failed to generate gitlab ssh key"
	echo "Public key for gitlab:"
	cat $ssh_dir/id_gitlab.pub
	echo
	echo "In order to proceed, this key needs to be valid on gitlab."
	read -s -p "Press enter to continue."
	echo
fi

if [[ ! -d "$ansible_dir" ]]; then
	mkdir -p $ansible_dir || fail "Failed to create $ansible_dir"
	chown $user: $ansible_dir || fail "Failed to set ownership of $ansible_dir"
	chmod 750 $ansible_dir || fail "Failed to chmod $ansible_dir"
fi

# Track whether we're creating ansible folders, which will require yet another bootstrap to add
# the bind mounts into /etc/ansible/
run_bootstrap=0

if [[ ! -d "$ansible_dir/ansible-scripts" ]]; then
	sudo -iu $user git clone git@github.com:leehuk/ansible-scripts.git $ansible_dir/ansible-scripts || fail "Error: Failed to checkout ansible"
	run_bootstrap=1
fi


if [[ ! -d "$ansible_dir/ansible-private" ]]; then
	sudo -iu $user git clone git@gitlab.com:leehuk/ansible-private.git $ansible_dir/ansible-private || fail "Error: Failed to checkout ansible"
	run_bootstrap=1
fi

if [[ $run_bootstrap -ne 0 ]]; then
	ansible-playbook -i hosts playbooks/role-runner.yml -e host="$server" -e role=core_diskmgmt
fi

# We are done with /.ansible at this point, so clean it up
rm -rf /.ansible

# And now we've bootstrapped, we need to reboot.
echo "Reboot required.
read -s -p "Press enter to continue."

sudo /sbin/shutdown -r now
