#!/usr/bin/env bash

function render-atomically {
  local target=$1
  shift

  local candidate
  candidate=$(mktemp "${target}.tmp.XXXXXX")

  if "$@" > "${candidate}"; then
    mv "${candidate}" "${target}"
  else
    local status=$?
    rm -f "${candidate}"
    return "${status}"
  fi
}
