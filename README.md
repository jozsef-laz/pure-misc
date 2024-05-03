### About
Some scripts I made and (hopefully) will be useful for others as well.

### Content
* `artifactory_search.sh` - prints which hash of the specified branch has artifacts in artifactory
* `collect.sh` - collects logfiles from EASim clusters in a similar structure as jenkins hits
* `ghsync` - syncs the specified branches in your fork repo from `upstream`
  * fetches the branches from `origin`
  * optionally updates local branches too
* `run-ir-test.sh` - command to set up clusters and run ir test
  * bootstrapping cluster
  * creating replication vip
  * creating array connection
  * exchanging certificates
  * starting ir test
  * etc.
