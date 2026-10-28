"""Skip a nightly only when an earlier successful main run covered its native jobs."""
import json
import os
import sys
import urllib.parse
import urllib.request

REQUIRED = {
    'sdk-m0.yml': {'apple-host-controls', 'sdk-example', 'sdk-core', 'sdk-fixtures',
                   'device-release', 'legacy-audio-lifecycle', 'swift-livekit-native',
                   'Pinned Expo LiveKit selected Release device build',
                   'SDK audio routes on iPhone Duo', *(f'SDK journey ({g})' for g in
                       ('m1', 'contracts', 'push-entry', 'system'))},
    'runtime-m4.yml': {'Runtime native and Inspector'},
    'simulator-discovery.yml': {'probe (26.6)', 'probe (26.3)'},
}


def covered(workflow, jobs):
    if jobs['total_count'] != len(jobs['jobs']):
        return False
    required = REQUIRED[workflow]
    selected = [job for job in jobs['jobs'] if job['name'] in required]
    return (len(selected) == len(required)
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
