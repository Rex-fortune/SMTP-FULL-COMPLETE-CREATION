#!/usr/bin/env python3
"""
Site Cloner - Authorized Penetration Testing Tool
Clones a target website completely (HTML, images, PDFs, CSS, JS)

Usage:
    python3 clone_site.py <target_url> <output_dir>

Example:
    python3 clone_site.py https://www.example.com/ example-clone
    python3 clone_site.py https://www.oneexample.com/ oneexample-clone

External Dependencies: None (uses only Python standard library)
"""

import os
import re
import sys
import time
import hashlib
import urllib.parse
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError
from html.parser import HTMLParser

# ============================================================
# CONFIGURATION
# ============================================================
DELAY = 0.5  # seconds between requests (be polite)
MAX_RETRIES = 3
TIMEOUT = 30
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

# Asset extensions to always download
ASSET_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.svg', '.webp', '.ico',
                    '.css', '.js', '.pdf', '.doc', '.docx', '.xls', '.xlsx',
                    '.woff', '.woff2', '.ttf', '.eot', '.mp4', '.webm'}


# ============================================================
# FETCHER
# ============================================================
def fetch_url(url):
    """Fetch a URL with retries and proper headers."""
    for attempt in range(MAX_RETRIES):
        try:
            # Sanitize URL — encode spaces and other unsafe characters
            parsed = urllib.parse.urlparse(url)
            clean_path = urllib.parse.quote(parsed.path, safe='/:@!$&\'()*+,;=-._~')
            clean_url = urllib.parse.urlunparse((
                parsed.scheme,
                parsed.netloc,
                clean_path,
                parsed.params,
                parsed.query,
                parsed.fragment
            ))

            req = Request(clean_url, headers={
                'User-Agent': USER_AGENT,
                'Accept': '*/*',
                'Accept-Language': 'en-US,en;q=0.9',
            })
            resp = urlopen(req, timeout=TIMEOUT)
            content = resp.read()
            content_type = resp.headers.get('Content-Type', '').lower()
            return content, content_type
        except HTTPError as e:
            if e.code == 404:
                return None, 'text/html'
            print(f"  [WARN] HTTP {e.code} for {url} (attempt {attempt+1}/{MAX_RETRIES})")
            time.sleep(DELAY)
        except (URLError, TimeoutError, ConnectionError) as e:
            print(f"  [WARN] {type(e).__name__} for {url} (attempt {attempt+1}/{MAX_RETRIES})")
            time.sleep(DELAY * 2)
        except Exception as e:
            print(f"  [WARN] {type(e).__name__} for {url}: {e} (attempt {attempt+1}/{MAX_RETRIES})")
            time.sleep(DELAY)
    return None, 'text/html'


# ============================================================
# HTML PARSER for LINK EXTRACTION
# ============================================================
class LinkExtractor(HTMLParser):
    """Extract all src, href, and srcset from HTML."""
    def __init__(self, base_url, site_domain):
        super().__init__()
        self.base_url = base_url
        self.site_domain = site_domain
        self.links = set()
        self.pages = set()
        self.assets = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        base = self.base_url

        # Links to other pages
        if tag == 'a' and 'href' in attrs:
            href = attrs['href']
            full = urllib.parse.urljoin(base, href)
            parsed = urllib.parse.urlparse(full)
            # Only internal links (same domain or relative)
            if not parsed.netloc or parsed.netloc == self.site_domain:
                clean = urllib.parse.urlunparse((
                    parsed.scheme, parsed.netloc, parsed.path,
                    parsed.params, parsed.query, ''
                ))
                ext = os.path.splitext(parsed.path)[1].lower()
                if not ext or ext in ('.html', '.htm') or parsed.path.endswith('/'):
                    self.pages.add(clean)
                else:
                    self.assets.add(clean)

        # Images
        if tag == 'img' and 'src' in attrs:
            self.assets.add(urllib.parse.urljoin(base, attrs['src']))
        if tag == 'img' and 'srcset' in attrs:
            for part in attrs['srcset'].split(','):
                src = part.strip().split(' ')[0]
                self.assets.add(urllib.parse.urljoin(base, src))

        # CSS, JS, favicon, etc.
        if tag == 'link' and 'href' in attrs:
            self.assets.add(urllib.parse.urljoin(base, attrs['href']))
        if tag == 'script' and 'src' in attrs:
            self.assets.add(urllib.parse.urljoin(base, attrs['src']))
        if tag == 'source' and 'src' in attrs:
            self.assets.add(urllib.parse.urljoin(base, attrs['src']))
        if tag == 'iframe' and 'src' in attrs:
            self.assets.add(urllib.parse.urljoin(base, attrs['src']))

        # Inline style background images
        if tag in ('div', 'span', 'section', 'header', 'footer') and 'style' in attrs:
            urls = re.findall(r'url\(["\']?([^"\'\)]+)["\']?\)', attrs['style'])
            for u in urls:
                self.assets.add(urllib.parse.urljoin(base, u))

    def handle_data(self, data):
        pass


def extract_links(html_content, base_url, site_domain):
    """Extract all links from HTML."""
    parser = LinkExtractor(base_url, site_domain)
    try:
        parser.feed(html_content.decode('utf-8', errors='replace'))
    except Exception:
        try:
            parser.feed(html_content.decode('latin-1'))
        except Exception as e:
            print(f"  [ERROR] Parsing HTML: {e}")
    return parser.pages, parser.assets


def extract_css_urls(css_content, base_url):
    """Extract URLs from CSS (url(), @import, etc.)."""
    urls = set()
    css_text = css_content.decode('utf-8', errors='replace')

    for match in re.finditer(r'url\(["\']?([^"\'\)]+)["\']?\)', css_text):
        urls.add(urllib.parse.urljoin(base_url, match.group(1)))

    for match in re.finditer(r'@import\s+["\']([^"\']+)["\']', css_text):
        urls.add(urllib.parse.urljoin(base_url, match.group(1)))

    return urls


# ============================================================
# FILE SAVER
# ============================================================
def save_file(url, content, output_dir):
    """Save fetched content to the proper local path, preserving directory structure."""
    parsed = urllib.parse.urlparse(url)
    path = parsed.path

    if path == '' or path.endswith('/'):
        path = os.path.join(path, 'index.html')

    local_path = os.path.join(output_dir, path.lstrip('/'))
    local_path = urllib.parse.unquote(local_path)
    if '?' in local_path:
        local_path = local_path.split('?')[0]

    local_path = os.path.normpath(local_path)
    dir_path = os.path.dirname(local_path)

    if not dir_path:
        dir_path = output_dir
        local_path = os.path.join(output_dir, os.path.basename(local_path))

    os.makedirs(dir_path, exist_ok=True)

    try:
        if isinstance(content, str):
            content = content.encode('utf-8')
        with open(local_path, 'wb') as f:
            f.write(content)
        return local_path
    except Exception as e:
        print(f"  [ERROR] Saving {local_path}: {e}")
        return None


def get_local_path(url, output_dir):
    """Convert a URL to its local file path."""
    parsed = urllib.parse.urlparse(url)
    path = parsed.path
    if path == '' or path.endswith('/'):
        path = os.path.join(path, 'index.html')
    local_path = os.path.join(output_dir, path.lstrip('/'))
    local_path = urllib.parse.unquote(local_path)
    if '?' in local_path:
        local_path = local_path.split('?')[0]
    return os.path.normpath(local_path)


# ============================================================
# REWRITE HTML TO USE LOCAL PATHS
# ============================================================
def rewrite_html(content, url, output_dir, base_domain):
    """Rewrite HTML content to replace remote URLs with local paths."""
    text = content.decode('utf-8', errors='replace')

    def to_local_path(url_value):
        full_url = urllib.parse.urljoin(url, url_value)
        parsed = urllib.parse.urlparse(full_url)

        # Skip external absolute URLs
        if parsed.netloc and parsed.netloc != base_domain:
            return None

        local = get_local_path(full_url, '')
        current_path = get_local_path(url, '')
        current_dir = os.path.dirname(current_path)
        if current_dir == '' or current_dir == '/':
            current_dir = ''

        try:
            rel = os.path.relpath(local.lstrip('/'), current_dir.lstrip('/'))
        except ValueError:
            rel = local

        if not rel.startswith('.') and not rel.startswith('/'):
            rel = './' + rel

        return rel

    def replace_srcset(match):
        prefix = match.group(1)
        url_value = match.group(2)
        suffix = match.group(3)
        parts = []
        for part in url_value.split(','):
            part = part.strip()
            if part:
                sub_parts = part.split(' ')
                if sub_parts:
                    new_url = to_local_path(sub_parts[0])
                    if new_url:
                        sub_parts[0] = new_url
                    parts.append(' '.join(sub_parts))
        return prefix + ', '.join(parts) + suffix

    def replace_single(match):
        prefix = match.group(1)
        url_value = match.group(2)
        suffix = match.group(3)
        new_url = to_local_path(url_value)
        if new_url:
            return prefix + new_url + suffix
        return match.group(0)

    # srcset (comma-separated URLs)
    text = re.sub(r'(srcset=["\'])([^"\']+)(["\'])', replace_srcset, text)

    # Single URL attributes
    for attr in ['src', 'href', 'data-src', 'poster']:
        text = re.sub(
            r'(' + attr + r'=["\'])([^"\']+)(["\'])',
            replace_single, text
        )

    # CSS url() references
    text = re.sub(
        r'(url\(["\']?)([^"\'\)]+)(["\']?\))',
        replace_single, text
    )

    return text.encode('utf-8')


# ============================================================
# MAIN CLONING LOGIC
# ============================================================
def clone_site(base_url, output_dir):
    print("=" * 60)
    print("  SEDFA Site Cloner - Authorized Pentest Tool")
    print(f"  Source: {base_url}")
    print(f"  Output: {output_dir}/")
    print("=" * 60)

    # Extract domain for internal-link filtering
    parsed_base = urllib.parse.urlparse(base_url)
    site_domain = parsed_base.netloc

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # Bootstrap: start by crawling the root page
    all_assets = set()

    # ==============================
    # PHASE 1: Crawl all HTML pages
    # ==============================
    print("\n[PHASE 1] Crawling HTML pages...")

    # Start with the root URL
    root_url = base_url.rstrip('/') + '/'
    to_visit = {root_url}
    visited = set()

    while to_visit:
        page_url = to_visit.pop()
        if page_url in visited:
            continue
        visited.add(page_url)

        # Skip non-HTML pages by extension
        parsed = urllib.parse.urlparse(page_url)
        ext = os.path.splitext(parsed.path)[1].lower()
        if ext and ext not in ('', '.html', '.htm'):
            print(f"  [SKIP] Non-HTML: {page_url}")
            continue

        print(f"  Crawling: {page_url}")
        content, content_type = fetch_url(page_url)
        if content is None:
            print(f"    [SKIP] Could not fetch")
            continue

        saved = save_file(page_url, content, output_dir)
        if saved:
            print(f"    [SAVED] {saved}")

        # Extract links from HTML
        if 'text/html' in content_type:
            pages, assets = extract_links(content, page_url, site_domain)
            for p in pages:
                if p not in visited:
                    to_visit.add(p)
            all_assets.update(assets)

        time.sleep(DELAY)

    print(f"\n  Discovered {len(visited)} pages, {len(all_assets)} assets")

    # ==============================
    # PHASE 2: Download all assets
    # ==============================
    print("\n[PHASE 2] Downloading assets (images, CSS, JS, PDFs)...")

    # Re-scan downloaded HTML for additional inline assets
    for root, dirs, files in os.walk(output_dir):
        for fname in files:
            if fname.endswith('.html'):
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, 'rb') as f:
                        html_content = f.read()
                    rel_path = os.path.relpath(fpath, output_dir).replace('\\', '/')
                    page_url = urllib.parse.urljoin(base_url, '/' + rel_path)
                    _, page_assets = extract_links(html_content, page_url, site_domain)
                    all_assets.update(page_assets)
                except Exception as e:
                    print(f"  [WARN] Scanning {fpath}: {e}")

    # Scan CSS for background images
    for root, dirs, files in os.walk(output_dir):
        for fname in files:
            if fname.endswith('.css'):
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, 'rb') as f:
                        css_content = f.read()
                    rel_path = os.path.relpath(fpath, output_dir).replace('\\', '/')
                    css_url = urllib.parse.urljoin(base_url, '/' + rel_path)
                    css_assets = extract_css_urls(css_content, css_url)
                    all_assets.update(css_assets)
                except Exception:
                    pass

    # Filter and download unique assets
    failed_files = set()
    unique_assets = set()
    for asset_url in all_assets:
        parsed = urllib.parse.urlparse(asset_url)
        if parsed.netloc and parsed.netloc != site_domain:
            continue
        if not parsed.path or parsed.path.startswith('#') or parsed.path.startswith('javascript:'):
            continue
        ext = os.path.splitext(parsed.path)[1].lower()
        if ext in ASSET_EXTENSIONS or not ext:
            unique_assets.add(asset_url)

    total_assets = len(unique_assets)
    downloaded = 0

    for i, asset_url in enumerate(sorted(unique_assets)):
        local_path = get_local_path(asset_url, output_dir)
        if os.path.exists(local_path):
            downloaded += 1
            continue

        print(f"  [{i+1}/{total_assets}] Asset: {asset_url}")
        content, content_type = fetch_url(asset_url)
        if content:
            saved = save_file(asset_url, content, output_dir)
            if saved:
                downloaded += 1
                print(f"    [SAVED] {saved}")
            else:
                failed_files.add(asset_url)
        else:
            print(f"    [FAILED] Could not download")
            failed_files.add(asset_url)

        time.sleep(DELAY)

    print(f"\n  Downloaded {downloaded}/{total_assets} assets")

    # ==============================
    # PHASE 3: Rewrite HTML for local browsing
    # ==============================
    print("\n[PHASE 3] Rewriting HTML to use local paths...")
    rewritten = 0
    for root, dirs, files in os.walk(output_dir):
        for fname in files:
            if fname.endswith('.html'):
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, 'rb') as f:
                        content = f.read()
                    rel_path = os.path.relpath(fpath, output_dir).replace('\\', '/')
                    page_url = urllib.parse.urljoin(base_url, '/' + rel_path)
                    new_content = rewrite_html(content, page_url, output_dir, site_domain)
                    with open(fpath, 'wb') as f:
                        f.write(new_content)
                    rewritten += 1
                except Exception as e:
                    print(f"  [WARN] Rewriting {fpath}: {e}")

    print(f"  Rewrote {rewritten} HTML files")

    # ==============================
    # SUMMARY
    # ==============================
    print("\n" + "=" * 60)
    print("  CLONE COMPLETE")
    print("=" * 60)
    print(f"  Output directory: {os.path.abspath(output_dir)}")
    print(f"  Pages visited:    {len(visited)}")
    print(f"  Assets downloaded: {downloaded}")
    print(f"  Failed downloads: {len(failed_files)}")
    print()
    print("  To view: Open index.html in your browser")
    print(f"  Or run:  python3 -m http.server 8080 -d {output_dir}/")
    print()

    if failed_files:
        log_path = os.path.join(output_dir, '_failed_downloads.txt')
        with open(log_path, 'w') as f:
            for url in sorted(failed_files):
                f.write(url + '\n')
        print(f"  Failed URLs logged to: {log_path}")
    print()


# ============================================================
# USAGE / ENTRY POINT
# ============================================================
def print_usage():
    print("Usage: python3 clone_sedfa.py <target_url> <output_dir>")
    print()
    print("Examples:")
    print("  python3 clone_sedfa.py https://www.example.com/ sedfa-clone")
    print("  python3 clone_sedfa.py https://www.oneexample.com/ oneexample-clone")
    print()
    print("External Dependencies: None")
    print("  This script uses only Python 3 standard library modules:")
    print("    - os, re, sys, time, hashlib")
    print("    - urllib.request, urllib.parse, urllib.error")
    print("    - html.parser")
    print("  No pip packages are required.")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print_usage()
        sys.exit(1)

    target_url = sys.argv[1]
    output_dir = sys.argv[2]

    # Validate URL
    if not target_url.startswith(('http://', 'https://')):
        print("[ERROR] Target URL must start with http:// or https://")
        sys.exit(1)

    # Ensure trailing slash for consistent joining
    if not target_url.endswith('/'):
        target_url += '/'

    try:
        clone_site(target_url, output_dir)
    except KeyboardInterrupt:
        print("\n\n[INTERRUPTED] Cloning stopped by user.")
        print(f"Partial output in: {os.path.abspath(output_dir)}")
        sys.exit(1)