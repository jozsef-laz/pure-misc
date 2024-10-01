#! /bin/bash
BASE_DIR=$(pwd)
CLUSTER_INFO_FILE="cluster-info.txt"

#ack "Starting heartbeat rpc_type=array_conn_heartbeat" -l
# finding out portal blades
for irpdir in $(ls -d irp[0-9][0-9][0-9]-c[0-9][0-9]); do
   nfs_logs=$(ack -g 'nfs.log' $irpdir)
   portal_logs=$(ack --files-with-matches --match "Starting heartbeat rpc_type=array_conn_heartbeat" $nfs_logs)
   echo -n "portal blade on cluster $irpdir: " >> $CLUSTER_INFO_FILE
   echo $portal_logs | cut -d '/' -f 2 | sort | uniq | awk '{print $1}' | paste -s -d, - >> $CLUSTER_INFO_FILE
done

# collecting IPs
if [ -f ir_test.log ]; then
   ack --match '"ipv4_admin_vip": "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"|"name": "irp[0-9][0-9][0-9]-c[0-9][0-9]"' ir_test.log | awk '{$1=$1};1' | uniq | paste -s -d' \n' >> $CLUSTER_INFO_FILE
else
   echo "no ir_test.log found"
fi
