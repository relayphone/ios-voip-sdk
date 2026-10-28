#!/usr/bin/env python3
"""Summarize Actions job annotations without exposing remote text."""

import argparse
import json
import re
import subprocess
import sys


REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
RUN = re.compile(r"[1-9][0-9]{0,19}\Z")
BILLING_REJECTION = re.compile(
    r"\Athe job was not started because your [a-z]+ is locked due to a billing issue\.\Z",
    re.IGNORECASE,
)


def read_pages(endpoint):
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", endpoint],
                            capture_output=True, text=True, timeout=30, check=True)
    value = json.loads(result.stdout)
    if not isinstance(value, list):
        raise ValueError("Invalid response")
    return value


def billing_rejection(annotation):
    if not isinstance(annotation, dict) or not isinstance(annotation.get("message"), str):
        return False
    return BILLING_REJECTION.fullmatch(annotation["message"]) is not None


def summarize(repo, run, fetch=read_pages):
    if (not REPO.fullmatch(repo) or any(part in {".", ".."} for part in repo.split("/"))
            or not RUN.fullmatch(run)):
        raise ValueError("Invalid run identifier")
    pages = fetch(f"repos/{repo}/actions/runs/{run}/jobs?per_page=100")
    if not pages:
        raise ValueError("Invalid jobs response")
    jobs = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("jobs"), list):
            raise ValueError("Invalid jobs response")
        jobs.extend(page["jobs"])
    if len(jobs) > 500 or any(not isinstance(job, dict) for job in jobs):
        raise ValueError("Invalid jobs response")
    summary = {"jobsObserved": len(jobs), "failedJobs": 0, "billingBlocked": 0, "otherFailures": 0,
               "annotationsUnavailable": 0, "incompleteJobs": 0}
    for job in jobs:
        if job.get("status") != "completed":
            summary["incompleteJobs"] += 1
        if not isinstance(job.get("conclusion"), str) or job["conclusion"] not in {"failure", "timed_out", "action_required"}:
            continue
        summary["failedJobs"] += 1
        job_id = job.get("id")
        if type(job_id) is not int or job_id <= 0:
            summary["annotationsUnavailable"] += 1
            continue
        try:
            pages = fetch(f"repos/{repo}/check-runs/{job_id}/annotations?per_page=100")
            if (not pages or any(not isinstance(page, list) for page in pages)
                    or any(not isinstance(item, dict) or not isinstance(item.get("message"), str)
                           for page in pages for item in page)):
                raise ValueError("Invalid annotations response")
            found = any(billing_rejection(item) for page in pages for item in page)
        except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
            summary["annotationsUnavailable"] += 1
            continue
        summary["billingBlocked" if found else "otherFailures"] += 1
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarize failed GitHub Actions jobs from their annotations")
    parser.add_argument("run", help="Actions run ID")
    parser.add_argument("--repo", required=True, help="GitHub repository in owner/name form")
    args = parser.parse_args(argv)
    try:
        result = summarize(args.repo, args.run)
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
        print("Could not read GitHub Actions checks.", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 2 if result["annotationsUnavailable"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
