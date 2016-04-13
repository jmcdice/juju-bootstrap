#!/usr/bin/bash
#
# This should deploy our heat stack and include all the stuff we 
# need to know about.

OS_USERNAME=$(config-get os_username)
OS_TENANT_NAME=$(config-get os_tenant_name)
OS_PASSWORD=$(config-get os_password)
KEYSTONE_ADMIN_TOKEN=$(config-get keystone_admin_token)
OS_AUTH_URL=$(config-get os_auth_url)

heat stack-destroy epdg-stack-00

