#!/bin/bash
#
set -e

MOD_SRC=$1

usage() {
  echo "$0 modules_src_dir"
  printf "\tmodules_src_dir:\tpath to prosody-modules mercurial source\n"
}

refresh_sources() {
  echo "refresh sources at $MOD_SRC"
  ( cd "$MOD_SRC" &&  hg pull && hg update )
}

copy_modules() {
  while read -r dir ; do
    if [ -d "$MOD_SRC/$dir" ] ; then
      cp -vr "$MOD_SRC/$dir" plugins
    else
      echo "$MOD_SRC/$dir no longer there"
    fi
  done < prosody-modules.list
}

get_revision_id() {
  (cd "$MOD_SRC/$dir" && hg id -i) > 'prosody-modules.revision'
}

if [ $# -ne 1 ] ; then
  echo "wrong number of parameters" >&2
  usage
  exit 1
fi

if ! [ -d "$MOD_SRC" ] ; then
  printf "modules_src_dir[%s] not found\n" "$MOD_SRC"
fi

refresh_sources
copy_modules
get_revision_id
exit 0
