#!/bin/bash
export FMT="%-9s%-8s%-8s%s\n"

export VAULT_CLAUSE=""
for vault_key_file in *vault.key; do
  if [[ -f "$vault_key_file" ]]; then
    export VAULT_CLAUSE="$VAULT_CLAUSE --vault-password-file $vault_key_file"
  fi
done

for env in $(find .. -maxdepth 2 -type d); do

  pgpkey=$env/pgp.key
  pgppub=$env/pgp.pub
  if [[ -r $pgppub ]]; then
    gpg --import $pgppub &> /dev/null
    if [[ $? -eq 0 ]]; then
      printf $FMT "[  ok  ]" import "pub key" $pgppub
    else
      printf $FMT "[ fail ]" import "pub key" $pgppub
    fi
  fi
  if [[ -r $pgpkey ]]; then
    ansible-vault decrypt $VAULT_CLAUSE $pgpkey &>/dev/null
    if [[ $? -eq 0 ]]; then
      printf $FMT "[  ok  ]" decrypt "pgp key" $pgpkey
      gpg --import --allow-secret-key $pgpkey &> /dev/null
      if [[ $? -eq 0 ]]; then
        git checkout -- $pgpkey
        printf $FMT "[  ok  ]" import "pgp key" $pgpkey
      else
        printf $FMT "[ fail ]" import "pgp key" $pgpkey
      fi
    else
      printf $FMT "[ fail ]" decrypt "pgp key" $pgpkey
    fi
  fi

done
