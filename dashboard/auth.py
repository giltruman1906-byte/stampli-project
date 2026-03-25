"""
auth.py — Role-based access control
Roles:
  admin           → full access, all regions
  analyst         → full access, all regions (read-only)
  regional_manager→ own region only (CR-1 enforcement)
  viewer          → revenue + customer tabs only, no support detail
"""

USERS = {
    "admin":    {"password": "admin123",   "role": "admin",            "region": "ALL",  "name": "Admin User"},
    "analyst":  {"password": "analyst123", "role": "analyst",          "region": "ALL",  "name": "Sarah Chen (Finance)"},
    "mgr_na":   {"password": "na123",      "role": "regional_manager", "region": "NA",   "name": "NA Manager"},
    "mgr_emea": {"password": "emea123",    "role": "regional_manager", "region": "EMEA", "name": "EMEA Manager"},
    "mgr_apac": {"password": "apac123",    "role": "regional_manager", "region": "APAC", "name": "APAC Manager"},
    "viewer":   {"password": "viewer123",  "role": "viewer",           "region": "ALL",  "name": "Viewer"},
}

# What each role can see
ROLE_PERMISSIONS = {
    "admin":            {"tabs": ["revenue", "customers", "support", "product", "raw"], "can_export": True},
    "analyst":          {"tabs": ["revenue", "customers", "support", "product"],       "can_export": True},
    "regional_manager": {"tabs": ["revenue", "customers", "support", "product"],       "can_export": False},
    "viewer":           {"tabs": ["revenue", "customers"],                             "can_export": False},
}

ROLE_LABELS = {
    "admin":            "👑 Admin",
    "analyst":          "🔍 Analyst",
    "regional_manager": "🌍 Regional Manager",
    "viewer":           "👁 Viewer",
}


def authenticate(username: str, password: str):
    user = USERS.get(username)
    if user and user["password"] == password:
        return user
    return None


def can_see_tab(role: str, tab: str) -> bool:
    return tab in ROLE_PERMISSIONS.get(role, {}).get("tabs", [])


def can_export(role: str) -> bool:
    return ROLE_PERMISSIONS.get(role, {}).get("can_export", False)
