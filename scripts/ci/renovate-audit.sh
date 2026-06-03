#!/usr/bin/env bash
# Renovate Dependency Audit – verifies that all images and versions in YAML manifests
# are covered by Renovate's configuration or have explicit markers.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Starting Renovate Dependency Audit...${NC}"

EXIT_CODE=0

# 1. Check for images without explicit tags or Renovate markers
echo -e "\n${YELLOW}Checking for images without explicit tags or Renovate markers...${NC}"
# We ignore empty 'image:' keys and lines with Renovate markers.
# We also ignore 'latest' if it's intentional (though discouraged).
# We only care about lines that actually look like they have a repo but no tag.
images_without_tags=$(grep -r "image:" apps/ infrastructure/ clusters/ --include="*.yaml" \
    | grep -vE "# renovate:|image:\s*[\"']?\s*$" \
    | grep -vE ":[0-9]+(\.[0-9]+)*" \
    | grep -vE ":v[0-9]+" \
    | grep -vE "image: [^:]+:[^:]+" || true)

if [[ -n "$images_without_tags" ]]; then
    # Filter out known false positives or expected 'latest'
    filtered_images=$(echo "$images_without_tags" | grep -v "latest" || true)
    if [[ -n "$filtered_images" ]]; then
        echo -e "${RED}Found potential untracked images (missing version tag or marker):${NC}"
        echo "$filtered_images"
        EXIT_CODE=1
    else
        echo -e "${GREEN}✓ All images seem to have tags or markers (excluding 'latest').${NC}"
    fi
else
    echo -e "${GREEN}✓ All images seem to have tags or markers.${NC}"
fi

# 2. Check for version fields in custom resources that lack markers.
echo -e "\n${YELLOW}Checking for 'version:' fields in custom resources without markers...${NC}"
suspicious_versions=$(grep -r "version:" apps/ infrastructure/ clusters/ --include="*.yaml" \
    | grep -vE "# renovate:|.secret.yaml" \
    | grep -E ": [\"']?[vV]?[0-9]+\.[0-9]+" || true)

if [[ -n "$suspicious_versions" ]]; then
    found_any=false
    while read -r line; do
        file=$(echo "$line" | cut -d: -f1)
        # Standard Flux HelmReleases are handled automatically
        if grep -q "kind: HelmRelease" "$file"; then continue; fi
        # Flux components in gotk-components.yaml are special
        if [[ "$file" == *"gotk-components.yaml" ]]; then continue; fi

        if [ "$found_any" = false ]; then
            echo -e "${RED}Found 'version:' fields without markers in non-HelmRelease files:${NC}"
            found_any=true
            EXIT_CODE=1
        fi
        echo "$line"
    done <<< "$suspicious_versions"

    if [ "$found_any" = false ]; then
        echo -e "${GREEN}✓ No suspicious 'version:' fields found.${NC}"
    fi
else
    echo -e "${GREEN}✓ No suspicious 'version:' fields found.${NC}"
fi

# 3. Grafana plugins: require renovate marker on previous line or dedicated manager
echo -e "\n${YELLOW}Checking Grafana plugins (@version)...${NC}"
while IFS= read -r plugin_line; do
    file="${plugin_line%%:*}"
    lineno="${plugin_line#*:}"
    lineno="${lineno%%:*}"
    prev=$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null || true)
    if [[ "$prev" != *"# renovate:"* ]]; then
        echo -e "${RED}Grafana plugin without renovate marker on previous line:${NC} $plugin_line"
        EXIT_CODE=1
    fi
done < <(grep -rnE '@[0-9]+\.[0-9]+' apps/ --include="*.yaml" | grep -E 'plugins:|^\s*-\s+[^@]+@' || true)
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e "${GREEN}✓ Grafana plugins have renovate markers.${NC}"
fi

# 4. Grafana plugin pins must exist in grafana.com catalog (Grafana preinstalls from catalog)
echo -e "\n${YELLOW}Validating Grafana plugin versions against grafana.com catalog...${NC}"
while IFS= read -r marker_line; do
    file=$(echo "$marker_line" | cut -d: -f1)
    lineno=$(echo "$marker_line" | cut -d: -f2)
    plugin_line=$(sed -n "$((lineno + 1))p" "$file")
    plugin_id=$(echo "$plugin_line" | sed -n 's/^[[:space:]]*-[[:space:]]*\([^@[:space:]]*\)@.*/\1/p')
    plugin_ver=$(echo "$plugin_line" | sed -n 's/^[[:space:]]*-[[:space:]]*[^@[:space:]]*@\([^[:space:]#]*\).*/\1/p')
    [[ -n "$plugin_id" && -n "$plugin_ver" ]] || continue
    if ! curl -fsS "https://grafana.com/api/plugins/${plugin_id}/versions" \
        | jq -e --arg v "$plugin_ver" '.items[] | select(.version == $v)' >/dev/null; then
        echo -e "${RED}Grafana plugin version not in catalog:${NC} ${plugin_id}@${plugin_ver}"
        echo "  ${file}:${lineno}"
        EXIT_CODE=1
    fi
done < <(grep -rn 'datasource=custom\.grafana-plugins' apps/ infrastructure/ clusters/ --include="*.yaml" || true)
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e "${GREEN}✓ All pinned Grafana plugin versions exist in the catalog.${NC}"
fi

# 5. github-releases depName must be a real GitHub repo (plugin id != repo name)
echo -e "\n${YELLOW}Validating github-releases depName markers...${NC}"
while IFS= read -r marker_line; do
    dep_name=$(echo "$marker_line" | sed -n 's/.*depName=\([^[:space:]]*\).*/\1/p')
    [[ -n "$dep_name" ]] || continue
    http_code=$(curl -fsS -o /dev/null -w '%{http_code}' \
        "https://api.github.com/repos/${dep_name}" 2>/dev/null || echo "000")
    if [[ "$http_code" != "200" ]]; then
        echo -e "${RED}Invalid github-releases depName (GitHub repo not found):${NC} ${dep_name}"
        echo "  ${marker_line}"
        EXIT_CODE=1
    fi
done < <(grep -rn 'datasource=github-releases' apps/ infrastructure/ clusters/ --include="*.yaml" || true)
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e "${GREEN}✓ All github-releases depName values resolve on GitHub.${NC}"
fi

# 6. Check for remote Kustomize resources
echo -e "\n${YELLOW}Checking for remote Kustomize resources...${NC}"
remote_resources=$(grep -rE "https?://|github\.com" **/kustomization.yaml 2>/dev/null || true)
if [[ -n "$remote_resources" ]]; then
    echo -e "${GREEN}✓ Found remote Kustomize resources (tracked by kustomize manager).${NC}"
else
    echo -e "${GREEN}✓ No remote Kustomize resources found.${NC}"
fi

# 7. renovate.json managerFilePatterns must match nested paths (not only repo-root filenames)
echo -e "\n${YELLOW}Checking renovate.json managerFilePatterns...${NC}"
if grep -qE '\(\^\|\)/\)\(helmrelease\|values\|deployment\)' renovate.json 2>/dev/null \
    || grep -qE '"\(\^\|/\)helmrelease' renovate.json; then
    echo -e "${RED}renovate.json uses root-only managerFilePatterns; nested paths like apps/**/helmrelease.yaml will not match.${NC}"
    EXIT_CODE=1
else
    echo -e "${GREEN}✓ managerFilePatterns look nested-path safe.${NC}"
fi

echo -e "\n${YELLOW}Audit complete.${NC}"
exit $EXIT_CODE
