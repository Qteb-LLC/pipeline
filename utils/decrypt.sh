#!/bin/bash

# Determine the base directory (parent of utils/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

export GNUPGHOME=$HOME/.gnupg
mkdir -p $GNUPGHOME
export FMT="%-9s%-8s%-8s%s\n"

# Collect all *vault.key files to use as vault password file sources
export VAULT_CLAUSE=""
# Search in current directory and utils/ directory
for vault_key_file in *vault.key "$SCRIPT_DIR"/*vault.key; do
  if [[ -f "$vault_key_file" ]]; then
    export VAULT_CLAUSE="$VAULT_CLAUSE --vault-password-file $vault_key_file"
  fi
done

function check_packages() {
    PACKAGES=(gpg ansible sops)
    NOT_INSTALLED_PACKAGES=""
    OS=$(uname -s)

    for PACKAGE in ${PACKAGES[@]}; do
        if ! (which $PACKAGE > /dev/null 2>&1); then
            NOT_INSTALLED_PACKAGES+="$PACKAGE "
        fi
    done

    if [ -n "$NOT_INSTALLED_PACKAGES" ]; then
        echo "Packages: $NOT_INSTALLED_PACKAGES, is NOT installed."
        read -p "Do you want to install them now? [y/n] default y: " install_pkgs

        if [  -z "$install_pkgs" ] || [ "$install_pkgs" = "y" ]; then
            for PACKAGE in $NOT_INSTALLED_PACKAGES; do
                echo -e "Installation of the $PACKAGE begins...\n"
                case "$OS" in
                    Darwin)
                        brew install $PACKAGE
                        ;;
                    Linux)
                        source /etc/os-release
                        case "$ID" in
                            almalinux|rhel|centos)
                                sudo dnf install -y $PACKAGE
                                ;;
                            debian|ubuntu)
                                sudo apt-get update
                                sudo apt-get install -y $PACKAGE
                                ;;
                            *)
                                echo "Unknown Linux distribution: $ID"
                                exit 1
                                ;;
                        esac
                        ;;
                    *)
                        echo "Unknown OS: $OS"
                        exit 1
                        ;;
                esac
                echo -e "\n\n"
            done
        else
            echo "Automatic installation has been cancelled."
            echo "Before running the script again, you must install the packages yourself."
            exit 0
        fi
    fi
}

import_pgp_key() {

  pgp_key="$1"

  # Check if readable
  # TODO: do we need it at all?
  if [[ ! -r $pgp_key ]]; then return; fi

  # Decrypt private key
  ansible-vault decrypt $VAULT_CLAUSE $pgp_key &>/dev/null
  if [[ $? -ne 0 ]]; then
    printf $FMT "[ fail ]" decrypt "pgp key" $pgp_key
    return
  fi
  printf $FMT "[  ok  ]" decrypt "pgp key" $pgp_key

  # Import key
  gpg --import --allow-secret-key $pgp_key &>/dev/null
  if [[ $? -eq 0 ]]; then
    git checkout -- $pgp_key &>/dev/null
    printf $FMT "[  ok  ]" import "pgp key" $pgp_key
  else
    printf $FMT "[ fail ]" import "pgp key" $pgp_key
  fi

}

check_packages

for pgp_key in $(find "$BASE_DIR/conf" -type f -name "pgp.key"); do
  import_pgp_key "$pgp_key"
done

for encfile in $(grep -rlE '"?sops"?:' "$BASE_DIR"); do
  parent_dir=$(dirname $encfile)
  file_name=$(basename $encfile)
  $(cd $parent_dir && sops -i -d $file_name &>/dev/null)
  if [[ $? -eq 0 ]]; then
    chmod 0600 $encfile &>/dev/null
    printf $FMT "[  ok  ]" decrypt file $encfile
  else
    printf $FMT "[ fail ]" decrypt file $encfile
  fi
done

rm -rf $GNUPGHOME
if [[ $? -eq 0 ]]; then
  echo "[  ok  ] remove decrypted keys"
else
  echo "[ fail ] remove decrypted keys"
fi
