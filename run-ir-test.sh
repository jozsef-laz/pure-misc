#! /bin/bash
CLUSTERS_DEFAULT=(irp871-c76 irp871-c77)
printf -v CLUSTERS_DEFAULT_JOINED_EXTRA_COMMA '%s,' "${CLUSTERS_DEFAULT[@]}"
CLUSTERS_DEFAULT_JOINED="${CLUSTERS_DEFAULT_JOINED_EXTRA_COMMA%,}"
DEFAULT_DEPLOY_TARGETS="middleware,cpp_release,feature-flags-system,feature-flags-admin,pure-cli,etcd,admin,inuk,plugins,netconf,FF"

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
   echo "  -t <num>        running numbered test, with 0 it lists available testcases" 1>&2
   echo "  -h              help" 1>&2
   echo "  -x              temp: deleting hedghog fs+link and recreating it (with link)" 1>&2
   echo "  --sha=<sha>     sha of the commit to bootstrap to clusters (full sha needed)" 1>&2
   echo "  --branch=<branch>        the branch where the latest available sha shall be used" 1>&2
   echo "                           if both --sha and --branch is specified, --sha is going to be used" 1>&2
   echo "  --clusters=<clusters>    comma separated list of clusters to use for the above commands" 1>&2
   echo "                           Note: some actions assume 2 clusters (eg. certificate exchange)" 1>&2
   echo "  --deploy-targets=<targets>    comma separated list of targets to tree deploy" 1>&2
   echo "                                for the list of targets see: ./run tools/remote/tree_deploy.py -h" 1>&2
   echo "                                Default: $DEFAULT_DEPLOY_TARGETS" 1>&2
   echo "  --only-clean             when used with -x, hedghog fs+link will be only cleaned, not recreated" 1>&2
   echo "  --reverse-connect        when used with -c, second cluster is going to be the source array" 1>&2
   echo "                           and first one is going to be the target array" 1>&2
   echo "" 1>&2
   echo "examples:" 1>&2
   echo "   for preparing a testbed for MW replication integration tests:" 1>&2
   echo "      $0 -i -d -a -r -e -f" 1>&2
   echo "   initing testbed for s3 test:" 1>&2
   echo "      $0 -i -d -f" 1>&2
   echo "   running test:" 1>&2
   echo "      $0 -t" 1>&2
   echo "   mixed version usage:" 1>&2
   echo "      $0 -i --clusters=c1 --sha=abcd [-d]" 1>&2
   echo "      $0 -i --clusters=c2 --sha=efgh [-d]" 1>&2
   echo "      $0 --cluster=c1,c2 <other opts>" 1>&2
   exit 1
}

die() { echo "$*" >&2; exit 2; }
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }

while getopts "idarceflt:xh-:" OPT; do
   # support long options: https://stackoverflow.com/a/28466267/519360
   if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
      OPT="${OPTARG%%=*}"       # extract long option name
      OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
      OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
      echo "long option detected: OPT=[$OPT], OPTARG=[$OPTARG]"
   fi
   case "$OPT" in
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
      t) RUN_TEST=1; TEST_NUM=$OPTARG ;;
      x) X_RECREATE_HEDGEHOG=1 ;;
      sha) needs_arg; SHA=$OPTARG ;;
      branch) needs_arg; BRANCH=$OPTARG ;;
      clusters)
         needs_arg
         CLUSTERS_JOINED=$OPTARG
         CLUSTERS_STR=$(echo "$CLUSTERS_JOINED" | sed -e "s/,/ /g")
         CLUSTERS=($CLUSTERS_STR)
         ;;
      deploy-targets) needs_arg; DEPLOY_TARGETS=$OPTARG ;;
      only-clean) X_ONLY_CLEAN=1 ;;
      reverse-connect) C_REVERSE_CONNECT=1 ;;
      h) usage ;;
      *) die "Error: Unknown option detected: [$OPT], use option -h to see options";;
   esac
done
shift $((OPTIND-1))

if [ -z "$CLUSTERS_JOINED" ]; then
   CLUSTERS_JOINED=$CLUSTERS_DEFAULT_JOINED
   CLUSTERS=("${CLUSTERS_DEFAULT[@]}")
fi
echo -ne "Used clusters:\n   "
for CLUSTER in ${CLUSTERS[@]}; do
   echo -n " [$CLUSTER]"
done
echo

if [ -z "$DEPLOY_TARGETS" ]; then
   DEPLOY_TARGETS=$DEFAULT_DEPLOY_TARGETS
fi
date
echo

if [ "$INITIATE_CLUSTER" == "1" ] || [ "$RUN_TEST" == "1" ]; then
   if [ -z "$SHA" ]; then
      if [ -z "$BRANCH" ]; then
         BRANCH="HEAD"
      fi
      SHA=$(artifactory_search.sh -l -b $BRANCH)
      retval=$?
      echo "artifactory_search.sh returned SHA=[$SHA] for BRANCH=[$BRANCH]"
      retval_check $retval
   fi
fi

if [ "$INITIATE_CLUSTER" == "1" ]; then
   echo "---> bootstrapping clusters [$CLUSTERS_JOINED] to sha [$SHA] <---"
   time ./run ./tools/python/simctl sim \
      -a $CLUSTERS_JOINED \
      --skip-easim-check \
      clean start \
      --blades 3 \
      --sha $SHA
   retval_check $?
fi

if [ "$TREE_DEPLOY" == "1" ]; then
   git show --quiet
   git status
   rm -f deployed
   echo "# vim: ft=diff" > deployed
   date >> deployed
   echo "---> targets to deploy: DEPLOY_TARGETS=[$DEPLOY_TARGETS] <---" >> deployed
   echo "---> git show <---" >> deployed
   git show --quiet >> deployed
   echo "---> git status <---" >> deployed
   git status >> deployed
   echo "---> git diff --staged <---" >> deployed
   git diff --staged >> deployed
   echo "---> git diff <---" >> deployed
   git diff >> deployed

   echo "---> targets to deploy: DEPLOY_TARGETS=[$DEPLOY_TARGETS] <---"
   for CLUSTER in ${CLUSTERS[@]}; do
      if [ ! -z "$(echo $DEPLOY_TARGETS | grep middleware)" ]; then
         echo "---> tree deploy to cluster [$CLUSTER]: MW <---"
         time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -sa middleware
         retval_check $?
      fi
      if [ ! -z "$(echo $DEPLOY_TARGETS | grep cpp_release)" ]; then
         echo "---> tree deploy to cluster [$CLUSTER]: NFS <---"
         time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -na cpp_release
         retval_check $?
      fi
      if [ ! -z "$(echo $DEPLOY_TARGETS | grep FF)" ]; then
         echo "---> tree deploy to cluster [$CLUSTER]: FF <---"
         time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -sa -na feature-flags-system feature-flags-admin pure-cli etcd admin plugins netconf
         retval_check $?
      fi
      if [ ! -z "$(echo $DEPLOY_TARGETS | grep inuk)" ]; then
         echo "---> tree deploy to cluster [$CLUSTER]: inuk <---"
         time ./run tools/remote/tree_deploy.py -v -a $CLUSTER -sa -na inuk
         retval_check $?
      fi
      echo "---> restarting cluster [$CLUSTER] <--- [$(date)]"
      time ./run tools/remote/restart_sw.py --wait -na -sa restart -a $CLUSTER
      retval_check $?
   done
   echo "---> sleeping for 20 sec <---"
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
   echo "---> connecting arrays <---"
   if [ "$C_REVERSE_CONNECT" == "1" ]; then
      echo "---> reverse connecting arrays ! <---"
      SOURCE_CLUSTER=${CLUSTERS[1]}
      TARGET_CLUSTER=${CLUSTERS[0]}
   else
      SOURCE_CLUSTER=${CLUSTERS[0]}
      TARGET_CLUSTER=${CLUSTERS[1]}
   fi
   echo "---> SOURCE_CLUSTER = [$SOURCE_CLUSTER], TARGET_CLUSTER = [$TARGET_CLUSTER] <---"
   CONNECTION_KEY=$(sshpass -p welcome ssh $SSHARGS \
      ir@$TARGET_CLUSTER \
      "purearray create --connection-key" | tail -n 1)
   MGMT_IP=$(sshpass -p welcome ssh $SSHARGS \
      ir@$TARGET_CLUSTER \
      "purenetwork list --service management --csv" | grep vir0 | cut -d ',' -f4)
   echo "MGMT_IP=[$MGMT_IP], CONNECTION_KEY=[${CONNECTION_KEY:0:34}...]"
   sshpass -p welcome ssh $SSHARGS \
     ir@$SOURCE_CLUSTER \
     "echo "$CONNECTION_KEY" | purearray connect --management-address $MGMT_IP"
fi

if [ "$EXCHANGE_CERTIFICATES" == "1" ]; then
   echo "---> downloading certificates <---"
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
   echo "---> uploading certificates <---"
   for NUM in 0 1; do
      # uploading SRC cluster's certificate to TRG cluster
      OTHER_NUM=$(((NUM+1)%2))
      SRC=${CLUSTERS[$NUM]}
      TRG=${CLUSTERS[$OTHER_NUM]}
      echo "NUM=[$NUM], SRC=[$SRC], TRG=[$TRG]"
      CERTS=$(sshpass -p welcome ssh $SSHARGS \
         ir@${TRG} \
         "purecert list")
      if [ -z "$(echo $CERTS | grep global-$SRC)" ]; then
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
      else
         echo "---> global-$SRC.crt already exists on TRG=[$TRG], skipping... <---"
      fi
   done
fi

if [ "$SET_FEATURE_FLAGS" == "1" ]; then
   echo "---> turning on feature flags <--- [$(date)]"
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
   echo "---> sleeping for 20 sec <---"
   sleep 20
fi

if [ "$CLEAN_LOGS" == "1" ]; then
   echo "---> cleaning logs <--- [$(date)]"
   for CLUSTER in ${CLUSTERS[@]}; do
      echo "CLUSTER = [$CLUSTER]"
      sshpass -p welcome ssh $SSHARGS \
         ir@$CLUSTER \
         "exec.py -na -sa \"sudo rm -rf /logs/*\""
      retval_check $?
   done
fi

if [ "$X_RECREATE_HEDGEHOG" == "1" ]; then
   FSNAME="hedgehog"
   echo "---> are there any replica links? <--- [$(date)]"
   REPLICA_LINK_LIST=$(sshpass -p welcome ssh $SSHARGS \
      ir@${CLUSTERS[0]} \
      "purefs replica-link list $FSNAME")
   if [ ! -z "$(echo $REPLICA_LINK_LIST | grep $FSNAME)" ]; then
      echo "---> removing replica link <--- [$(date)]"
      sshpass -p welcome ssh $SSHARGS \
         ir@${CLUSTERS[0]} \
         "purefs replica-link delete $FSNAME --remote ${CLUSTERS[1]} --cancel-in-progress-transfers"
      echo "---> waiting for heartbeat to remove link on target <--- [$(date)]"
      sleep 15
   fi

   FSINFO=$(sshpass -p welcome ssh $SSHARGS \
      ir@${CLUSTERS[0]} \
      "purefs list --notitle --csv $FSNAME")
   echo -e "---> FSINFO=[\n$FSINFO\n] <--- [$(date)]"
   echo "---> removing replica link <--- [$(date)]"
   sshpass -p welcome ssh $SSHARGS \
      ir@${CLUSTERS[0]} \
      "purefs replica-link delete $FSNAME --remote ${CLUSTERS[1]} --cancel-in-progress-transfers"
   if [ ! -z "$(echo $FSINFO | grep $FSNAME)" ]; then
      if [ ! -z "$(echo $FSINFO | cut -d',' -f7)" ]; then
         echo "---> removing protocol flag from fs on source: FSNAME=[$FSNAME] <--- [$(date)]"
         sshpass -p welcome ssh $SSHARGS \
            ir@${CLUSTERS[0]} \
            "purefs remove --protocol nfsv3 $FSNAME"
      fi
      echo "---> removing fs on source: FSNAME=[$FSNAME] <--- [$(date)]"
       sshpass -p welcome ssh $SSHARGS \
          ir@${CLUSTERS[0]} \
         "purefs destroy --delete-link-on-eradication $FSNAME; purefs eradicate $FSNAME"
      retval_check $?
   fi

   FSINFO_1=$(sshpass -p welcome ssh $SSHARGS \
       ir@${CLUSTERS[1]} \
      "purefs list --notitle --csv $FSNAME")
   if [ ! -z "$(echo $FSINFO_1 | grep $FSNAME)" ]; then
      echo "---> removing fs on target: FSNAME=[$FSNAME] <--- [$(date)]"
      sshpass -p welcome ssh $SSHARGS \
         ir@${CLUSTERS[1]} \
         "purefs destroy $FSNAME; purefs eradicate $FSNAME"
      retval_check $?
   fi

   if [ "$X_ONLY_CLEAN" != "1" ]; then
      echo "---> creating fs on source: FSNAME=[$FSNAME] <--- [$(date)]"
      sshpass -p welcome ssh $SSHARGS \
         ir@${CLUSTERS[0]} \
         "purefs create $FSNAME"
      retval_check $?
      echo "---> adding protocol flag to fs on source: FSNAME=[$FSNAME] <--- [$(date)]"
      sshpass -p welcome ssh $SSHARGS \
         ir@${CLUSTERS[0]} \
         "purefs add --protocol nfsv3 $FSNAME"
      retval_check $?
      echo "---> creating replica link <--- [$(date)]"
      sshpass -p welcome ssh $SSHARGS \
         ir@${CLUSTERS[0]} \
         "purefs replica-link create --remote ${CLUSTERS[1]} $FSNAME"
      retval_check $?
   fi
fi

declare -A TEST_DICT=( \
   [1]="ir_test/functional/replication/test_replication_encryption.py::test_cross_version_encrypted_link_creation" \
   [2]="ir_test/functional/replication/replication_throttling.py::test_throttling_trio" \
   [3]="ir_test/functional/replication/test_tc.py" \
   [4]="ir_test/functional/replication/test_replication_with_nfsd_restart.py -k restart_one_or_two_blades_per_resgrp" \
)

if [ "$RUN_TEST" == "1" ]; then
   if [ -z "$TEST_NUM" ] || [ "$TEST_NUM" == "0" ]; then
      echo "---> available testcases <--- [$(date)]"
      for t in ${!TEST_DICT[@]}; do
         echo $t, ${TEST_DICT[$t]}
      done | tac
      exit 0
   elif [ -z "${TEST_DICT[$TEST_NUM]}" ]; then
      echo "Error: TEST_NUM=$TEST_NUM does not exist in TEST_DICT:"
      for t in ${!TEST_DICT[@]}; do
         echo $t, ${TEST_DICT[$t]}
      done | tac
      exit 1
   else
      TESTCASE=${TEST_DICT[$TEST_NUM]}
   fi
   echo "---> checking  <--- [$(date)]"
   ( cd /home/ir/work/initiator_tools
      if [ ! -f initiator_tools-$SHA-1404.tar.gz ]; then
         pure_artifacts fetch --path build/$SHA/ubuntu1404 initiator_tools.tar.gz
         retval_check $?
         mv initiator_tools.tar.gz initiator_tools-$SHA-1404.tar.gz
      fi
   )
   echo "---> running the test <--- [$(date)]"
   echo "---> TEST_NUM=[$TESTNUM], TESTCASE=[$TESTCASE] <--- [$(date)]"
   time PS_FEATURE_FLAG_ENCRYPTED_FILE_REPLICATION=true AD_TEST_DOMAINS="dc=ir-jad2019,dc=local" ./run ir_test/exec_test \
      --update_initiators=0 \
      --verbose \
      --config ${CLUSTERS[0]} \
      $TESTCASE
   TEST_RESULT=$?

   echo "---> collecting the logs <---"
   time collect.sh -d triage -c $CLUSTERS_JOINED -l platform,middleware,nfs,platform_blades,system,system_blades -n 2

   RED='\033[0;31m'
   GREEN='\033[0;32m'
   NC='\033[0m'
   if [ "$TEST_RESULT" == "0" ]; then
      echo -e "\n${GREEN}SUCCESS${NC}\n"
   else
      echo -e "\n${RED}TEST FAILED${NC}, but otherwise ${GREEN}OK${NC}\n"
   fi
fi
