#!/usr/bin/env bash
# After enabling Lake Formation: remove the IAMAllowedPrincipals default grants so that
# LF (not plain IAM/S3 permissions) decides who can read what.  Usage: scripts/lf_lockdown.sh <db> [<db>...]
set -euo pipefail
for db in "$@"; do
  echo "Revoking IAM_ALLOWED_PRINCIPALS on $db"
  aws lakeformation revoke-permissions --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
    --permissions ALL --resource "{\"Database\":{\"Name\":\"$db\"}}" || true
  aws lakeformation revoke-permissions --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
    --permissions ALL --resource "{\"Table\":{\"DatabaseName\":\"$db\",\"TableWildcard\":{}}}" || true
done
