#!/bin/bash
# Pre-commit hook: проверяет, что секретные файлы в conf/*/ зашифрованы SOPS
# Проверяются только: credentials.yaml, pgp.key
# Если файл содержит маркер SOPS — он зашифрован
# Если нет — файл расшифрован и не должен попасть в коммит

set -e

EXIT_CODE=0

# Файлы, которые должны быть зашифрованы
ENCRYPTED_FILES="credentials.yaml pgp.key"

for file in "$@"; do
    filename=$(basename "$file")

    # Проверяем только файлы из списка в conf/*/
    if [[ "$file" =~ ^conf/[^/]+/ ]]; then
        for secret_file in $ENCRYPTED_FILES; do
            if [[ "$filename" == "$secret_file" ]]; then
                # Для YAML проверяем блок sops:
                # Для pgp.key проверяем $ANSIBLE_VAULT (vault-encrypted)
                if [[ "$filename" == "pgp.key" ]]; then
                    if ! grep -q '^\$ANSIBLE_VAULT' "$file" 2>/dev/null; then
                        echo "ERROR: $file is NOT encrypted!"
                        echo "       This file should be encrypted with ansible-vault"
                        EXIT_CODE=1
                    fi
                else
                    if ! grep -q '"sops":\|^sops:' "$file" 2>/dev/null; then
                        echo "ERROR: $file is NOT encrypted!"
                        echo "       Run 'git checkout -- $file' to restore encrypted version"
                        echo "       or encrypt it with 'sops -e -i $file'"
                        EXIT_CODE=1
                    fi
                fi
            fi
        done
    fi
done

if [[ $EXIT_CODE -ne 0 ]]; then
    echo ""
    echo "Commit blocked: decrypted secrets detected in conf/*/"
    echo "Never commit decrypted secrets to the repository!"
fi

exit $EXIT_CODE
