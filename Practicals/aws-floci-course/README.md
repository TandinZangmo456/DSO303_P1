# AWS CLI + Floci — USMS Course Project

Infrastructure for the University Student Management System (USMS), built lab by lab
with the AWS CLI against Floci, a local AWS emulator.

## Quick start
    source configs/course.env
    ./scripts/setup/floci-up.sh
    ./scripts/utilities/whoami.sh

## Daily workflow
    ./scripts/setup/floci-up.sh      # start or resume (idempotent)
    ./scripts/setup/floci-down.sh    # pause; state is kept

## Never run these
| Command | Why |
|---|---|
| docker compose down -v | -v deletes volumes |
| docker volume prune | Unfiltered |
| floci start ... | Bypasses Compose |
| rm -rf ~/floci-data | That directory is the IAM state |

## Labs
| Lab | Topic | Status |
|-----|-------|--------|
| 01  | IAM   | [x] complete |
| 02  | VPC   | [ ] not started |

## Conventions
- All resources are prefixed usms-
- Region: us-east-1 · Floci account: 000000000000
- Storage mode: hybrid, bind-mounted to ~/floci-data
- Secrets live in outputs/ and are never committed
