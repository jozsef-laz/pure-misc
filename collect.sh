#!/usr/bin/env bash

usage() {
   echo "Usage: $0 -c <clusters> [-h]" 1>&2
   echo "  -c <clusters>   where clusters are names of clusters separated by comma (ex. \"irp871-c01,irp871-c02\")" 1>&2
   echo "  -h              help" 1>&2
   exit 1
}

while getopts "c:h" o; do
   case "${o}" in
      c)
         CLUSTERS_ARG=${OPTARG}
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

DATE=$(date "+%F-T%H-%M-%S")
# directory in which we download the logs
# we use the first cluster's name, because that's what indentifies the testbed
FIRST_CLUSTER=$(echo $CLUSTERS | cut -d" " -f1)
DIR="${FIRST_CLUSTER}_$DATE"
echo "Directory in which we download the logs: $DIR"

mkdir $DIR
rm -f latest-collection
ln -s $DIR latest-collection

download_file() {
   REMOTE_FILEPATH=$1
   LOCAL_FILEPATH=$2
   echo -n "Downloading: $REMOTE_FILEPATH ..."
   sshpass -p welcome scp \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      -o LogLevel=ERROR \
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
   echo -n "Downloading: Cluster=[$CLUSTER] Ip=[$FM_IP] BLADENUM=[$BLADENUM] LOGFILE=[$LOGFILE] ..."

   # TODO: instead of double scp this would be nicer, but logging in to ir1 gives "ir@ir1: Permission denied (publickey)."
   #       with this we wouldn't need FM_IP
   # scp -v -o 'ProxyCommand sshpass -p welcome ssh irp871-c01 nc %h %p' -o PubkeyAuthentication=no -o PreferredAuthentications=password ir1:/logs/nfs.log .

   # first copy the file from blade to FM, and then from FM to local machine
   sshpass -p welcome ssh \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      ir@$FM_IP "rm -f $LOGFILE; scp ir$BLADENUM:/logs/$LOGFILE ."
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp #1: RETVAL=$RETVAL"
   fi
   sshpass -p welcome scp \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      -o LogLevel=ERROR \
      ir@$FM_IP:/home/ir/$LOGFILE $BLADE_DIR
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp #2: RETVAL=$RETVAL"
   fi
   # cleanup
   sshpass -p welcome ssh \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      ir@$FM_IP "rm -f $LOGFILE"
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in cleanup: RETVAL=$RETVAL"
   fi
}

for CLUSTER in $CLUSTERS; do
   echo -e "\n-------- Collecting logs from CLUSTER=[$CLUSTER] --------\n"

   FMNUM_LIST=(1 2)
   for FMNUM in ${FMNUM_LIST[@]}; do
      echo "collecting from FM #$FMNUM"
      # getting admin ip of FM
      FM_IP=$(sshpass -p welcome ssh \
         -o "UserKnownHostsFile=/dev/null" \
         -o "StrictHostKeyChecking=no" \
         ir@$CLUSTER "purenetwork list --csv | grep 'fm$FMNUM.admin0,' | cut -d',' -f4")
      FM_DIR=$DIR/${CLUSTER}_sup${FMNUM}_${FM_IP}
      echo "FM_IP = [$FM_IP], FM_DIR=[$FM_DIR]"
      mkdir $FM_DIR
      LOGFILES=$(sshpass -p welcome ssh \
         -o "UserKnownHostsFile=/dev/null" \
         -o "StrictHostKeyChecking=no" \
         ir@$FM_IP "cd /logs; ls middleware.log* platform.log*")
      echo "LOGFILES=[$LOGFILES]"
      for LOGFILE in $LOGFILES; do
         download_file ir@$FM_IP:/logs/$LOGFILE $FM_DIR
         # if it's zstd file, decompress it
         if [ $(echo "$LOGFILE" | grep "\.zst$") ] ; then
            zstd -d $FM_DIR/$LOGFILE
            rm $FM_DIR/$LOGFILE
         fi
      done
   done

   # for transferring the logs, we use FM1, because usually the active one is FM2
   FM1_IP=$(sshpass -p welcome ssh \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      ir@$CLUSTER "purenetwork list --csv | grep 'fm1.admin0,' | cut -d',' -f4")
   BLADENUM=$(sshpass -p welcome ssh \
      -o "UserKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=no" \
      ir@$CLUSTER "pureblade list | grep healthy | tail -n1 | cut -d' ' -f1 | cut -d'B' -f2")
   echo "Cluster has $BLADENUM blades"
   for NUM in $(seq 1 $BLADENUM); do
      echo "downloading from ir$NUM"
      BLADE_DIR=$DIR/$CLUSTER/ir$NUM
      mkdir -p $BLADE_DIR

      # TODO: future improvement could be to limit how many logs we download from a blade or for how much time in the past we're looking back
      LOGFILES=$(sshpass -p welcome ssh \
         -o "UserKnownHostsFile=/dev/null" \
         -o "StrictHostKeyChecking=no" \
         ir@$CLUSTER "ssh ir$NUM \"cd /logs; ls nfs.log nfs.log.*\"")
      for LOGFILE in $LOGFILES; do
         download_file_from_blade $LOGFILE $BLADE_DIR $NUM $FM1_IP $CLUSTER
         if [ $(echo "$LOGFILE" | grep "\.zst$") ] ; then
            zstd -d $BLADE_DIR/$LOGFILE
            rm $BLADE_DIR/$LOGFILE
         fi
      done
   done
done

cp ../../ir_test.log latest-collection

