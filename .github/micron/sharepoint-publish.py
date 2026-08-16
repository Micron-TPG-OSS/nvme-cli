#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This file is part of nvme.
# Copyright (c) 2026 Micron Technology, Inc.
#
# Record one Windows release in the "NVMe CLI Windows Builds" SharePoint list on
# the TACT site, so the team's home page shows what was built and where to get
# it. Called by the sharepoint job in .github/workflows/micron-release.yml after
# the GitHub release is published. The one-time Entra and site setup is
# documented outside this public repository, since it names the tenant and site.
#
# Why a list rather than editing the page?
#   The row is data, so it can be re-written idempotently: the upsert is keyed on
#   the release tag, and a forced rebuild of an existing tag updates that tag's
#   row instead of appending a duplicate. Editing the modern page's canvas
#   instead would mean read-modify-write on hand-authored HTML, which loses
#   whatever a human changed in between.
#
# Why no Python dependencies?
#   The workflow runs this on a bare ubuntu-latest with the system Python. Every
#   call here is plain urllib against Graph, so there is no pip step to break and
#   nothing to pin.

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GRAPH = "https://graph.microsoft.com/v1.0"

# GitHub's OIDC provider issues a token for whatever audience is asked for; this
# is the value Entra expects for a workload identity federation credential.
DEFAULT_AUDIENCE = "api://AzureADTokenExchange"

# The list schema. Kept as data because it is used three ways: to create the
# list, to add any column a previously created list is missing, and to know
# which fields are hyperlinks (those take a {Url, Description} object rather
# than a bare string).
#
# "name" is the internal field name used when writing items. Graph sets the
# display name to match when a column is created this way, so the two agree.
COLUMNS = [
    {"name": "Tag", "text": {},
     "description": "Upstream release tag the binaries were built from"},
    {"name": "ReleaseDate",
     "dateTime": {"displayAs": "standard", "format": "dateOnly"},
     "description": "When the release was published upstream"},
    {"name": "Prerelease", "boolean": {},
     "description": "Mirrors upstream's prerelease flag"},
    {"name": "Win64Zip", "hyperlinkOrPicture": {"isPicture": False},
     "description": "Download: x64 nvme.exe"},
    {"name": "Arm64Zip", "hyperlinkOrPicture": {"isPicture": False},
     "description": "Download: ARM64 nvme.exe"},
    {"name": "ForkRelease", "hyperlinkOrPicture": {"isPicture": False},
     "description": "The Micron-TPG-OSS release holding these assets"},
    {"name": "UpstreamRelease", "hyperlinkOrPicture": {"isPicture": False},
     "description": "The linux-nvme/nvme-cli release this mirrors"},
    {"name": "BuildRun", "hyperlinkOrPicture": {"isPicture": False},
     "description": "Actions run that produced the binaries"},
    {"name": "Win64Sha256", "text": {},
     "description": "SHA-256 of the x64 zip"},
    {"name": "Arm64Sha256", "text": {},
     "description": "SHA-256 of the ARM64 zip"},
    {"name": "NvmeVersion", "text": {},
     "description": "What 'nvme version' reports for the shipped binary"},
]

HYPERLINK_FIELDS = {
    c["name"] for c in COLUMNS if "hyperlinkOrPicture" in c
}


class GraphError(Exception):
    def __init__(self, status, body, method, url):
        self.status = status
        self.body = body
        super().__init__("%s %s -> HTTP %s: %s" % (method, url, status, body))


def request(method, url, token=None, json_body=None, form_body=None,
            retries=4):
    """One HTTP call, with a retry for the failures that are worth retrying.

    429 and 5xx are transient (Graph throttles by tenant, and SharePoint
    occasionally returns 503 mid-write); anything else is a real answer and is
    raised immediately so the workflow fails with the actual message.
    """
    data = None
    headers = {"Accept": "application/json"}

    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif form_body is not None:
        data = urllib.parse.urlencode(form_body).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    if token:
        headers["Authorization"] = "Bearer " + token

    attempt = 0
    while True:
        attempt += 1
        req = urllib.request.Request(url, data=data, headers=headers,
                                     method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            transient = exc.code == 429 or 500 <= exc.code < 600
            if not transient or attempt > retries:
                raise GraphError(exc.code, body, method, url)
            delay = int(exc.headers.get("Retry-After") or 0) or 2 ** attempt
            print("  HTTP %s, retrying in %ss (attempt %s/%s)"
                  % (exc.code, delay, attempt, retries), flush=True)
            time.sleep(delay)
        except urllib.error.URLError as exc:
            if attempt > retries:
                raise
            print("  %s, retrying in %ss" % (exc, 2 ** attempt), flush=True)
            time.sleep(2 ** attempt)


# --------------------------------------------------------------------------
# Authentication
# --------------------------------------------------------------------------

def access_token(tenant_id, client_id, audience):
    """An app-only Graph token, via GitHub's OIDC token as the client assertion.

    Federated credentials mean no client secret lives in the repository: GitHub
    mints a short-lived JWT describing this workflow, and Entra trades it for a
    Graph token if the subject matches the credential. GRAPH_ACCESS_TOKEN short
    -circuits all of that, which is how this script is testable outside CI.
    """
    pre_issued = os.environ.get("GRAPH_ACCESS_TOKEN")
    if pre_issued:
        print("Using GRAPH_ACCESS_TOKEN from the environment.")
        return pre_issued

    req_url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")
    req_token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if not req_url or not req_token:
        sys.exit("error: no GRAPH_ACCESS_TOKEN and no Actions OIDC token "
                 "available.\n"
                 "       In a workflow this means the job is missing\n"
                 "           permissions:\n"
                 "             id-token: write")

    print("Requesting a GitHub OIDC token for %s" % audience)
    github_jwt = request(
        "GET",
        req_url + "&audience=" + urllib.parse.quote(audience),
        token=req_token,
    )["value"]

    print("Exchanging it for a Graph token in tenant %s" % tenant_id)
    token = request(
        "POST",
        "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % tenant_id,
        form_body={
            "client_id": client_id,
            "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials",
            "client_assertion_type":
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": github_jwt,
        },
    )
    return token["access_token"]


# --------------------------------------------------------------------------
# List and column bootstrap
# --------------------------------------------------------------------------

def find_list(token, site_id, list_name):
    """The list's id, or None. Matched client-side on purpose.

    $filter on displayName is not supported for lists, and a site has a handful
    of lists at most, so listing them and comparing is both simpler and less
    likely to break than a filter Graph might reject.
    """
    url = "%s/sites/%s/lists?$select=id,name,displayName&$top=200" % (
        GRAPH, site_id)
    while url:
        page = request("GET", url, token=token)
        for lst in page.get("value", []):
            if list_name in (lst.get("displayName"), lst.get("name")):
                return lst["id"]
        url = page.get("@odata.nextLink")
    return None


def create_list(token, site_id, list_name, description):
    print("Creating list %r" % list_name)
    body = {
        "displayName": list_name,
        "description": description,
        "list": {"template": "genericList"},
        "columns": COLUMNS,
    }
    try:
        return request("POST", "%s/sites/%s/lists" % (GRAPH, site_id),
                       token=token, json_body=body)["id"]
    except GraphError as exc:
        if exc.status in (401, 403):
            sys.exit(
                "error: not allowed to create a list on this site (HTTP %s).\n"
                "       %s\n"
                "       Creating a list needs the 'manage' role, while writing\n"
                "       rows only needs 'write'. Either raise the app's\n"
                "       Sites.Selected role, or create the list by hand with\n"
                "       the columns in COLUMNS above -- their names must match\n"
                "       exactly, including case."
                % (exc.status, exc.body))
        raise


def ensure_columns(token, site_id, list_id, dry_run=False):
    """Add any column this script writes that the list does not have yet.

    Without this, adding a field below would mean hand-editing the list, and a
    row written with an unknown field is rejected outright rather than partially
    saved. Existing columns are left exactly as they are.
    """
    url = "%s/sites/%s/lists/%s/columns?$select=name&$top=200" % (
        GRAPH, site_id, list_id)
    have = set()
    while url:
        page = request("GET", url, token=token)
        have.update(c["name"] for c in page.get("value", []))
        url = page.get("@odata.nextLink")

    for column in COLUMNS:
        if column["name"] in have:
            continue
        if dry_run:
            print("--dry-run: would add missing column %r" % column["name"])
            continue
        print("Adding missing column %r" % column["name"])
        request("POST", "%s/sites/%s/lists/%s/columns"
                % (GRAPH, site_id, list_id), token=token, json_body=column)


# --------------------------------------------------------------------------
# The row itself
# --------------------------------------------------------------------------

def find_item_by_tag(token, site_id, list_id, tag):
    """The existing row for this tag, or None.

    Also matched client-side: $filter on fields/Tag needs the column indexed and
    a HonorNonIndexedQueries header whose own documentation says it "may fail
    randomly". The list holds one row per release, so reading it whole is cheap
    and always correct.
    """
    url = ("%s/sites/%s/lists/%s/items?$expand=fields&$top=200"
           % (GRAPH, site_id, list_id))
    while url:
        page = request("GET", url, token=token)
        for item in page.get("value", []):
            if (item.get("fields") or {}).get("Tag") == tag:
                return item
        url = page.get("@odata.nextLink")
    return None


def link(url, text):
    return {"Url": url, "Description": text}


def build_fields(args):
    fields = {
        "Title": args.version,
        "Tag": args.tag,
        "Prerelease": args.prerelease,
    }

    if args.published_at:
        fields["ReleaseDate"] = args.published_at
    if args.nvme_version:
        fields["NvmeVersion"] = args.nvme_version
    if args.win64_sha256:
        fields["Win64Sha256"] = args.win64_sha256
    if args.arm64_sha256:
        fields["Arm64Sha256"] = args.arm64_sha256

    if args.win64_url:
        fields["Win64Zip"] = link(args.win64_url,
                                  "nvme-cli-%s-win64.zip" % args.version)
    if args.arm64_url:
        fields["Arm64Zip"] = link(args.arm64_url,
                                  "nvme-cli-%s-arm64.zip" % args.version)
    if args.fork_release_url:
        fields["ForkRelease"] = link(args.fork_release_url,
                                     "Micron release %s" % args.tag)
    if args.upstream_release_url:
        fields["UpstreamRelease"] = link(args.upstream_release_url,
                                         "Upstream %s" % args.tag)
    if args.run_url:
        fields["BuildRun"] = link(args.run_url, "Build log")

    return fields


def upsert(token, site_id, list_id, args, dry_run):
    fields = build_fields(args)
    existing = find_item_by_tag(token, site_id, list_id, args.tag)

    print("Fields to write:")
    print(json.dumps(fields, indent=2, sort_keys=True))

    if dry_run:
        print("--dry-run: not writing. Would %s."
              % ("update item %s" % existing["id"] if existing
                 else "create a new item"))
        return None

    if existing:
        item_id = existing["id"]
        print("Updating existing row for %s (item %s)" % (args.tag, item_id))
        request("PATCH", "%s/sites/%s/lists/%s/items/%s/fields"
                % (GRAPH, site_id, list_id, item_id),
                token=token, json_body=fields)
        return item_id

    print("Creating a row for %s" % args.tag)
    item = request("POST", "%s/sites/%s/lists/%s/items"
                   % (GRAPH, site_id, list_id),
                   token=token, json_body={"fields": fields})
    return item["id"]


def boolish(value):
    return str(value).strip().lower() in ("1", "true", "yes", "y")


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Upsert a release row in the TACT SharePoint list.")

    p.add_argument("--site-id", default=os.environ.get("SHAREPOINT_SITE_ID"),
                   help="Graph site id (host,siteCollectionId,siteId)")
    p.add_argument("--tenant-id",
                   default=os.environ.get("SHAREPOINT_TENANT_ID"))
    p.add_argument("--client-id",
                   default=os.environ.get("SHAREPOINT_CLIENT_ID"))
    p.add_argument("--audience", default=DEFAULT_AUDIENCE)
    p.add_argument("--list-name",
                   default=os.environ.get("SHAREPOINT_LIST_NAME")
                   or "NVMe CLI Windows Builds")
    p.add_argument("--list-description",
                   default="Windows x64/ARM64 nvme.exe builds published by "
                           "Micron-TPG-OSS/nvme-cli for each upstream "
                           "linux-nvme/nvme-cli release. Rows are written by "
                           "the Micron - Windows Release workflow.")
    p.add_argument("--create-list", action="store_true",
                   help="create the list if it does not exist yet")

    p.add_argument("--tag", required=True, help="e.g. v3.0-rc1")
    p.add_argument("--version", required=True, help="e.g. 3.0-rc1")
    p.add_argument("--prerelease", type=boolish, default=False)
    p.add_argument("--published-at", default="",
                   help="ISO 8601 upstream publish time")
    p.add_argument("--nvme-version", default="",
                   help="output of 'nvme version' for the shipped binary")
    p.add_argument("--win64-url", default="")
    p.add_argument("--arm64-url", default="")
    p.add_argument("--win64-sha256", default="")
    p.add_argument("--arm64-sha256", default="")
    p.add_argument("--fork-release-url", default="")
    p.add_argument("--upstream-release-url", default="")
    p.add_argument("--run-url", default="")
    p.add_argument("--dry-run", action="store_true",
                   help="resolve everything and print the row, but write "
                        "nothing")

    args = p.parse_args(argv)

    missing = [name for name in ("site_id", "tenant_id", "client_id")
               if not getattr(args, name)]
    # tenant/client are only needed to mint a token, so a caller that brought
    # its own does not have to supply them.
    if os.environ.get("GRAPH_ACCESS_TOKEN"):
        missing = [name for name in missing if name == "site_id"]
    if missing:
        p.error("missing required value(s): %s"
                % ", ".join("--" + m.replace("_", "-") for m in missing))

    return args


def main(argv):
    args = parse_args(argv)

    token = access_token(args.tenant_id, args.client_id, args.audience)

    list_id = find_list(token, args.site_id, args.list_name)
    if not list_id:
        if not args.create_list:
            sys.exit("error: list %r not found on the site and --create-list "
                     "was not given" % args.list_name)
        list_id = create_list(token, args.site_id, args.list_name,
                              args.list_description)
    print("List %r is %s" % (args.list_name, list_id))

    ensure_columns(token, args.site_id, list_id, args.dry_run)
    item_id = upsert(token, args.site_id, list_id, args, args.dry_run)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and item_id:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("### SharePoint\n\nWrote %s to **%s** (item %s).\n"
                     % (args.tag, args.list_name, item_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except GraphError as exc:
        sys.exit("error: %s" % exc)
