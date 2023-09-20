#! /bin/bash
RCol='\e[0m'

Red='\e[0;31m'
Gre='\e[0;32m'
BYel='\e[1;33m'
BBlu='\e[1;34m'
Pur='\e[0;35m'

NUM_OF_COMMITS_TO_CHECK=20

BRANCH=$1
git --no-pager log --graph --decorate -$NUM_OF_COMMITS_TO_CHECK --oneline --abbrev-commit $BRANCH
SHAS=$(git log -$NUM_OF_COMMITS_TO_CHECK --pretty=format:'%H' $BRANCH)
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
