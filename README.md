# Centralized Agentless Patch Management using Serverless Orchestration

A serverless framework on AWS that patches Red Hat Enterprise Linux 9 and Windows Server 2022 hosts
**without installing any agent**. A Lambda function reaches each host over its built-in remote protocol
(SSH for RHEL, WinRM for Windows), and AWS Step Functions orchestrates the patch cycle.

```mermaid
flowchart LR
    EB["EventBridge Scheduler<br/>weekly or one-time trigger"]

    SF["Step Functions<br/><b>serverless-patch-cycle</b><br/>parallel branch per host"]
    SM["Secrets Manager<br/>SSH key, WinRM account"]
    LR["Lambda<br/><b>serverless-patch-rhel</b>"]
    LW["Lambda<br/><b>serverless-patch-windows</b>"]
    LM["Lambda<br/><b>serverless-patch-metrics</b>"]
    SNS["Amazon SNS<br/>result email"]
    CW["CloudWatch<br/>logs, metrics, dashboard"]

    R1["RHEL 9<br/>rhel-01 nginx &nbsp;|&nbsp; no agent"]
    R2["RHEL 9<br/>rhel-02 MySQL &nbsp;|&nbsp; no agent"]
    W1["Windows Server 2022<br/>win-01 IIS &nbsp;|&nbsp; no agent"]

    EB -->|starts| SF
    SF --> LR
    SF --> LW
    SF --> LM
    SF -->|publish| SNS
    SM -.-> LR
    SM -.-> LW
    LM -->|EMF| CW
    LR ==>|"SSH 22<br/>dnf upgrade --security"| R1
    LR ==>|"SSH 22"| R2
    LW ==>|"WinRM 5986<br/>Windows Update API"| W1

    classDef trigger fill:#7c3aed,stroke:#5b21b6,color:#ffffff
    classDef orch fill:#e7157b,stroke:#9d0f53,color:#ffffff
    classDef fn fill:#ff9900,stroke:#b36b00,color:#1f2937
    classDef sec fill:#dd344c,stroke:#9b2335,color:#ffffff
    classDef obs fill:#2563eb,stroke:#1e40af,color:#ffffff
    classDef rhel fill:#fee2e2,stroke:#cc0000,stroke-width:2px,color:#7f1d1d
    classDef win fill:#dbeafe,stroke:#0078d4,stroke-width:2px,color:#0c4a6e
    class EB trigger
    class SF orch
    class LR,LW,LM fn
    class SM sec
    class SNS,CW obs
    class R1,R2 rhel
    class W1 win
    linkStyle 8,9 stroke:#cc0000,stroke-width:3px
    linkStyle 10 stroke:#0078d4,stroke-width:3px
```

Region `ap-southeast-5` (Asia Pacific, Malaysia). All resources are tagged `project=serverless-patch`.

## Repository layout

| Path | Purpose |
|---|---|
| `config.ps1` | Shared settings (account, VPC, hosts, baseline AMIs, resource names) and helper functions. Dot-sourced by every script. |
| `lambda/patch_rhel.py` | RHEL actions over SSH: precheck, scan, install_start, install_status, reboot, health. Every scan also logs the update list line by line (`dnf updateinfo list --security`, available and `--installed`) |
| `lambda/patch_windows.py` | Windows actions over WinRM: same six actions; installs through a one-shot SYSTEM scheduled task. Every scan also logs the available KBs and the installed ones (`Get-HotFix`) |
| `lambda/metrics.py` | `serverless-patch-metrics`: per-host and per-cycle records (EMF metrics), cost estimate, email text |
| `lambda/summary_widget.py` | `serverless-patch-summary-widget`: CloudWatch custom widget (coloured Patch Summary panels) |
| `statemachine/patch-cycle.asl.json` | Step Functions workflow `serverless-patch-cycle` (JSONata, parallel Map over hosts) |
| `iam/*.json` | Trust and permission policies (least privilege) |
| `dashboard/dashboard-v3.json` | CloudWatch dashboard `PatchManagement-Dashboard` (template; `dashboard-v2.json` is the earlier layout) |
| `deploy-framework.ps1` | Deploys the patch Lambdas, IAM roles, state machine and the weekly schedule (created disabled) |
| `deploy-monitoring.ps1` | Deploys visibility: SNS topic, metrics Lambda, custom widget Lambda, dashboard. `-DashboardOnly` redraws the dashboard |
| `deploy-site.ps1` | Publishes the project website (`site\`) on CloudFront from a private S3 bucket. `-SkipBuild` uploads without rebuilding the data, `-Domain` adds a custom domain |
| `lab.ps1` | `status`, `start-rhel`, `start-win`, `start-all`, `stop-all`, `endpoint-up`, `endpoint-down` |
| `test-rhel.ps1`, `test-win.ps1` | Read-only precheck and scan, calling the Lambdas directly |
| `run-cycle.ps1` | Starts one patch cycle (`-Mode scan` or `-Mode patch`) and follows it to the end |
| `restore-baseline.ps1` | Returns hosts to their unpatched baseline AMI (EC2 replace root volume) |
| `exp3-scale.ps1` | Experiment 3 (scalability): launch clones, run levels from baseline (RHEL, Windows or mixed), teardown |
| `exp4-prices.ps1` | Experiment 4 (cost): current ap-southeast-5 list prices from the AWS Price List API, saved as evidence (read-only) |
| `evidence/` | Results of every test, cycle, restore and deploy (JSON, CSV) |
| `site/` | Project website: landing page and results dashboard built from `evidence/` (see [Project Website](#project-website)) |
| `build/` | Generated files (not in the repository) |

## Prerequisites

- Windows workstation with **PowerShell 7** and **AWS CLI v2**, signed in with `aws login`
- The testbed from the build record: VPC, three hosts frozen as baseline AMIs, Secrets Manager secrets,
  Lambda layer `serverless-patch-remote-libs` (Paramiko, pywinrm) and the Lambda execution roles
- Run every script from this folder:

```powershell
cd 'C:\AWS Project\deployment'
Get-ChildItem -Recurse | Unblock-File      # only needed for files that came from a download
```

## Deploy

```powershell
.\lab.ps1 endpoint-up          # Secrets Manager interface endpoint (billed hourly while it exists)
.\deploy-framework.ps1           # patch Lambdas, Step Functions, Scheduler
.\deploy-monitoring.ps1           # SNS email, metrics Lambda, custom widget Lambda, dashboard
```

Both deploy scripts are safe to run again. Confirm the SNS subscription email once. The first time the
dashboard opens, allow its custom widgets ("Allow always").

## Run

| Step | Command | Changes hosts? |
|---|---|---|
| Start hosts | `.\lab.ps1 start-all` (or `start-rhel` / `start-win`) | No |
| Read-only checks | `.\test-rhel.ps1`, `.\test-win.ps1` | No |
| Scan cycle | `.\run-cycle.ps1` | No |
| Patch cycle | `.\run-cycle.ps1 -Mode patch -ViaSchedule` | **Yes** (type `PATCH`) |
| Partial cycle | `.\run-cycle.ps1 -Mode patch -Percent 5` | **Yes** (highest severity first) |
| One host only | `.\run-cycle.ps1 -Mode patch -Targets serverless-patch-win-01` | **Yes** |
| Back to baseline | `.\restore-baseline.ps1 -Target rhel-01,rhel-02,win-01` | **Yes** (type `RESTORE`) |
| Shut down | `.\lab.ps1 stop-all`, `.\lab.ps1 endpoint-down` | No |

Windows follow-up passes (iteration 3): the Windows Recovery Environment update (KB5131594) is often still
offered after the first pass, because it only takes effect once Windows has finished servicing the cumulative
update. The cycle therefore reinstalls any selected update the rescan still finds, up to `-Followups` times
(default 2), each after a wait (`-FollowupWaitMinutes`, default 10) and a read-only check that servicing has
settled (uptime at least 15 min, Windows Modules Installer idle, nothing pending). `-Followups 0` restores
the iteration 2 behaviour.

## Demonstration and Evaluation

The report (Chapter 3, Sections 3.5 and 3.6) defines three demonstration runs and four experiments.
Every patch run writes its result to `evidence\` and to the metrics log group, so the same runs feed
several experiments.

| Item | What it shows | How it is produced | Main data |
|---|---|---|---|
| Demonstration Run 1 (Linux) | Both RHEL hosts patched in one cycle | Patch cycle on rhel-01 and rhel-02 | `evidence\cycle-patch-*.json`, SNS email |
| Demonstration Run 2 (Windows) | win-01 patched through the same workflow | Patch cycle on win-01 | `evidence\cycle-patch-*.json`, SNS email |
| Demonstration full cycle | Trigger to email on all three hosts, no agent | Full 3-host cycle via EventBridge | Step Functions execution history, dashboard |
| Experiment 1: deployment time | How long a patch cycle takes, per host and per run | Repetition runs (below) | `duration_s` per host and per cycle |
| Experiment 2: success rate | Updates confirmed fixed / updates attempted, per platform | Repetition runs (below) | `succeeded`, `attempted` per host |
| Experiment 3: scalability | Cycle time as hosts are added | `exp3-scale.ps1` (below) | `evidence\exp3-*-summary-*.csv` |
| Experiment 4: operational cost | Serverless cost of one cycle at AWS prices | Every patch run (automatic) | `cost_usd`, `transitions`, `lambda_invocations` per cycle |

### Experiments 1 and 2: Repetition Runs

Each repetition starts from baseline, so every run patches the same set of missing updates.

```powershell
.\lab.ps1 endpoint-up ; .\lab.ps1 start-all
.\restore-baseline.ps1 -Target rhel-01,rhel-02,win-01                 # type RESTORE, then wait ~4 min
.\run-cycle.ps1 -Mode patch -ViaSchedule                              # all three hosts, follow-ups included, type PATCH
```

Repeat three times with the iteration 3 workflow, and count only those runs for the final figures.
Earlier runs (iterations 1 and 2) are reported as iteration history, not mixed into the final figures.

- **Deployment time (Experiment 1):** `duration_s` per host, from the start of the host's branch to its
  final verified rescan, follow-up passes and waits included. Report the first-pass time separately from
  `install_passes[0].at`.
- **Success rate (Experiment 2):** `succeeded / attempted` per cycle, where succeeded means confirmed fixed
  by the final rescan of that cycle. Report the first-pass figure (`first_pass_succeeded / attempted`) and
  the number of passes next to it.

### Experiment 3: Scalability

RHEL carries the scaling series: the question is whether the orchestration layer keeps up as hosts are added,
and a RHEL run takes about 4 minutes against about 25 for Windows. Each level starts from baseline.

The evaluation ran 1, 2 and 4 RHEL hosts (13 Nov 2026), a smaller series than the 1, 2, 4, 6, 8 first
planned, to fit the time and the AWS credits. These are the commands that produced it:

```powershell
.\lab.ps1 stop-all ; .\lab.ps1 endpoint-up ; .\lab.ps1 start-rhel   # win-01 stopped
.\exp3-scale.ps1 -Action status
.\exp3-scale.ps1 -Action launch -Platform rhel -Total 4               # adds rhel-03 and rhel-04
.\exp3-scale.ps1 -Action run    -Platform rhel -Levels 1,2,4          # type SCALE
.\exp3-scale.ps1 -Action teardown                                     # type TERMINATE
```

The script still supports more levels (`-Total 8 -Levels 1,2,4,6,8` uses all 16 vCPUs with win-01 stopped)
and a Windows add-on (`-Platform windows -Total 2 -Levels 1,2`). Teardown removes only clones tagged
`Experiment=exp3`, never the testbed hosts.

Mixed series (both platforms, testbed ratio of two RHEL hosts to one Windows host): level 3 is the testbed
(rhel-01, rhel-02, win-01) and level 6 doubles it with clones rhel-03, rhel-04 and win-02 (12 of 16 vCPUs).

```powershell
.\lab.ps1 endpoint-up ; .\lab.ps1 start-all
.\exp3-scale.ps1 -Action launch -Platform mixed                      # rhel-03, rhel-04, win-02
.\exp3-scale.ps1 -Action run    -Platform mixed                      # levels 3 and 6, type SCALE
.\exp3-scale.ps1 -Action teardown                                     # type TERMINATE
```

### Experiment 4: Operational Cost

No extra runs are needed: the metrics Lambda estimates the cost of every patch cycle from its execution
history. The prices are environment variables (`PRICE_*`) on `serverless-patch-metrics`; check them against
the ap-southeast-5 prices before reporting: `.\exp4-prices.ps1` reads them from the AWS Price List API and saves them
under `evidence\exp4-prices-*`. The estimate covers the serverless control plane only
(Step Functions, Lambda, SNS). EC2 hosts and the VPC endpoint are excluded by design.

### Results (evaluation period, 1 to 13 Nov 2026)

From `evidence\` and the metrics log group; the same figures the website's Evaluation view and
`PatchManagement-Dashboard` show for that period. Success counts only updates confirmed fixed by the rescan.

| Experiment | Result |
|---|---|
| 1: deployment time | RHEL about 4 min per host (avg 238 s in the final runs); Windows about 32 min (avg 1,936 s). A 3-host cycle takes as long as its Windows branch (avg 1,936 s), because the hosts run in parallel |
| 2: success rate | 99.9% overall (7,766 / 7,774) over 20 patch cycles. RHEL 100% (7,715 / 7,715 advisories), Windows 86.4% (51 / 59 KBs) |
| 3: scalability | RHEL, time per host: 338 s at 1 host, 330 s at 2, 284 s at 4. Whole run 338, 362 and 296 s: no growth as hosts are added |
| 4: operational cost | USD 0.0041 per 3-host patch cycle, USD 0.0029 average over the 20 cycles (USD 0.058 in total). Step Functions, Lambda and SNS only, at list price before the free tier |

Windows success by iteration (the reason the period figure is below the final one):

| Runs | Workflow | Windows result |
|---|---|---|
| 1 Nov | Iteration 2 | 3 of 4 KBs; KB5131594 (Recovery Environment) left for a manual follow-up |
| 4 to 5 Nov | Iteration 3, first runs | Follow-up passes inside the cycle (61 min), still 3 of 4 |
| 7 to 8 Nov | Iteration 3, final (12 runs) | 91.7% (44 / 48): 11 runs installed all 4 KBs on the first pass. One failed its post-reboot health check with WinRM "Access is denied", fixed the same day by a retry (`d8203f4`) |

RHEL was 100% in every run. Later runs (14 and 16 Nov) are outside the evaluation period.

### Exporting Results For The Report

In CloudWatch Logs Insights, select `/aws/lambda/serverless-patch-metrics`, set the time range to the
experiment window, run a query and choose **Export results > Download table (CSV)**.

```
# Experiments 1 and 2: One Row per Host per Patch Run
filter record = 'host' and mode = 'patch'
| fields @timestamp, run_id, host, platform, unit, status, before, after, attempted, succeeded, first_pass_succeeded, passes, duration_s, rebooted, healthy
| sort @timestamp asc

# Experiment 2: Success Rate per Platform
filter record = 'host' and mode = 'patch' and attempted > 0
| stats sum(succeeded) as verified, sum(attempted) as tried, 100 * sum(succeeded) / sum(attempted) as success_pct,
        100 * sum(first_pass_succeeded) / sum(attempted) as first_pass_pct, avg(passes) as avg_passes by platform

# Experiment 3: Cycle Time by Number of RHEL Hosts (also saved as evidence\exp3-rhel-summary-*.csv)
filter record = 'host' and mode = 'patch' and percent = 100 and platform = 'rhel' and status like /^patched/
| stats count(*) as hosts_in_run, max(duration_s) as run_s, avg(duration_s) as host_s by run_id
| stats avg(run_s) as total_workflow_s, avg(host_s) as per_host_s by hosts_in_run
| sort hosts_in_run asc

# Experiment 4: Cost per Cycle
filter record = 'cycle' and mode = 'patch' and hosts_total > 0
| fields @timestamp, run_id, hosts_total, duration_s, transitions, lambda_invocations, lambda_gb_s, cost_usd
| sort @timestamp asc
```

## Project Website

`site/` is a static website that introduces the project and mirrors the CloudWatch dashboard
`PatchManagement-Dashboard`: the same widgets on the same 24-column layout (the text header is left out,
as the page title and the dashboard toolbar already carry it), the same titles,
colours and **Host** selector (`?host=`), in the CloudWatch console style (light and dark). The three
coloured Patch Summary panels are the HTML of `lambda/summary_widget.py` itself; every other widget is
redrawn from the same records and metrics, following its Logs Insights query or metric expression in
`dashboard/dashboard-v3.json`. Times are shown in MYT. Two views, switched at the top of the dashboard;
neither has an end date, so nothing needs changing as more cycles run:

| View | Data | Updates |
|---|---|---|
| **Live** (default) | `data/live.json`: last `$SiteLiveDays` days (14, "Last 2 weeks") from CloudWatch | By itself: rewritten when a cycle starts or finishes, and once a day; open pages re-check every 60 s and show "Patch cycle in progress" while one runs |
| **Evaluation** (`?view=evaluation`) | `data/evaluation.json`: every run since `$SiteFrom` ("Since 1 Nov 2026") from CloudWatch; falls back to `data/patch-data.js` (built from `evidence\`, no cost or orchestration counts) | When the publisher runs (after every cycle, and once a day) |

When the last 2 weeks hold no patch cycle, the page opens on Evaluation instead of an empty Live view
(Live stays one click away).

**Security updates per host.** Two tables side by side, as the Red Hat guide *Identifying security
updates* lists them: **not installed** (`dnf updateinfo list --security`) and **installed**
(`dnf updateinfo list --security --installed`), each in the three columns of `dnf updateinfo list`
(advisory, severity, package build); for Windows the rows are KBs. Each scan step logs these lines to
its own Lambda log group (`record = "update"`, closed by one `update_scan` line with the counts), so
nothing extra passes through the state machine. The two CloudWatch widgets query those log groups
directly (newest scan first, 1,000 lines each); the publisher writes the latest scan of each host to
`data/updates.json` for the website (up to 1,000 lines of each). The lists appear after the first scan or patch cycle that runs
with the updated patch Lambdas (`.\deploy-framework.ps1`).

| File | Purpose |
|---|---|
| `site/index.html` | The page |
| `site/assets/style.css`, `site/assets/dashboard.css`, `site/assets/app.js` | Page styling, CloudWatch-style dashboard styling, dashboard rendering (no libraries) |
| `site/assets/theme.js` | Auto / Light / Dark switch |
| `site/assets/og.png`, `favicon.svg`, `apple-touch-icon.png` | Link preview picture (1200x630) and icons; the picture is rendered from `site-src/og-card.html` (not published) |
| `site-src/build_arch_diagram.py` | Writes the architecture diagram (inline SVG) into `site/index.html`; edit and re-run to change it |
| `site/data/patch-data.js` | Fallback data from `evidence\` (same evidence always gives the same file) |
| `site/build_site_data.py` | Builds that fallback: evidence reports (`cycle-*.json` and the Experiment 3 runs `exp3-*-n*.json`) -> metrics records (`lambda/metrics.py`) -> the publisher's format |
| `lambda/site_publisher.py` | Lambda `serverless-patch-site-publisher`: writes `data/live.json`, `data/evaluation.json` and `data/updates.json` |

To look at the page locally (opened from disk, Evaluation shows the evidence files; Live needs the published site):

```powershell
python site\build_site_data.py
start site\index.html
```

The generated data holds only what the page shows: no account ID, ARNs, instance IDs or IP addresses.
Cost per cycle is not shown, because it is estimated from the execution history in CloudWatch and is
not saved in `evidence\`.

### Publishing

`deploy-site.ps1` publishes the site on CloudFront, in the same account and with the same conventions as
the other deploy scripts (safe to run again):

```powershell
.\deploy-site.ps1             # rebuild the data from evidence\, upload, clear the cache
.\deploy-site.ps1 -SkipBuild  # upload site\ as it is
```

| Piece | Setting |
|---|---|
| S3 bucket `serverless-patch-site-<account>` (ap-southeast-5) | Private: all public access blocked, ACLs disabled |
| CloudFront Origin Access Control `serverless-patch-site-oac` | Only CloudFront can read the bucket (SigV4) |
| CloudFront distribution (comment `serverless-patch project website`) | HTTPS only, AWS managed caching and security-headers policies, `index.html` as root |
| Bucket policy | `s3:GetObject` for this distribution's ARN only |

The Evaluation view starts on `$SiteFrom` in `config.ps1` (1 Nov 2026, the start of the evaluation; Malaysia
time) and has no end date, because `$SiteTo` is empty. Set `$SiteTo` (or run
`.\deploy-site.ps1 -From 2026-11-01 -To 2026-11-13`) only to freeze it to a fixed period. The evidence
fallback covers the same days.

The URL (`https://<id>.cloudfront.net/`) is printed at the end and saved to `evidence\deploy-site.json`.
The first deployment takes 5 to 15 minutes to reach the edge locations. Files are uploaded with an
explicit Content-Type, `build_site_data.py` and dot folders (such as `.hallmark/`) are not uploaded, and the cache is
cleared on every run.

#### Live updates

Step 8 of `deploy-site.ps1` sets up the Live view; nothing changes in the state machine or the patch Lambdas.

```
serverless-patch-cycle starts / finishes
   -> EventBridge rule serverless-patch-site-publish (Step Functions Execution Status Change)
   -> Lambda serverless-patch-site-publisher
        reads the host and cycle records from /aws/lambda/serverless-patch-metrics (Logs Insights)
        renders the Patch Summary panels with summary_widget.py (light and dark)
        reads Step Functions / Lambda / SNS counts (GetMetricData) for the Orchestration widgets
        asks Step Functions which executions are running
        reads each host's update list from the patch Lambdas' log groups
        writes data/live.json, data/evaluation.json and data/updates.json, clears them in CloudFront
   -> open pages re-check data/live.json every 60 s

every day at 00:05 MYT
   -> EventBridge rule serverless-patch-site-publish-daily -> the same Lambda,
      so "Last 2 weeks" keeps moving when no cycle runs
```

- For a patch cycle that has just succeeded, the publisher waits up to 90 s for its metrics record to
  become searchable, so a finished cycle is never published as missing.
- Role `serverless-patch-site-publisher-role` may only query the metrics log group, read metric data,
  list and describe executions of `serverless-patch-cycle`, write `data/live.json` and
  `data/evaluation.json` and clear the cache of this distribution. No host access, no secrets, no VPC.
- The files hold only the fields the dashboard shows: no account ID, ARNs, instance IDs or IP addresses
  (any in a failure reason are masked). The header's link to the Step Functions console is left out,
  as it would show the account ID and needs a console sign-in.
- Progress inside a cycle (which host, which step) is not published; that stays on the CloudWatch dashboard.
- To republish by hand: `aws lambda invoke --function-name serverless-patch-site-publisher --region ap-southeast-5 out.json`.

#### Custom domain (DNS at Cloudflare)

Use a subdomain such as `patch.example.com`, or set `$SiteDomain` in `config.ps1` so every run keeps it.
CloudFront needs an ACM certificate in us-east-1; the script requests it and attaches the domain.

1. `.\deploy-site.ps1 -Domain patch.example.com` requests the certificate and prints a validation CNAME
   (`_xxxx.patch.example.com` -> `_yyyy.acm-validations.aws`).
2. In Cloudflare, DNS > Records > Add record: type CNAME, that name and target, proxy status **DNS only**.
   Keep this record; ACM uses it to renew the certificate every year.
3. A few minutes later, run `.\deploy-site.ps1 -Domain patch.example.com` again. With the certificate
   issued it adds the domain to the distribution (TLS 1.2 or later) and prints the second record.
4. In Cloudflare add CNAME `patch` -> `<id>.cloudfront.net`, proxy status **DNS only**.

Keep both records on **DNS only** (grey cloud). CloudFront already serves HTTPS and caches the site; with
the Cloudflare proxy on, pages would be cached twice and the script's cache clearing would not reach
Cloudflare's copy.

The CloudWatch dashboard stays the live operational view and is not made public: a public CloudWatch
dashboard link would give anyone with the link read access to every metric and EC2 instance name and tag
in the account. To show it to a supervisor, share it with named email addresses instead.

## Safety Defaults

- A run without `"mode": "patch"` is **scan only**. Patch scope is **security updates only** on RHEL.
- Only running instances tagged `PatchTarget=true` and `project=serverless-patch` are touched.
- The weekly schedule `serverless-patch-weekly` (Sunday 02:00 MYT) is created **disabled**.
- Microsoft Defender updates are excluded from the Windows counts by design (they update themselves).
- No secrets are stored in this repository: credentials live in AWS Secrets Manager.
- Lab limitations: WinRM certificate verification is skipped (self-signed certificate); SSH host keys are not pinned.

## Monitoring

- Every patch cycle sends one SNS email (patched, partial, failed or error) and writes records to
  `/aws/lambda/serverless-patch-metrics`, which feed the `ServerlessPatch` metrics and the dashboard.
- **Success** counts only updates confirmed fixed by the post-install rescan, not installer result codes.
- **Cost** is a list-price estimate from each execution's history (state transitions, Lambda invocations
  and duration), before the free tier.
