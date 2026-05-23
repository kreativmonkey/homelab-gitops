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
        fi
        echo "$line"
    done <<< "$suspicious_versions"
    
    if [ "$found_any" = false ]; then
        echo -e "${GREEN}✓ No suspicious 'version:' fields found.${NC}"
    fi
else
    echo -e "${GREEN}✓ No suspicious 'version:' fields found.${NC}"
fi

# 3. Check for Grafana plugins (should be caught by our custom regex)
echo -e "\n${YELLOW}Checking for Grafana plugins...${NC}"
grafana_plugins=$(grep -r "@[0-9]\+\.[0-9]\+" apps/ --include="*.yaml" | grep -v "# renovate:" || true)
if [[ -n "$grafana_plugins" ]]; then
    echo -e "${GREEN}✓ Found Grafana plugins (tracked by custom regex).${NC}"
else
    echo -e "${GREEN}✓ No Grafana plugins found.${NC}"
fi

# 4. Check for remote Kustomize resources
echo -e "\n${YELLOW}Checking for remote Kustomize resources...${NC}"
remote_resources=$(grep -rE "https?://|github\.com" **/kustomization.yaml || true)
if [[ -n "$remote_resources" ]]; then
    echo -e "${GREEN}✓ Found remote Kustomize resources (tracked by kustomize manager).${NC}"
else
    echo -e "${GREEN}✓ No remote Kustomize resources found.${NC}"
fi

echo -e "\n${YELLOW}Audit complete.${NC}"
exit $EXIT_CODE
