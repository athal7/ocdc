module.exports = {
  branches: [
    'main'
  ],
  
  plugins: [
    // Analyze commits to determine release type
    '@semantic-release/commit-analyzer',
    
    // Generate release notes
    '@semantic-release/release-notes-generator',
    
    // Update CHANGELOG.md
    [
      '@semantic-release/changelog',
      {
        changelogFile: 'CHANGELOG.md',
        changelogTitle: '# OCDC Changelog\n\nAll notable changes to this project will be documented in this file.'
      }
    ],
    
    // Create GitHub release with assets
    [
      '@semantic-release/github',
      {
        assets: [
          {
            path: 'dist/devcontainer-multi.tar.gz',
            label: 'OCDC Release Archive',
            name: (release) => `ocdc-${release.version}.tar.gz`
          }
        ],
        releaseName: (release) => `OCDC ${release.version}`,
        releaseBody: (release) => `## 🎉 Release ${release.version}

### 📦 Installation
\`\`\`bash
brew install ocdc/tap/ocdc
\`\`\`

Or download the archive below.

### 📋 Changes
${release.notes}

### 🔗 Assets
- Binary release: \`ocdc-${release.version}.tar.gz\`
- Homebrew formula will be automatically updated
        `
      }
    ],
    
    // Update version numbers and commit changes
    [
      '@semantic-release/git',
      {
        assets: [
          'CHANGELOG.md',
          'plugin/package.json',
          'package.json'
        ],
        message: (release) => `chore(release): ${release.version} [skip ci]\n\n${release.notes}`
      }
    ],
    
    // Custom plugin to synchronize plugin package.json
    {
      async verifyConditions(pluginConfig, context) {
        // Verify plugin/package.json exists
        const fs = await import('fs');
        if (!fs.existsSync('plugin/package.json')) {
          throw new Error('plugin/package.json not found');
        }
      },
      
      async prepare(pluginConfig, context) {
        const fs = await import('fs');
        const { nextRelease } = context;
        
        // Update plugin/package.json version
        const pluginPackagePath = 'plugin/package.json';
        const pluginPackage = JSON.parse(fs.readFileSync(pluginPackagePath, 'utf8'));
        pluginPackage.version = nextRelease.version;
        fs.writeFileSync(pluginPackagePath, JSON.stringify(pluginPackage, null, 2) + '\n');
        
        context.logger.log(`✅ Updated plugin/package.json to version ${nextRelease.version}`);
      }
    },
    
    // Custom plugin to trigger Homebrew tap update
    {
      async success(pluginConfig, context) {
        const { nextRelease, logger } = context;
        
        // This would typically trigger a webhook or create an issue
        // in the homebrew-tap repository to update the formula
        logger.log(`🍺 Ready to update Homebrew tap for version ${nextRelease.version}`);
        
        // TODO: Add webhook to homebrew-tap repository
        // Could use GitHub API to create an issue or PR
      }
    }
  ]
};