module.exports = {
  branches: [
    'main'
  ],
  
  plugins: [
    // Analyze commits to determine release type
    '@semantic-release/commit-analyzer',
    
    // Generate release notes
    '@semantic-release/release-notes-generator',
    
    // Update version in package.json and publish to npm with provenance
    ['@semantic-release/npm', { provenance: true }],
    
    // Commit the version changes
    [
      '@semantic-release/git',
      {
        assets: ['package.json', 'package-lock.json'],
        message: 'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}'
      }
    ],
    
    // Create GitHub release
    '@semantic-release/github'
  ]
};
