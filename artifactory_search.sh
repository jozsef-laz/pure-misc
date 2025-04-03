#! /bin/bash

RCol='\e[0m'

Red='\e[0;31m'
Gre='\e[0;32m'
BYel='\e[1;33m'
BBlu='\e[1;34m'
Pur='\e[0;35m'

DEFAULT_NUM_OF_COMMITS_TO_CHECK=20
DEFAULT_UBUNTU_VERSION="2404"

usage() {
   echo "Usage: $0 <opts>" 1>&2
   echo "  -l              print latest sha which is usable" 1>&2
   echo "  -b <branch>     branchname (or commit, tag). If not specified, HEAD is going to be used" 1>&2
   echo "  -u <version>    ubuntu version to check in artifactory, eg: 1404, 1804, 2204, 2404, default: $DEFAULT_UBUNTU_VERSION" 1>&2
   echo "  -c <count>      number of commits to check, default: $DEFAULT_NUM_OF_COMMITS_TO_CHECK" 1>&2
   echo "  -h              help" 1>&2
   echo "" 1>&2
   echo "examples:" 1>&2
   echo "   none for now..." 1>&2
   exit 1
}

die() { echo "$*" >&2; exit 2; }
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }

while getopts "b:lu:c:h" OPT; do
   case "$OPT" in
      b) needs_arg; BRANCH=$OPTARG ;;
      l) LATEST_SHA=1 ;;
      u) needs_arg; UBUNTU_VERSION=$OPTARG ;;
      c) needs_arg; NUM_OF_COMMITS_TO_CHECK=$OPTARG ;;
      *) usage ;;
   esac
done
shift $((OPTIND-1))

# do not log when using -l option, because it's mostly used in scripts
if [ -z "$BRANCH" ] && [ -z "$LATEST_SHA" ]; then
   echo "No branchname was given (-b option), using HEAD"
fi

if [ -z "$UBUNTU_VERSION" ]; then
   # do not log when using -l option, because it's mostly used in scripts
   if [ -z "$LATEST_SHA" ]; then
      echo "No ubuntu version was given (-u option), using $DEFAULT_UBUNTU_VERSION"
   fi
   UBUNTU_VERSION=$DEFAULT_UBUNTU_VERSION
fi

if [ -z "$NUM_OF_COMMITS_TO_CHECK" ]; then
   NUM_OF_COMMITS_TO_CHECK=$DEFAULT_NUM_OF_COMMITS_TO_CHECK
fi

SHAS=$(git log -$NUM_OF_COMMITS_TO_CHECK --pretty=format:'%H' $BRANCH)

if [ "$LATEST_SHA" == "1" ]; then
   for SHA in $SHAS
   do
      LINK="https://pure-artifactory.dev.purestorage.com/artifactory/iridium-artifacts/build/$SHA/ubuntu${UBUNTU_VERSION}/iros.img.gz"
      IROS_HTTP_RESULT=$(wget --spider --server-response $LINK 2>&1 | awk '/^  HTTP/{print $2}')
      if [ "$IROS_HTTP_RESULT" == "200" ]; then
         echo -n "$SHA"
         exit 0
      fi
   done
   >&2 echo "Error: Could not find any available sha in the last $NUM_OF_COMMITS_TO_CHECK shas."
   exit 1
fi

color_result() {
   HTTP_RESULT=${1:-NA}
   if [ "$HTTP_RESULT" == "200" ]
   then
      RESULT_COLORED="$Gre$HTTP_RESULT$RCol"
   else
      RESULT_COLORED="$Red$HTTP_RESULT$RCol"
   fi
   echo $RESULT_COLORED
}

git --no-pager log --graph --decorate -$NUM_OF_COMMITS_TO_CHECK --oneline --abbrev-commit $BRANCH
echo "DIR: whether the directory for the sha exists on artifactory"
echo "IROS: whether iros.img.gz exists in the directory"
echo "                    SHA                  - DIR - IROS - LINK"
for SHA in $SHAS
do
   DIR_LINK="https://pure-artifactory.dev.purestorage.com/artifactory/iridium-artifacts/build/$SHA/ubuntu${UBUNTU_VERSION}/"
   IROS_LINK="https://pure-artifactory.dev.purestorage.com/artifactory/iridium-artifacts/build/$SHA/ubuntu${UBUNTU_VERSION}/iros.img.gz"
   DIR_HTTP_RESULT=$(wget --spider --server-response $DIR_LINK 2>&1 | awk '/^  HTTP/{print $2}')
   IROS_HTTP_RESULT=$(wget --spider --server-response $IROS_LINK 2>&1 | awk '/^  HTTP/{print $2}')
   DIR_COLORED_RES=$(color_result $DIR_HTTP_RESULT)
   IROS_COLORED_RES=$(color_result $IROS_HTTP_RESULT)
   if [ "$DIR_HTTP_RESULT" == "200" ]
   then
      echo -e "$SHA - $DIR_COLORED_RES - $IROS_COLORED_RES  - $DIR_LINK"
   else
      echo -e "$SHA - $DIR_COLORED_RES - $IROS_COLORED_RES"
   fi
done
