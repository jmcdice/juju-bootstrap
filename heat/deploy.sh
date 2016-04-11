#!/usr/bin/bash
#
# This should deploy our heat stack and include all the stuff we 
# need to know about.

NET_ID=$(nova net-list | awk '/ floating / { print $2 }')

heat stack-create -f epdgd_example.yml \
   -P public_net=$NET_ID \
   epdg-stack-00

