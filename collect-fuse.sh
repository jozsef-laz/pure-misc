#!/usr/bin/env bash

LOGTYPES_DEFAULT_ARG="middleware,platform,nfs"
DEFAULT_NUMBER_OF_LOGFILES=3
USERNAME=jlaz

retval_check () {
   RETVAL=$1
   if [ $RETVAL != 0 ]; then
      exit $RETVAL
   fi
}

usage() {
   echo "Usage: $0 args..." 1>&2
   echo "  -c <cluster>    cluster whose logs we need (ex. fern)" 1>&2
   echo "  -s              use fuse-staging instead of fuse" 1>&2
   echo "  -l <logtypes>   list of logtypes which we want to download (separated by comma)" 1>&2
   echo "                     possible values:" 1>&2
   echo "                      - middleware: middleware.log" 1>&2
   echo "                      - platform: platform.log of FMs" 1>&2
   echo "                      - platform_blades: platform.log of blades" 1>&2
   echo "                      - nfs: nfs.log of blades" 1>&2
   echo "                      - system: system.log of FMs" 1>&2
   echo "                      - system_blades: system.log of blades" 1>&2
   echo "                     default value: \"$LOGTYPES_DEFAULT_ARG\"" 1>&2
   echo "  -d <dir path>   relative path where log pack directory shall be created" 1>&2
   echo "                     (ex. \"path/to/downloads\", then logs will be under \"path/to/downloads/irpXXX-cXX_2024-01-30-T17-00-37)" 1>&2
   echo "                     only irpXXX-cXX... directory will be created but no parents (for safety considerations)" 1>&2
   echo "  --date <date>         the date we need data for (format: YYYY-MM-DD)" 1>&2
   echo "  --min-hour <hour>     the minimum hour we need data for in 24 hour format" 1>&2
   echo "  --max-hour <hour>      the maximum hour we need data for in 24 hour format" 1>&2
   echo "  --cluster-dir-on-fuse <path>    the dir where 'goto <cluster>' brings on fuse (without date)" 1>&2

   echo "  -h              help" 1>&2
   exit 1
}

die() { echo "$*" >&2; exit 2; }
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }

while getopts "c:sl:d:h-:" OPT; do
   # support long options: https://stackoverflow.com/a/28466267/519360
   if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
      OPT="${OPTARG%%=*}"       # extract long option name
      OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
      OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
      echo "long option detected: OPT=[$OPT], OPTARG=[$OPTARG]"
   fi
   case "$OPT" in
      c) CLUSTER=${OPTARG} ;;
      s) USE_STAGING=1 ;;
      l) LOGTYPES_ARG=${OPTARG} ;;
      d) DIR_PREFIX=${OPTARG} ;;
      date) needs_arg; DATE=$OPTARG ;;
      min-hour) needs_arg; MIN_HOUR=$OPTARG ;;
      max-hour) needs_arg; MAX_HOUR=$OPTARG ;;
      cluster-dir-on-fuse) needs_arg; CLUSTER_DIR_ON_FUSE=$OPTARG ;;
      *) usage ;;
   esac
done
shift $((OPTIND-1))

if [ -z "${CLUSTER}" ]; then
   usage
fi

echo -ne "Used cluster: [$CLUSTER]"
echo

if [ -z "${USE_STAGING}" ]; then
   FUSE_SERVER="fuse"
else
   FUSE_SERVER="fuse-staging"
fi

if [ -z "${LOGTYPES_ARG}" ]; then
   LOGTYPES_ARG=$LOGTYPES_DEFAULT_ARG
fi
echo "logtypes to download: [$LOGTYPES_ARG]"
echo "date: [$DATE]"
if [ -z "$MIN_HOUR" ]; then
   MIN_HOUR=0
fi
if [ -z "$MAX_HOUR" ]; then
   MAX_HOUR=23
fi
if (( $MAX_HOUR < $MIN_HOUR )); then
   echo "Error: min-hour should be less or equal to max-hour! MIN_HOUR=[$MIN_HOUR], MAX_HOUR=[$MAX_HOUR]"
   exit 1
fi
echo "minimum hour: [$MIN_HOUR]"
echo "maximum hour: [$MAX_HOUR]"

does_logtype_contain() {
   SPECIFIC_LOGTYPE=$1
   echo "$LOGTYPES_ARG" | grep "$SPECIFIC_LOGTYPE"
}
#declare -A LOGNAME_PATTERN=( \
#   ["middleware"]="middleware.log" \
#   ["platform"]="platform.log" \
#   ["platform_blades"]="platform.log" \
#   ["nfs"]="nfs.log" \
#   ["system"]="system.log" \
#   ["system_blades"]="system.log" \
#)

SSHARGS=" \
   -o UserKnownHostsFile=/dev/null \
   -o StrictHostKeyChecking=no \
   -o LogLevel=ERROR \
"

CURRENT_DATE=$(date "+%F-T%H-%M-%S")
# directory in which we download the logs
# we use the first cluster's name, because that's what indentifies the testbed
DIR="${CLUSTER}_$DATE-T$MIN_HOUR"
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
   scp $SSHARGS \
      $REMOTE_FILEPATH $LOCAL_FILEPATH
   RETVAL=$?
   if [ $RETVAL != 0 ]; then
      echo " Error in scp: RETVAL=$RETVAL"
   else
      echo " Done"
   fi
}

get_desired_logs() {
   LOGFILENAME=$1
   # MIN_HOUR, MAX_HOUR come from global var
   DESIRED_LOGS=""
   for HOUR in $(seq $MIN_HOUR $MAX_HOUR); do
      HOUR_2DIGIT=$(printf "%02d" $HOUR)
      DESIRED_LOGS="$DESIRED_LOGS $LOGFILENAME.$DATE.$HOUR_2DIGIT-*"
   done
   echo $DESIRED_LOGS
}

# fuse uses underscore
FUSE_DATE=$(echo $DATE | sed -e "s/-/_/g")
echo "FUSE_DATE=[$FUSE_DATE]"

download_desired_logs() {
   # relying on global vars instead of passing 10 vars :(
   FM=$1
   DESIRED_LOGS=$2
   LOCAL_DIR=$3
   echo "FM=$FM, DESIRED_LOG=$DESIRED_LOGS, LOCAL_DIR=$LOCAL_DIR"
   LOGFILES=$(ssh $SSH_PARAMS \
      $USERNAME@$FUSE_SERVER "cd $CLUSTER_DIR_ON_FUSE/$FUSE_DATE/$FM; ls $DESIRED_LOGS")
   echo "LOGFILES=[$LOGFILES]"
   for LOGFILE in $LOGFILES; do
      download_file $USERNAME@$FUSE_SERVER:$CLUSTER_DIR_ON_FUSE/$FUSE_DATE/$FM/$LOGFILE $LOCAL_DIR
   done
}

#ssh $SSH_PARAMS \
#   $FUSE_SERVER "goto $CLUSTER; pwd"
if [ -z "$CLUSTER_DIR_ON_FUSE" ]; then
   echo "Error: please add path with --cluster-dir-on-fuse argument (goto <cluster>, without date)"
fi

echo -e "\n-------- Collecting logs from CLUSTER=[$CLUSTER] --------\n"

LOGDIRS=$(ssh $SSH_PARAMS \
   $USERNAME@$FUSE_SERVER "cd $CLUSTER_DIR_ON_FUSE/$FUSE_DATE; ls")

echo "LOGDIRS=[$LOGDIRS]"
FM_DIRS=$(echo $LOGDIRS | sed 's/ /\n/g' | grep "fm[12]$")
echo "FM_DIRS=[$FM_DIRS]"

for FM in $FM_DIRS; do
   LOCAL_FM_DIR=$DIR/${FM}
   mkdir $LOCAL_FM_DIR
   echo "collecting from FM: $FM"
   if [ ! -z "$(does_logtype_contain middleware)" ]; then
      DESIRED_MW_LOGS=$(get_desired_logs "middleware.log")
      echo "DESIRED_MW_LOGS=[$DESIRED_MW_LOGS]"
      download_desired_logs $FM "$DESIRED_MW_LOGS" $LOCAL_FM_DIR
   fi
   echo
   if [ ! -z "$(does_logtype_contain platform)" ]; then
      DESIRED_PLATFORM_LOGS=$(get_desired_logs "platform.log")
      echo "DESIRED_PLATFORM_LOGS=[$DESIRED_PLATFORM_LOGS]"
      download_desired_logs $FM "$DESIRED_PLATFORM_LOGS" $LOCAL_FM_DIR
   fi
   echo
   if [ ! -z "$(does_logtype_contain system)" ]; then
      DESIRED_SYSTEM_LOGS=$(get_desired_logs "system.log")
      echo "DESIRED_SYSTEM_LOGS=[$DESIRED_SYSTEM_LOGS]"
      download_desired_logs $FM "$DESIRED_SYSTEM_LOGS" $LOCAL_FM_DIR
   fi
   echo
done

BLADE_DIRS=$(echo $LOGDIRS | sed 's/ /\n/g' | grep "fb[0-9]\+$")
echo "BLADE_DIRS=[$BLADE_DIRS]"

for BLADE in $BLADE_DIRS; do
   LOCAL_BLADE_DIR=$DIR/$BLADE
   mkdir $LOCAL_BLADE_DIR
   echo "collecting from BLADE: $BLADE"
   if [ ! -z "$(does_logtype_contain nfs)" ]; then
      DESIRED_NFS_LOGS=$(get_desired_logs "nfs.log")
      echo "DESIRED_NFS_LOGS=[$DESIRED_NFS_LOGS]"
      download_desired_logs $FM "$DESIRED_NFS_LOGS" $LOCAL_BLADE_DIR
   fi
   echo
   if [ ! -z "$(does_logtype_contain platform_blades)" ]; then
      DESIRED_PLATFORM_LOGS=$(get_desired_logs "platform.log")
      echo "DESIRED_PLATFORM_LOGS=[$DESIRED_PLATFORM_LOGS]"
      download_desired_logs $FM "$DESIRED_PLATFORM_LOGS" $LOCAL_BLADE_DIR
   fi
   echo
   if [ ! -z "$(does_logtype_contain system_blades)" ]; then
      DESIRED_SYSTEM_LOGS=$(get_desired_logs "system.log")
      echo "DESIRED_SYSTEM_LOGS=[$DESIRED_SYSTEM_LOGS]"
      download_desired_logs $FM "$DESIRED_SYSTEM_LOGS" $LOCAL_BLADE_DIR
   fi
   echo
done

echo "decompressing every .zst file we downloaded in DIR=[$DIR] ..."
find $DIR -name '*.zst' -exec sh -c 'zstd -d "{}"; rm -f "{}"' \;

$(cd $dir; cluster-info.sh)

echo "Directory in which the logs are downloaded: $DIR"
