"""Business line and tenant identity.

The allow-list mirrors config/tenancy.yaml. scripts/config-check.sh fails
if the two diverge. An id that is not on the list becomes the constant
"rejected". The raw string is never returned as a label value.
"""

from __future__ import annotations

import os

TOC_TENANT = "consumer"
TOB_TENANTS = ("acme", "northwind")
BUSINESS_LINES = ("toc", "tob")
ROLES = ("api", "checkout", "admin", "billing")

_ORG = {
    ("toc", "consumer"): "toc",
    ("tob", "acme"): "tob-acme",
    ("tob", "northwind"): "tob-northwind",
}


def resolve(business_line: str | None, tenant: str | None, role: str | None) -> dict[str, str]:
    """Return bounded business_line, tenant, org_id, and role."""
    line = (business_line or "toc").strip().lower()
    if line not in BUSINESS_LINES:
        line = "rejected"
    raw_tenant = (tenant or "").strip().lower()
    if line == "toc":
        # ToC has no per-customer tenant. Ignore anything the caller passed.
        tenant_label = TOC_TENANT
    elif line == "tob" and raw_tenant in TOB_TENANTS:
        tenant_label = raw_tenant
    else:
        tenant_label = "rejected"
    if line == "rejected":
        tenant_label = "rejected"
    chosen_role = (role or "").strip().lower()
    if chosen_role not in ROLES:
        chosen_role = "api" if line == "toc" else "admin"
    org_id = _ORG.get((line, tenant_label), "rejected")
    return {
        "business_line": line,
        "tenant": tenant_label,
        "org_id": org_id,
        "role": chosen_role,
    }


def resolve_from_env() -> dict[str, str]:
    return resolve(
        os.environ.get("BUSINESS_LINE"),
        os.environ.get("TENANT_ID"),
        os.environ.get("SERVICE_ROLE"),
    )
