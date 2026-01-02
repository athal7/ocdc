module.exports = {
  branches: [
    'main'
  ],
  
  plugins: [
    // Analyze commits to determine release type
    '@semantic-release/commit-analyzer',
    
    // Generate release notes
    '@semantic-release/release-notes-generator',
    
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
    ]
  ]
};