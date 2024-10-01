#!/usr/bin/env bash

LOGTYPES_DEFAULT_ARG="middleware,platform,nfs"
DEFAULT_NUMBER_OF_LOGFILES=3

usage() {
   echo "Usage: $0 -c <clusters> [-h]" 1>&2
   echo "  -c <clusters>   where clusters are names of clusters separated by comma (ex. \"irp871-c01,irp871-c02\")" 1>&2
   echo "  -l <logtypes>   list of logtypes which we want to download (separated by comma)" 1>&2
   echo "                     possible values:" 1>&2
   echo "                      - middleware: middleware.log" 1>&2
   echo "                      - platform: platform.log of FMs" 1>&2
   echo "                      - platform_blades: platform.log of blades" 1>&2
   echo "                      - nfs: nfs.log of blades" 1>&2
   echo "                      - system: system.log of FMs" 1>&2
   echo "                      - system_blades: system.log of blades" 1>&2
   echo "                      - haproxy_blades: haproxy.log of blades" 1>&2
   echo "                      - atop_blades: atop measurements on blades" 1>&2
   echo "                     default value: \"$LOGTYPES_DEFAULT_ARG\"" 1>&2
   echo "  -d <dir path>   relative path where log pack directory shall be created" 1>&2
   echo "                     (ex. \"path/to/downloads\", then logs will be under \"path/to/downloads/irpXXX-cXX_2024-01-30-T17-00-37)" 1>&2
   echo "                     only irpXXX-cXX... directory will be created but no parents (for safety considerations)" 1>&2
   echo "  -n <number>     collect only the last <number> of logfiles, default value: $DEFAULT_NUMBER_OF_LOGFILES" 1>&2
   echo "  -h              help" 1>&2
   exit 1
}

while getopts "c:l:d:n:h" o; do
   case "${o}" in
      c)
         CLUSTERS_ARG=${OPTARG}
         ;;
      l)
         LOGTYPES_ARG=${OPTARG}
         ;;
      d)
         DIR_PREFIX=${OPTARG}
         ;;
      n)
         NUMBER_OF_LOGFILES=${OPTARG}
         ;;
      *)
         usage
         ;;
   esac
done
shift $((OPTIND-1))

if [ -z "${CLUSTERS_ARG}" ]; then
   usage
fi

CLUSTERS=$(echo "$CLUSTERS_ARG" | sed -e "s/,/ /g")
echo -ne "Used clusters:\n   "
for CLUSTER in $CLUSTERS; do
   echo -n " [$CLUSTER]"
done
echo

if [ -z "${LOGTYPES_ARG}" ]; then
   LOGTYPES_ARG=$LOGTYPES_DEFAULT_ARG
fi
if [ -z "${NUMBER_OF_LOGFILES}" ]; then
   NUMBER_OF_LOGFILES=$DEFAULT_NUMBER_OF_LOGFILES
fi
echo "logtypes to download: [$LOGTYPES_ARG]"
echo "number of each logfile type: [$NUMBER_OF_LOGFILES]"
DOWNLOAD_MIDDLEWARE_LOG=$(echo "$LOGTYPES_ARG" | grep "middleware")
DOWNLOAD_PLATFORM_LOG=$(echo "$LOGTYPES_ARG" | grep "platform")
DOWNLOAD_PLATFORM_BLADES_LOG=$(echo "$LOGTYPES_ARG" | grep "platform_blades")
DOWNLOAD_NFS_LOG=$(echo "$LOGTYPES_ARG" | grep "nfs")
DOWNLOAD_SYSTEM_LOG=$(echo "$LOGTYPES_ARG" | grep "system")
DOWNLOAD_SYSTEM_BLADES_LOG=$(echo "$LOGTYPES_ARG" | grep "system_blades")
DOWNLOAD_HAPROXY_BLADES_LOG=$(echo "$LOGTYPES_ARG" | grep "haproxy_blades")
DOWNLOAD_ATOP_BLADES_LOG=$(echo "$LOGTYPES_ARG" | grep "atop_blades")

#declare -A LOGNAME_PATTERN=( \
#   ["middleware"]="middleware.log" \
#   ["platform"]="platform.log" \
#   ["platform_blades"]="platform.log" \
#   ["nfs"]="nfs.log" \
#   ["system"]="system.log" \
#   ["system_blades"]="system.log" \
#)

# TODO: use this
SSH_PARAMS="\
   -o UserKnownHostsFile=/dev/null \
   -o StrictHostKeyChecking=no \
   -o LogLevel=ERROR"

DATE=$(date "+%F-T%H-%M-%S")
# directory in which we download the logs
# we use the first cluster's name, because that's what indentifies the testbed
FIRST_CLUSTER=$(echo $CLUSTERS | cut -d" " -f1)
DIR="${FIRST_CLUSTER}_$DATE"
echo "DIR_PREFIX=[$DIR_PREFIX]"
if [ ! -z "$DIR_PREFIX" ]; then
   DIR="$DIR_PREFIX/$DIR"
fi
DIR=$(realpath $DIR)
echo "Directory in which we download the logs: $DIR"

mkdir $DIR
rm -f $DIR_PREFIX/latest-collection
ln -s $DIR $DIR_PREFIX/latest-collection

download_file() {
   REMOTE_FILEPATH=$1
   LOCAL_FILEPATH=$2
   echo -n "Downloading: $REMOTE_FILEPATH ..."
   sshpass -p welcome scp $SSH_PARAMS \
      $REMOTE_FILEPATH $LOCAL_FILEPATH
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp: RETVAL=$RETVAL"
   else
      echo " Done"
   fi
}

download_file_from_blade() {
   LOGFILE=$1
   BLADE_DIR=$2
   BLADENUM=$3
   FM_IP=$4
   CLUSTER=$5
   DIR_ON_BLADE=$6
   if [ -z "$DIR_ON_BLADE" ]; then
      DIR_ON_BLADE="/logs"
   fi
   echo -n "Downloading: Cluster=[$CLUSTER] Ip=[$FM_IP] BLADENUM=[$BLADENUM] LOGFILE=[$LOGFILE] DIR_ON_BLADE=[$DIR_ON_BLADE] ..."

   # TODO: instead of double scp this would be nicer, but logging in to ir1 gives "ir@ir1: Permission denied (publickey)."
   #       with this we wouldn't need FM_IP
   # scp -v -o 'ProxyCommand sshpass -p welcome ssh irp871-c01 nc %h %p' -o PubkeyAuthentication=no -o PreferredAuthentications=password ir1:/logs/nfs.log .
   # workaround idea: download the necessary key file from cluster to local machine, add to the keychain (ssh-add) and then with AgentForwarding we can
   # already login to the blade

   # first copy the file from blade to FM, and then from FM to local machine
   sshpass -p welcome ssh $SSH_PARAMS \
      ir@$FM_IP \
      "rm -f $LOGFILE; scp ir$BLADENUM:$DIR_ON_BLADE/$LOGFILE ."
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp #1: RETVAL=$RETVAL"
      return
   fi
   sshpass -p welcome scp $SSH_PARAMS \
      ir@$FM_IP:/home/ir/$LOGFILE $BLADE_DIR
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp #2: RETVAL=$RETVAL"
      return
   fi
   # cleanup
   sshpass -p welcome ssh $SSH_PARAMS \
      ir@$FM_IP "rm -f $LOGFILE"
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in cleanup: RETVAL=$RETVAL"
      return
   fi
   # TODO: proper log about what happened
   echo " Done"
}

for CLUSTER in $CLUSTERS; do
   echo -e "\n-------- Collecting logs from CLUSTER=[$CLUSTER] --------\n"

   FMNUM_LIST=(1 2)
   for FMNUM in ${FMNUM_LIST[@]}; do
      echo "collecting from FM #$FMNUM"
      # getting admin ip of FM
      FM_IP=$(sshpass -p welcome ssh $SSH_PARAMS \
         ir@$CLUSTER "purenetwork list --csv | grep 'fm$FMNUM.admin0,' | cut -d',' -f5")
      FM_DIR=$DIR/${CLUSTER}_sup${FMNUM}_${FM_IP}
      echo "FM_IP = [$FM_IP], FM_DIR=[$FM_DIR]"
      mkdir $FM_DIR
      # TODO: put these in function
      if [ ! -z "$DOWNLOAD_MIDDLEWARE_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$FM_IP "cd /logs; ls middleware.log* -tr | tail --lines $NUMBER_OF_LOGFILES")
         echo "LOGFILES=[$LOGFILES]"
         for LOGFILE in $LOGFILES; do
            download_file ir@$FM_IP:/logs/$LOGFILE $FM_DIR
         done
      fi
      if [ ! -z "$DOWNLOAD_PLATFORM_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$FM_IP "cd /logs; ls platform.log* -tr | tail --lines $NUMBER_OF_LOGFILES")
         echo "LOGFILES=[$LOGFILES]"
         for LOGFILE in $LOGFILES; do
            download_file ir@$FM_IP:/logs/$LOGFILE $FM_DIR
         done
      fi
      if [ ! -z "$DOWNLOAD_SYSTEM_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$FM_IP "cd /logs; ls system.log* -tr | tail --lines $NUMBER_OF_LOGFILES")
         echo "LOGFILES=[$LOGFILES]"
         for LOGFILE in $LOGFILES; do
            download_file ir@$FM_IP:/logs/$LOGFILE $FM_DIR
         done
      fi
   done

   # for transferring the logs, we use FM1, because usually the active one is FM2
   FM1_IP=$(sshpass -p welcome ssh $SSH_PARAMS \
      ir@$CLUSTER "purenetwork list --csv | grep 'fm1.admin0,' | cut -d',' -f5")
   BLADENUM=$(sshpass -p welcome ssh $SSH_PARAMS \
      ir@$CLUSTER "pureblade list | grep healthy | tail -n1 | cut -d' ' -f1 | cut -d'B' -f2")
   echo "Cluster has $BLADENUM blades"
   for NUM in $(seq 1 $BLADENUM); do
      echo "downloading from ir$NUM"
      BLADE_DIR=$DIR/$CLUSTER/ir$NUM
      mkdir -p $BLADE_DIR

      # TODO: future improvement could be to limit how many logs we download from a blade or for how much time in the past we're looking back
      if [ ! -z "$DOWNLOAD_NFS_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$CLUSTER "ssh ir$NUM \"cd /logs; ls nfs.log nfs.log.* -tr | tail --lines $NUMBER_OF_LOGFILES\"")
         for LOGFILE in $LOGFILES; do
            download_file_from_blade $LOGFILE $BLADE_DIR $NUM $FM1_IP $CLUSTER
         done
      fi
      if [ ! -z "$DOWNLOAD_PLATFORM_BLADES_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$CLUSTER "ssh ir$NUM \"cd /logs; ls platform.log* -tr | tail --lines $NUMBER_OF_LOGFILES\"")
         for LOGFILE in $LOGFILES; do
            download_file_from_blade $LOGFILE $BLADE_DIR $NUM $FM1_IP $CLUSTER
         done
      fi
      if [ ! -z "$DOWNLOAD_SYSTEM_BLADES_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$CLUSTER "ssh ir$NUM \"cd /logs; ls system.log* -tr | tail --lines $NUMBER_OF_LOGFILES\"")
         for LOGFILE in $LOGFILES; do
            download_file_from_blade $LOGFILE $BLADE_DIR $NUM $FM1_IP $CLUSTER
         done
      fi
      if [ ! -z "$DOWNLOAD_HAPROXY_BLADES_LOG" ]; then
         LOGFILES=$(sshpass -p welcome ssh $SSH_PARAMS \
            ir@$CLUSTER "ssh ir$NUM \"cd /logs; ls haproxy.log* -tr | tail --lines $NUMBER_OF_LOGFILES\"")
         for LOGFILE in $LOGFILES; do
            download_file_from_blade $LOGFILE $BLADE_DIR $NUM $FM1_IP $CLUSTER
         done
      fi
      if [ ! -z "$DOWNLOAD_ATOP_BLADES_LOG" ]; then
         download_file_from_blade alma.raw $BLADE_DIR $NUM $FM1_IP $CLUSTER /home/ir
      fi
   done
done

echo "decompressing every .zst file we downloaded in DIR=[$DIR] ..."
find $DIR -name '*.zst' -exec sh -c 'zstd -d "{}"; rm -f "{}"' \;

cp ir_test.log $DIR

echo "Directory in which the logs are downloaded: $DIR"
