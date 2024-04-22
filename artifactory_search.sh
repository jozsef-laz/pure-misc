#! /bin/bash
#
# Usage: ./artifactory_search.sh <branch>
#
# where <branch> can be:
#  - anything git log understands, eg. branchname, commit sha, etc.
#  - empty, in this case HEAD is condsidered as the base commit for search

RCol='\e[0m'

Red='\e[0;31m'
Gre='\e[0;32m'
BYel='\e[1;33m'
BBlu='\e[1;34m'
Pur='\e[0;35m'

NUM_OF_COMMITS_TO_CHECK=20

usage() {
   echo "Usage: $0 <opts>" 1>&2
   echo "  -l              print latest sha which is usable" 1>&2
   echo "  -b <branch>     branchname (or commit, tag). If not specified, HEAD is going to be used" 1>&2
   echo "  -h              help" 1>&2
   echo "" 1>&2
   echo "examples:" 1>&2
   echo "   none for now..." 1>&2
   exit 1
}

die() { echo "$*" >&2; exit 2; }
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }

while getopts "b:lh" OPT; do
   case "$OPT" in
      b) needs_arg; BRANCH=$OPTARG ;;
      l) LATEST_SHA=1 ;;
      *) usage ;;
   esac
done
shift $((OPTIND-1))

if [ -z "$BRANCH" ]; then
   echo "No branchname was given (-b option), using HEAD"
fi

SHAS=$(git log -$NUM_OF_COMMITS_TO_CHECK --pretty=format:'%H' $BRANCH)

if [ "$LATEST_SHA" == "1" ]; then
   for SHA in $SHAS
   do
      LINK="https://pure-artifactory.dev.purestorage.com/artifactory/iridium-artifacts/build/$SHA/ubuntu1804/"
      HTTP_RESULT=$(wget --spider --server-response $LINK 2>&1 | awk '/^  HTTP/{print $2}')
      if [ "$HTTP_RESULT" == "200" ]; then
         echo -n "$SHA"
         exit 0
      fi
   done
   echo "Error: Could not find any available sha in the last $NUM_OF_COMMITS_TO_CHECK shas."
   exit 1
fi

git --no-pager log --graph --decorate -$NUM_OF_COMMITS_TO_CHECK --oneline --abbrev-commit $BRANCH
for SHA in $SHAS
do
   LINK="https://pure-artifactory.dev.purestorage.com/artifactory/iridium-artifacts/build/$SHA/ubuntu1804/"
   HTTP_RESULT=$(wget --spider --server-response $LINK 2>&1 | awk '/^  HTTP/{print $2}')
   if [ "$HTTP_RESULT" == "200" ]
   then
      RESULT_COLORED="$Gre$HTTP_RESULT$RCol - $LINK"
   else
      RESULT_COLORED="$Red$HTTP_RESULT$RCol"
   fi
   echo -e "$SHA - $RESULT_COLORED"
done
