#!/usr/bin/env python3
"""
Validation script for Feather / AltStore source repository JSON.
Strictly validates schema, required fields, data types, and URLs.
"""

import sys
import os
import json
import re
from urllib.parse import urlparse
from datetime import datetime

REQUIRED_ROOT_FIELDS = {
    "name": str,
    "identifier": str,
    "iconURL": str,
    "website": str,
    "apps": list,
}

REQUIRED_APP_FIELDS = {
    "name": str,
    "bundleIdentifier": str,
    "developerName": str,
    "subtitle": str,
    "localizedDescription": str,
    "iconURL": str,
    "tintColor": str,
    "version": str,
    "versionDate": str,
    "versionDescription": str,
    "downloadURL": str,
    "size": int,
    "versions": list,
}

REQUIRED_VERSION_FIELDS = {
    "version": str,
    "date": str,
    "size": int,
    "downloadURL": str,
    "localizedDescription": str,
}

REVERSE_DNS_REGEX = re.compile(r"^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)+$")
SEMVER_REGEX = re.compile(r"^\d+\.\d+(\.\d+)?(-[a-zA-Z0-9.]+)?$")
HEX_COLOR_REGEX = re.compile(r"^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$")


class ValidationError(Exception):
    pass


def validate_url(url: str, field_name: str, must_end_with: str = None) -> None:
    if not isinstance(url, str) or not url.strip():
        raise ValidationError(f"Field '{field_name}' must be a non-empty string URL.")
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValidationError(f"URL '{url}' in '{field_name}' must use http or https scheme.")
    if not parsed.netloc:
        raise ValidationError(f"URL '{url}' in '{field_name}' must have a valid hostname.")
    if must_end_with and not parsed.path.endswith(must_end_with):
        raise ValidationError(
            f"URL '{url}' in '{field_name}' must end with '{must_end_with}'."
        )


def validate_date(date_str: str, field_name: str) -> None:
    if not isinstance(date_str, str) or not date_str.strip():
        raise ValidationError(f"Field '{field_name}' must be a valid date string.")
    
    # Accept ISO 8601 variations (e.g., 2026-09-08T00:00:00Z, 2026-09-08)
    iso_formats = [
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d",
    ]
    parsed = False
    for fmt in iso_formats:
        try:
            datetime.strptime(date_str, fmt)
            parsed = True
            break
        except ValueError:
            continue
    if not parsed:
        try:
            datetime.fromisoformat(date_str.replace("Z", "+00:00"))
            parsed = True
        except ValueError:
            pass
    if not parsed:
        raise ValidationError(
            f"Field '{field_name}' has invalid date format: '{date_str}'. Expected ISO 8601 (e.g. YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)."
        )


def validate_source_json(file_path: str, verbose: bool = True) -> bool:
    print(f"=== Validating Feather Source: {file_path} ===")
    
    if not os.path.isfile(file_path):
        print(f"[FAIL] File not found: {file_path}")
        return False
    
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[FAIL] JSON parsing error: {e}")
        return False

    errors = []

    # 1. Validate Root Object
    for field, expected_type in REQUIRED_ROOT_FIELDS.items():
        if field not in data:
            errors.append(f"Missing required root field: '{field}'")
        elif not isinstance(data[field], expected_type):
            errors.append(
                f"Root field '{field}' must be of type {expected_type.__name__}, got {type(data[field]).__name__}"
            )
        elif expected_type is str and not data[field].strip():
            errors.append(f"Root field '{field}' cannot be empty.")

    if "identifier" in data and isinstance(data["identifier"], str):
        if not REVERSE_DNS_REGEX.match(data["identifier"]):
            errors.append(
                f"Root identifier '{data['identifier']}' must follow reverse-DNS notation (e.g. com.example.source)."
            )

    if "iconURL" in data and isinstance(data["iconURL"], str):
        try:
            validate_url(data["iconURL"], "iconURL")
        except ValidationError as ve:
            errors.append(str(ve))

    if "website" in data and isinstance(data["website"], str):
        try:
            validate_url(data["website"], "website")
        except ValidationError as ve:
            errors.append(str(ve))

    # Optional root fields validation
    if "tintColor" in data and isinstance(data["tintColor"], str):
        if not HEX_COLOR_REGEX.match(data["tintColor"]):
            errors.append(f"Root tintColor '{data['tintColor']}' must be valid hex color.")

    # 2. Validate Apps Array
    apps = data.get("apps", [])
    if not isinstance(apps, list) or len(apps) == 0:
        errors.append("Root field 'apps' must be a non-empty list of application definitions.")
    else:
        for idx, app in enumerate(apps):
            prefix = f"apps[{idx}] ({app.get('name', 'unnamed')})"
            
            # Check required fields
            for field, expected_type in REQUIRED_APP_FIELDS.items():
                if field not in app:
                    errors.append(f"{prefix}: Missing required field '{field}'")
                elif not isinstance(app[field], expected_type):
                    errors.append(
                        f"{prefix}: Field '{field}' must be {expected_type.__name__}, got {type(app[field]).__name__}"
                    )
                elif expected_type is str and not app[field].strip():
                    errors.append(f"{prefix}: Field '{field}' cannot be empty.")
                elif expected_type is int and app[field] <= 0:
                    errors.append(f"{prefix}: Field '{field}' must be greater than 0.")

            # Specific field validations
            if "bundleIdentifier" in app and isinstance(app["bundleIdentifier"], str):
                if not REVERSE_DNS_REGEX.match(app["bundleIdentifier"]):
                    errors.append(f"{prefix}: Invalid bundleIdentifier format: '{app['bundleIdentifier']}'")

            if "version" in app and isinstance(app["version"], str):
                if not SEMVER_REGEX.match(app["version"]):
                    errors.append(f"{prefix}: Invalid semver version format: '{app['version']}'")

            if "versionDate" in app and isinstance(app["versionDate"], str):
                try:
                    validate_date(app["versionDate"], f"{prefix}.versionDate")
                except ValidationError as ve:
                    errors.append(str(ve))

            if "downloadURL" in app and isinstance(app["downloadURL"], str):
                try:
                    validate_url(app["downloadURL"], f"{prefix}.downloadURL", must_end_with=".ipa")
                except ValidationError as ve:
                    errors.append(str(ve))

            if "iconURL" in app and isinstance(app["iconURL"], str):
                try:
                    validate_url(app["iconURL"], f"{prefix}.iconURL")
                except ValidationError as ve:
                    errors.append(str(ve))

            if "tintColor" in app and isinstance(app["tintColor"], str):
                if not HEX_COLOR_REGEX.match(app["tintColor"]):
                    errors.append(f"{prefix}: Invalid tintColor '{app['tintColor']}'")

            # Screenshots validation
            if "screenshotURLs" in app:
                if not isinstance(app["screenshotURLs"], list):
                    errors.append(f"{prefix}: 'screenshotURLs' must be a list of URLs.")
                else:
                    for s_idx, s_url in enumerate(app["screenshotURLs"]):
                        try:
                            validate_url(s_url, f"{prefix}.screenshotURLs[{s_idx}]")
                        except ValidationError as ve:
                            errors.append(str(ve))

            if "screenshots" in app:
                if not isinstance(app["screenshots"], list):
                    errors.append(f"{prefix}: 'screenshots' must be a list of screenshot objects.")
                else:
                    for s_idx, s_obj in enumerate(app["screenshots"]):
                        if not isinstance(s_obj, dict) or "imageURL" not in s_obj:
                            errors.append(f"{prefix}.screenshots[{s_idx}] must contain 'imageURL'")
                        else:
                            try:
                                validate_url(s_obj["imageURL"], f"{prefix}.screenshots[{s_idx}].imageURL")
                            except ValidationError as ve:
                                errors.append(str(ve))

            # Permissions
            if "appPermissions" in app:
                perms = app["appPermissions"]
                if not isinstance(perms, dict):
                    errors.append(f"{prefix}: 'appPermissions' must be an object.")
                elif "privacy" in perms and not isinstance(perms["privacy"], dict):
                    errors.append(f"{prefix}: 'appPermissions.privacy' must be an object.")

            # Validate Versions Array
            versions = app.get("versions", [])
            if not isinstance(versions, list) or len(versions) == 0:
                errors.append(f"{prefix}: 'versions' must be a non-empty list of versions.")
            else:
                # Latest version check
                latest = versions[0]
                if "version" in latest and "version" in app:
                    if latest["version"] != app["version"]:
                        errors.append(
                            f"{prefix}: App version '{app['version']}' does not match latest versions[0] version '{latest['version']}'"
                        )
                if "downloadURL" in latest and "downloadURL" in app:
                    if latest["downloadURL"] != app["downloadURL"]:
                        errors.append(
                            f"{prefix}: App downloadURL does not match latest versions[0] downloadURL"
                        )
                if "size" in latest and "size" in app:
                    if latest["size"] != app["size"]:
                        errors.append(f"{prefix}: App size does not match latest versions[0] size")

                for v_idx, ver in enumerate(versions):
                    v_prefix = f"{prefix}.versions[{v_idx}]"
                    for v_field, v_type in REQUIRED_VERSION_FIELDS.items():
                        if v_field not in ver:
                            errors.append(f"{v_prefix}: Missing required field '{v_field}'")
                        elif not isinstance(ver[v_field], v_type):
                            errors.append(
                                f"{v_prefix}: Field '{v_field}' must be {v_type.__name__}, got {type(ver[v_field]).__name__}"
                            )
                        elif v_type is str and not ver[v_field].strip():
                            errors.append(f"{v_prefix}: Field '{v_field}' cannot be empty.")
                        elif v_type is int and ver[v_field] <= 0:
                            errors.append(f"{v_prefix}: Field '{v_field}' must be greater than 0.")

                    if "version" in ver and isinstance(ver["version"], str):
                        if not SEMVER_REGEX.match(ver["version"]):
                            errors.append(f"{v_prefix}: Invalid version format '{ver['version']}'")

                    if "date" in ver and isinstance(ver["date"], str):
                        try:
                            validate_date(ver["date"], f"{v_prefix}.date")
                        except ValidationError as ve:
                            errors.append(str(ve))

                    if "downloadURL" in ver and isinstance(ver["downloadURL"], str):
                        try:
                            validate_url(ver["downloadURL"], f"{v_prefix}.downloadURL", must_end_with=".ipa")
                        except ValidationError as ve:
                            errors.append(str(ve))

    # 3. Validate News Array (if present)
    if "news" in data:
        news = data["news"]
        if not isinstance(news, list):
            errors.append("Root field 'news' must be a list.")
        else:
            for n_idx, item in enumerate(news):
                n_prefix = f"news[{n_idx}]"
                for field in ("title", "identifier", "caption", "date"):
                    if field not in item:
                        errors.append(f"{n_prefix}: Missing field '{field}'")
                if "date" in item:
                    try:
                        validate_date(item["date"], f"{n_prefix}.date")
                    except ValidationError as ve:
                        errors.append(str(ve))
                if "imageURL" in item:
                    try:
                        validate_url(item["imageURL"], f"{n_prefix}.imageURL")
                    except ValidationError as ve:
                        errors.append(str(ve))
                if "url" in item:
                    try:
                        validate_url(item["url"], f"{n_prefix}.url")
                    except ValidationError as ve:
                        errors.append(str(ve))

    # Print Results
    if errors:
        print(f"\n[FAIL] Found {len(errors)} validation issue(s):")
        for err in errors:
            print(f"  - {err}")
        return False
    else:
        app_count = len(apps)
        ver_count = sum(len(a.get("versions", [])) for a in apps)
        print("\n[PASS] Source JSON schema is 100% valid!")
        print(f"  - Repository Name: {data.get('name')}")
        print(f"  - Identifier:      {data.get('identifier')}")
        print(f"  - Apps Registered: {app_count}")
        print(f"  - Total Releases:  {ver_count}")
        for a in apps:
            print(f"    * {a.get('name')} ({a.get('bundleIdentifier')}) - v{a.get('version')} ({a.get('size')} bytes)")
            print(f"      IPA URL: {a.get('downloadURL')}")
        return True


if __name__ == "__main__":
    target = "/root/edge-eloquent/feather-source.json"
    if len(sys.argv) > 1:
        target = sys.argv[1]
    
    success = validate_source_json(target)
    sys.exit(0 if success else 1)
