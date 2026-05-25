module.exports = {
  platform: "forgejo",
  endpoint: "http://server:3000/api/v1",
  logLevel: "debug",
  timezone: "Europe/Berlin",
  
  // Auto-discover Forgejo repositories in homelab and kreativmonkey orgs
  autodiscover: true,
  autodiscoverFilter: ["homelab", "kreativmonkey"],
  
  // GitHub.com datasources access (for external dependencies)
  hostRules: [
    {
      hostName: "github.com",
      token: "{{ secrets.RENOVATE_GITHUB_COM_TOKEN }}"
    }
  ],
  
  // Package management rules
  packageRules: [
    {
      matchPackagePatterns: ["*"],
      matchUpdateTypes: ["major", "minor", "patch"],
      enabled: true
    }
  ],
  
  // Schedule runs (UTC time - adjust for Europe/Berlin)
  schedule: ["at 3:00 am on monday"],
  
  // PR configuration
  prTitle: "deps: Update {{depName}} to {{newVersion}}",
  prBody: "Updates [{{depName}}]({{depHomepage}}) from `{{currentVersion}}` to `{{newVersion}}`."
};