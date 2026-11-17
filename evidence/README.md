# Evidence

Raw results of every run, written by the scripts in the repository root. Nothing here is edited by hand.

| Folder | Written by | Contents |
|---|---|---|
| `cycles/` | `run-cycle.ps1` | One file per patch or scan cycle: `cycle-<mode>-<execution id>.json` (the Step Functions result for every host). `cycle-*-manual-*` are single-host passes run by hand during the iterations |
| `tests/` | `test-rhel.ps1`, `test-win.ps1` | Read-only precheck and scan of a host, before and after patching |
| `restore/` | `restore-baseline.ps1` | Every return of a host to its baseline AMI |
| `deploy/` | `deploy-framework.ps1`, `deploy-monitoring.ps1`, `deploy-site.ps1` | The latest deployment of each part, with the code hashes (`deploy-phase-b/d.json` are the earlier names) |
| `exp3/` | `exp3-scale.ps1` | Experiment 3: clone launches, one result per level (`exp3-<series>-n<hosts>-*.json`) and the summary CSV of each series |
| `exp4/` | `exp4-prices.ps1` | Experiment 4: ap-southeast-5 list prices from the AWS Price List API (the CSV holds the rows used, the JSON every price returned) |
| `website/` | screenshots | Setup of the project website (CloudFront, S3, certificate, DNS) |

Times in file names are local (MYT, UTC+8).
