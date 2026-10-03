#!/usr/bin/env bash
#
# Troca o account ID da AWS em todos os manifestos (imagens no ECR, ARNs das
# roles IRSA e URLs das filas SQS). Rode uma vez, depois de criar a conta, e
# commite o resultado — o account ID não é segredo.
#
# Uso:
#   ./scripts/set-aws-account.sh <account_id_novo> [account_id_atual]
#
#   account_id_atual  default: 000000000000 (o placeholder deste repositório)
#
# Exemplo:
#   ./scripts/set-aws-account.sh "$(aws sts get-caller-identity --query Account --output text)"
#
set -euo pipefail

NEW="${1:-}"
OLD="${2:-000000000000}"

[[ "$NEW" =~ ^[0-9]{12}$ ]] || { echo "uso: $0 <account_id de 12 dígitos> [account_id_atual]" >&2; exit 1; }
[[ "$OLD" =~ ^[0-9]{12}$ ]] || { echo "account_id_atual inválido: $OLD" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t FILES < <(grep -rl --include='*.yaml' "$OLD" "$ROOT/apps" "$ROOT/platform" "$ROOT/clusters" || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "nenhum arquivo contém $OLD — nada a fazer"
  exit 0
fi

sed -i "s/$OLD/$NEW/g" "${FILES[@]}"
echo "account ID trocado em ${#FILES[@]} arquivos ($OLD -> $NEW). Revise com: git diff --stat"
