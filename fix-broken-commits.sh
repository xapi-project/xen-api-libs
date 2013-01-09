#!/bin/sh

# xen-api-libs fails a "git fsck" because it has bad author and committer
# email addresses of the form:
export BAD='Jonathan.Ludlam@eu.citrix.com <Jon Ludlam <Jonathan.Ludlam@eu.citrix.com'

git filter-branch -f --commit-filter '
  echo "id = $GIT_COMMIT committer date = $GIT_COMMITTER_DATE" >> /tmp/foo
  echo "id = $GIT_COMMIT author date = $GIT_AUTHOR_DATE" >> /tmp/foo
  echo "id = $GIT_COMMIT committer email = \"$GIT_COMMITTER_EMAIL\"" >> /tmp/foo
  echo "id = $GIT_COMMIT author email    = \"$GIT_AUTHOR_EMAIL\"" >> /tmp/foo
  if [ "${GIT_COMMITTER_EMAIL}" = "${BAD}" ]
  then
     export GIT_COMMITTER_NAME="Jonathan Ludlam"
     export GIT_AUTHOR_NAME="Jonathan Ludlam"
     export GIT_COMMITTER_EMAIL="Jonathan.Ludlam@eu.citrix.com"
     export GIT_AUTHOR_EMAIL="Jonathan.Ludlam@eu.citrix.com"
     echo Rewrote >> /tmp/foo
  fi
  git commit-tree "$@";
' --tag-name-filter cat -- --all

rm -rf .git/refs/original/ && git reflog expire --all &&  git gc --aggressive --prune
