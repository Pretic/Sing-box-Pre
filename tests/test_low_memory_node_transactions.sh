#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
TEST_LOW_MEMORY=1 bash "$root/test_change_identity_transactions.sh"
TEST_LOW_MEMORY=1 bash "$root/test_extra_protocol_transactions.sh"
echo 'Low-memory identity/SNI/extra protocol commit, rejection, rollback and stopped-service matrix passed.'
