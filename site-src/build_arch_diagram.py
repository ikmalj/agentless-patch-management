"""Writes the architecture diagram (an inline SVG <figure>) into site/index.html, in "How a patch cycle runs".

Edit the boxes and arrows below, then run:  python site-src/build_arch_diagram.py
The SVG takes its colours from the page's theme tokens, so it follows Light / Dark.
"""
import html
import os
P = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'site', 'index.html')

out = []
def box(x, y, w, h, title, sub, accent, mono=True):
    # accent: a colour class from style.css (.c-trigger, .c-fn, ...), drawn as a square in the top right corner
    out.append(f'<g class="ab c-{accent}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8"/>'
               f'<rect class="ab-accent" x="{x + w - 15}" y="{y + 7}" width="7" height="7" rx="1.5"/>'
               f'<text class="{"ab-t mono" if mono else "ab-t"}" x="{x + 16}" y="{y + 23}">{html.escape(title)}</text>')
    for i, line in enumerate(sub):
        out.append(f'<text class="ab-s" x="{x + 16}" y="{y + 41 + i * 15}">{html.escape(line)}</text>')
    out.append('</g>')

def edge(points, label=None, at=None, dashed=False, anchor='middle'):
    pts = ' '.join(f'{x},{y}' for x, y in points)
    out.append(f'<polyline class="ae{" ae-d" if dashed else ""}" points="{pts}" marker-end="url(#arr)"/>')
    if label:
        lx, ly = at
        out.append(f'<text class="ae-l" x="{lx}" y="{ly}" text-anchor="{anchor}">{html.escape(label)}</text>')

# ---- band 1: patching ----
out.append('<text class="ab-band" x="20" y="22">Patching</text>')
out.append('<rect class="vpc" x="440" y="34" width="660" height="262" rx="12"/>')
out.append('<text class="vpc-l" x="456" y="54">VPC, private subnet, ap-southeast-5</text>')
box(14, 128, 190, 64, 'EventBridge Scheduler', ['weekly or one-time trigger'], 'trigger')
box(232, 114, 180, 92, 'Step Functions', ['serverless-patch-cycle', 'parallel branch per host', 'precheck, patch, rescan'], 'orch')
box(470, 70, 228, 58, 'λ serverless-patch-rhel', ['SSH client'], 'fn')
box(470, 152, 228, 52, 'Secrets Manager', ['VPC endpoint: SSH key, WinRM'], 'secrets')
box(470, 228, 228, 58, 'λ serverless-patch-windows', ['WinRM client'], 'fn')
box(912, 62, 178, 56, 'rhel-01', ['RHEL 9, nginx, no agent'], 'rhel')
box(912, 136, 178, 56, 'rhel-02', ['RHEL 9, MySQL, no agent'], 'rhel')
box(912, 222, 178, 70, 'win-01', ['Windows Server 2022', 'IIS, no agent'], 'win')
edge([(204, 160), (228, 160)])
edge([(412, 140), (440, 140), (440, 99), (466, 99)])
edge([(412, 180), (440, 180), (440, 257), (466, 257)])
edge([(584, 152), (584, 132)], dashed=True)
edge([(584, 204), (584, 224)], dashed=True)
edge([(698, 90), (908, 90)], 'SSH 22: dnf upgrade --security', (803, 82))
edge([(698, 108), (803, 108), (803, 164), (908, 164)])
edge([(698, 257), (908, 257)], 'WinRM 5986: Windows Update API', (803, 249))

# ---- band 2: monitoring and website ----
out.append('<text class="ab-band" x="20" y="336">Monitoring and website</text>')
box(20, 380, 170, 58, 'Amazon SNS', ['result email per cycle'], 'obs')
box(232, 380, 176, 58, 'λ …-metrics', ['host + cycle records'], 'fn')
box(452, 370, 196, 78, 'CloudWatch', ['Logs and Metrics (EMF)', 'PatchManagement-Dashboard', '(19 widgets)'], 'obs')
box(690, 380, 170, 58, 'λ …-site-publisher', ['dashboard data'], 'fn')
box(910, 380, 190, 58, 'EventBridge rule', ['cycle started / finished'], 'trigger')
box(20, 510, 170, 58, 'GitHub', ['code and pull requests'], 'ink')
box(232, 510, 176, 58, 'deploy-site.ps1', ['PowerShell + AWS CLI'], 'muted')
box(690, 510, 180, 58, 'S3 (private)', ['site files, data/*.json'], 's3')
box(910, 510, 190, 58, 'CloudFront + ACM', ['HTTPS, cache, OAC'], 'cdn')
box(910, 612, 190, 52, 'fyp.ikmaljohari.my', ['Cloudflare DNS to visitors'], 'accent')
edge([(262, 206), (262, 356), (105, 356), (105, 376)], 'publish', (180, 350))
edge([(320, 206), (320, 376)])
edge([(392, 206), (392, 318), (1005, 318), (1005, 376)], 'execution status events', (700, 312))
edge([(408, 409), (448, 409)], 'EMF', (428, 401))
edge([(648, 409), (686, 409)], 'reads', (667, 401))
edge([(910, 409), (864, 409)], 'runs', (887, 401))
edge([(775, 438), (775, 506)], 'writes', (785, 476), anchor='start')
edge([(190, 539), (228, 539)])
edge([(408, 539), (686, 539)], 'uploads the site', (547, 531))
edge([(870, 539), (906, 539)], 'OAC', (888, 531))
edge([(1005, 568), (1005, 608)])

svg = ('<svg class="arch-svg" viewBox="0 0 1120 680" role="img" aria-labelledby="arch-title arch-desc">'
       '<title id="arch-title">Architecture of the agentless patch management system</title>'
       '<desc id="arch-desc">EventBridge Scheduler starts the Step Functions state machine serverless-patch-cycle, which runs '
       'one parallel branch per host. Inside the VPC, the Lambda functions serverless-patch-rhel and serverless-patch-windows '
       'take credentials from Secrets Manager through a VPC endpoint and patch rhel-01 and rhel-02 over SSH port 22 and win-01 '
       'over WinRM port 5986; no agent is installed on any host. Step Functions publishes the result to Amazon SNS and calls '
       'serverless-patch-metrics, which writes host and cycle records to CloudWatch, where the PatchManagement-Dashboard reads them. '
       'Its execution status events trigger an EventBridge rule, which runs serverless-patch-site-publisher; the publisher reads '
       'CloudWatch and writes the dashboard data to a private S3 bucket. GitHub holds the code, and deploy-site.ps1 uploads the '
       'site to S3. CloudFront with an ACM certificate serves the bucket over HTTPS through Origin Access Control to visitors '
       'of fyp.ikmaljohari.my, whose DNS is at Cloudflare.</desc>'
       '<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
       '<path class="arr-h" d="M0 0L10 5L0 10z"/></marker></defs>'
       + ''.join(out) + '</svg>')

figure = f'''      <figure class="arch" id="architecture">
        <div class="arch-scroll" tabindex="0" aria-label="Architecture diagram (scrolls sideways on small screens)">
          {svg}
        </div>
        <figcaption><strong>Architecture.</strong> Top: one patch cycle, from the schedule to each host, with no agent installed. Bottom: how the results reach CloudWatch, the email and this website; the code lives in GitHub and the data comes from CloudWatch.</figcaption>
      </figure>
'''
s = open(P, encoding='utf-8').read()
anchor = '      <ol class="steps">'
import re
s = re.sub(r'      <figure class="arch" id="architecture">.*?</figure>\n', '', s, flags=re.S)
assert anchor in s and 'id="architecture"' not in s
s = s.replace(anchor, figure + anchor, 1)
open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('inserted', len(svg), 'bytes of SVG')
