#! /bin/bash
CLUSTERS=(irp871-c76 irp871-c77)
printf -v CLUSTERS_JOINED_EXTRA_COMMA '%s,' "${CLUSTERS[@]}"
CLUSTERS_JOINED="${CLUSTERS_JOINED_EXTRA_COMMA%,}"

retval_check () {
   RETVAL=$1
   if [ $RETVAL != 0 ]; then
      exit $RETVAL
   fi
}

SSHARGS=" \
   -o UserKnownHostsFile=/dev/null \
   -o StrictHostKeyChecking=no \
   -o LogLevel=ERROR \
"

usage() {
   echo "Usage: $0 <opts>" 1>&2
   echo "  -i              initiates cluster (clean & start)" 1>&2
   echo "  -d              tree deploy" 1>&2
   echo "  -a              update appliance_id" 1>&2
   echo "  -r              create replication vip on all clusters" 1>&2
   echo "  -c              create array connection between arrays" 1>&2
   echo "  -e              exchange certificates" 1>&2
   echo "  -f              turning on feature flags on clusters" 1>&2
   echo "  -l              clean logs (on FMs & blades: /logs/*)" 1>&2
   echo "  -t              running test" 1>&2
   echo "  -h              help" 1>&2
   echo "" 1>&2
   echo "examples:" 1>&2
   echo "   for preparing a testbed for MW replication integration tests:" 1>&2
   echo "      $0 -i -d -a -r -e -f" 1>&2
   echo "   initing testbed for s3 test:" 1>&2
   echo "      $0 -i -d -f" 1>&2
   echo "   running test:" 1>&2
   echo "      $0 -t" 1>&2
   exit 1
}

while getopts "idarceflth" o; do
   case "${o}" in
      i)
         INITIATE_CLUSTER=1
         ;;
      d)
         TREE_DEPLOY=1
         ;;
      a)
         UPDATE_APPLIANCE_ID=1
         ;;
      r)
         CREATE_REPLICATION_VIP=1
         ;;
      c)
         CONNECT_ARRAYS=1
         ;;
      e)
         EXCHANGE_CERTIFICATES=1
         ;;
      f)
         SET_FEATURE_FLAGS=1
         ;;
      l)
         CLEAN_LOGS=1
         ;;
      t)
         RUN_TEST=1
         ;;
      *)
         usage
         ;;
   esac
done
shift $((OPTIND-1))

SHA="7a9ce3994b0a57efa68159b35405dd33b35f7cf3"
# SHA2=""
if [ "$INITIATE_CLUSTER" == "1" ]; then
   if [ "$SHA2" == "" ]; then
      echo "---> bootstrapping clusters [$CLUSTERS_JOINED] to sha [$SHA] <---"
      time ./run ./tools/python/simctl sim \
         -a $CLUSTERS_JOINED \
         --skip-easim-check \
         clean start \
         --blades 3 \
         --sha $SHA
      retval_check $?
   else
      echo "---> bootstrapping clusters to different versions <---"
      echo "---> bootstrapping cluster [${CLUSTERS[0]}] to sha [$SHA] <---"
      time ./run ./tools/python/simctl sim \
         -a ${CLUSTERS[0]} \
         --skip-easim-check \
         clean start \
         --blades 3 \
         --sha $SHA
      retval_check $?
      echo "---> bootstrapping cluster [${CLUSTERS[1]}] to sha [$SHA2] <---"
      time ./run ./tools/python/simctl sim \
         -a ${CLUSTERS[1]} \
         --skip-easim-check \
         clean start \
         --blades 3 \
         --sha $SHA2
      retval_check $?
   fi
fi

if [ "$TREE_DEPLOY" == "1" ]; then
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "---> tree deploy to cluster [$CLUSTER]: MW <---"
      time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -sa middleware
      retval_check $?
      echo "---> tree deploy to cluster [$CLUSTER]: NFS <---"
      time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -na cpp_release
      retval_check $?
      echo "---> tree deploy to cluster [$CLUSTER]: FF <---"
      time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -sa -na feature-flags-system feature-flags-admin pure-cli etcd admin plugins netconf
      retval_check $?
      echo "---> restarting cluster [$CLUSTER] <--- [$(date)]"
      time ./run tools/remote/restart_sw.py --wait -na -sa restart -a $CLUSTER
      retval_check $?
   done
   echo "---> sleeping for 20 sec <----"
   sleep 20
fi

if [ "$UPDATE_APPLIANCE_ID" == "1" ]; then
   echo "---> update appliance_id on the second cluster: ${CLUSTERS[1]} <---"
   if [ ${#CLUSTERS[@]} -lt 2 ]; then
     echo "Error: CLUSTERS array needs to have at least 2 items, but it has only the following ${#CLUSTERS[@]}:"
     for CLUSTER in ${CLUSTERS[@]}; do
        echo "    $CLUSTER"
     done
     exit 1
   fi

   # to prevent this:
   # array_config.py: Put key appliance_id failed: EtcdError: KV client is not ready (code: -32021)
   sleep 10

   sshpass -p welcome ssh $SSHARGS \
     ir@${CLUSTERS[1]} \
     "sudo /opt/ir/admin/internal/array_config.py put appliance_id '\"00000000-0000-4000-8000-000000000001\"'"
   retval_check $?
fi

if [ "$CREATE_REPLICATION_VIP" == "1" ]; then
   echo "---> creating replication vip on clusters <---"
   time ./run ./tools/python/simctl sim --skip-easim-check --admin-vip $CLUSTERS_JOINED create-repl-vip
   retval_check $?

   echo "---> check about replication vip <---"
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "CLUSTER = [$CLUSTER]"
      RESULT=$(sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "purenetwork list | grep replication")
      retval_check $?
      if [ -z "$RESULT" ]; then
         echo "could not find replication vip on $CLUSTER"
      else
         echo "$RESULT"
      fi
      echo $RESULT
   done
fi

if [ "$CONNECT_ARRAYS" == "1" ]; then
   echo "---> connecting arrays <----"
   CONNECTION_KEY=$(sshpass -p welcome ssh $SSHARGS \
      ir@${CLUSTERS[1]} \
      "purearray create --connection-key" | tail -n 1)
   MGMT_IP=$(sshpass -p welcome ssh $SSHARGS \
      ir@${CLUSTERS[1]} \
      "purenetwork list --service management --csv" | grep vir0 | cut -d ',' -f4)
   echo "MGMT_IP=[$MGMT_IP], CONNECTION_KEY=[${CONNECTION_KEY:0:34}...]"
   sshpass -p welcome ssh $SSHARGS \
     ir@${CLUSTERS[0]} \
     "echo "$CONNECTION_KEY" | purearray connect --management-address $MGMT_IP"
fi

if [ "$EXCHANGE_CERTIFICATES" == "1" ]; then
   echo "---> downloading certificates <----"
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "CLUSTER = [$CLUSTER]"
      sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "purecert list --certificate global --notitle | cut -c9- > ~/global-$CLUSTER.crt"
      retval_check $?
      sshpass -p welcome scp $SSHARGS \
         ir@$CLUSTER:/home/ir/global-$CLUSTER.crt .
      retval_check $?
   done
   echo "---> uploading certificates <----"
   for NUM in 0 1; do
      # uploading SRC cluster's certificate to TRG cluster
      OTHER_NUM=$(((NUM+1)%2))
      SRC=${CLUSTERS[$NUM]}
      TRG=${CLUSTERS[$OTHER_NUM]}
      echo "NUM=[$NUM], SRC=[$SRC], TRG=[$TRG]"
      sshpass -p welcome scp $SSHARGS \
         global-$SRC.crt ir@$TRG:/home/ir
      retval_check $?
      sshpass -p welcome ssh $SSHARGS \
         ir@$TRG \
         "cat global-$SRC.crt | purecert create --ca-certificate global-$SRC"
      retval_check $?
      sshpass -p welcome ssh $SSHARGS \
         ir@$TRG \
         "purecert add --group _default_replication_certs global-$SRC"
      retval_check $?
   done
fi

if [ "$SET_FEATURE_FLAGS" == "1" ]; then
   echo "---> turning on feature flags <---- [$(date)]"
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "CLUSTER = [$CLUSTER]"
      sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "exec.py -na -sa \"sudo purefeatureflags reset-all\""
      retval_check $?
      sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "exec.py -na -sa \"sudo purefeatureflags enable --flags PS_FEATURE_FLAG_ENCRYPTED_FILE_REPLICATION\""
      retval_check $?
      echo "---> restarting cluster [$CLUSTER] <--- [$(date)]"
      time ./run tools/remote/restart_sw.py --wait -na -sa restart -a $CLUSTER
      retval_check $?
   done
   echo "---> sleeping for 20 sec <----"
   sleep 20
fi

if [ "$CLEAN_LOGS" == "1" ]; then
   echo "---> cleaning logs <---- [$(date)]"
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "CLUSTER = [$CLUSTER]"
      sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "exec.py -na -sa \"sudo rm -rf /logs/*\""
      retval_check $?
   done
fi

if [ "$RUN_TEST" == "1" ]; then
   echo "---> running the test <---- [$(date)]"
   PS_FEATURE_FLAG_ENCRYPTED_FILE_REPLICATION=true time ./run ir_test/exec_test \
      --update_initiators=0 \
      -v \
      --config ${CLUSTERS[0]} \
      ir_test/functional/replication/test_replication_encryption.py \
      -k test_fb_to_fb_secure_repl_nfsd_traffic
   TEST_RESULT=$?

   echo "---> collecting the logs <----"
   time collect.sh -d triage -c $CLUSTERS_JOINED -l platform,middleware,nfs,platform_blades,system,system_blades

   RED='\033[0;31m'
   GREEN='\033[0;32m'
   NC='\033[0m'
   if [ "$TEST_RESULT" == "0" ]; then
      echo -e "\n${GREEN}SUCCESS${NC}\n"
   else
      echo -e "\n${RED}TEST FAILED${NC}, but otherwise ${GREEN}OK${NC}\n"
   fi
fi
