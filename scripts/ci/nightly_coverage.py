"""Skip a nightly only when an earlier successful main run covered its native jobs."""
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

REQUIRED = {
    'runtime-m4.yml': {'Runtime native and Inspector'},
}


def sdk_required(path):
    """Resolve native jobs from the acceptance gate."""
    text = Path(path).read_text(encoding='utf-8').split('\njobs:\n', 1)[1]
    blocks = re.split(r'(?m)^  ([a-z][a-z0-9-]*):\s*$', text)
    jobs = dict(zip(blocks[1::2], blocks[2::2]))
    gate = jobs['plain-simulator']
    dependencies = re.search(r'(?m)^    needs: \[([^\]]+)\]\s*$', gate)
    if not dependencies:
        raise ValueError('Unsupported acceptance dependencies')
    required = set()
    for job in (name.strip() for name in dependencies.group(1).split(',')):
        block = jobs[job]
        runner = re.search(r'(?m)^    runs-on: ([^\n]+)$', block)
        if not runner:
            if re.search(r'(?m)^    uses:', block):
                continue
            raise ValueError('Missing runner for ' + job)
        if runner.group(1) not in ('xcode-27', 'macos-26'):
            if runner.group(1) == 'ubuntu-latest':
                continue
            raise ValueError('Unsupported runner for ' + job)
        name = re.search(r'(?m)^    name: (.+)$', block)
        display = name.group(1) if name else job
        if '${{' in display or re.search(r'(?m)^    strategy:', block):
            raise ValueError('Unsupported job name or matrix for ' + job)
        if display in required:
            raise ValueError('Duplicate native job name')
        required.add(display)
    if not required:
        raise ValueError('Empty native acceptance dependencies')
    return required


try:
    REQUIRED['sdk-m0.yml'] = sdk_required(Path(__file__).resolve().parents[2] / '.github/workflows/sdk-m0.yml')
except (OSError, ValueError, KeyError, IndexError):
    # A workflow layout we cannot resolve must run, never skip, the nightly.
    REQUIRED['sdk-m0.yml'] = set()


def covered(workflow, jobs):
    if jobs['total_count'] != len(jobs['jobs']):
        return False
    required = REQUIRED[workflow]
    selected = [job for job in jobs['jobs'] if job['name'] in required]
    return (bool(required) and len(selected) == len(required)
            and {job['name'] for job in selected} == required
            and all(job['conclusion'] == 'success' for job in selected))


def request(path, token):
    req = urllib.request.Request('https://api.github.com/' + path,
        headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


def has_coverage(workflow, repo, sha, token, fetch=request):
    query = urllib.parse.urlencode({'branch': 'main', 'head_sha': sha,
                                    'status': 'success', 'per_page': 100})
    prefix = f'repos/{repo}/actions'
    runs = fetch(f'{prefix}/workflows/{workflow}/runs?{query}', token)['workflow_runs']
    for run in runs[:10]:
        if (run['head_sha'] != sha or run['head_branch'] != 'main'
                or run['event'] not in ('push', 'schedule', 'workflow_dispatch')
                or run['status'] != 'completed' or run['conclusion'] != 'success'):
            continue
        jobs = fetch(f"{prefix}/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100", token)
        if covered(workflow, jobs):
            return True
    return False


def main():
    skip = False
    if os.environ['GITHUB_EVENT_NAME'] == 'schedule':
        try:
            skip = has_coverage(sys.argv[1], os.environ['GITHUB_REPOSITORY'],
                                os.environ['GITHUB_SHA'], os.environ['GH_TOKEN'])
        except (OSError, ValueError, KeyError, TypeError):
            print('Could not verify prior coverage; running the nightly.', file=sys.stderr)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        print(f"skip={'true' if skip else 'false'}", file=output)


if __name__ == '__main__':
    main()
