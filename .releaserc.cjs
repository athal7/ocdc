module.exports = {
  branches: [
    'main'
  ],
  
  plugins: [
    // Analyze commits to determine release type
    '@semantic-release/commit-analyzer',
    
    // Generate release notes
    '@semantic-release/release-notes-generator',
    
    // Update version in package.json (no npm publish)
    [
      '@semantic-release/npm',
      {
        npmPublish: false
      }
    ],
    
    // Update VERSION in bin/ocdc (use perl for cross-platform in-place edit)
    [
      '@semantic-release/exec',
      {
        prepareCmd: "perl -i -pe 's/^VERSION=\".*\"/VERSION=\"${nextRelease.version}\"/' bin/ocdc"
      }
    ],
    
    // Commit the version changes
    [
      '@semantic-release/git',
      {
        assets: ['package.json', 'package-lock.json', 'bin/ocdc'],
        message: 'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}'
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
            name: 'ocdc-${nextRelease.version}.tar.gz'
          }
        ]
      }
    ]
  ]
};
