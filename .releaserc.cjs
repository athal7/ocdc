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
            name: 'ocdc-${nextRelease.version}.tar.gz'
          }
        ]
      }
    ]
  ]
};