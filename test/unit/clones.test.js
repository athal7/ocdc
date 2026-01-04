/**
 * Tests for plugin/core/clones.js
 * 
 * Run with: node --test test/unit/clones.test.js
 */

import { test, describe, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert'
import { join, basename } from 'path'
import { homedir } from 'os'
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from 'fs'
import { execSync } from 'child_process'

// Module under test
import { 
  createClone,
  copyGitignored,
  getClonePath,
  listClones
} from '../../plugin/core/clones.js'
import { PATHS } from '../../plugin/core/paths.js'

describe('getClonePath', () => {
  test('returns path under clones directory', () => {
    const path = getClonePath('my-repo', 'feature-branch')
    assert.strictEqual(path, join(PATHS.clones, 'my-repo', 'feature-branch'))
  })

  test('handles branches with slashes', () => {
    const path = getClonePath('my-repo', 'feature/nested/branch')
    assert.strictEqual(path, join(PATHS.clones, 'my-repo', 'feature/nested/branch'))
  })
})

describe('copyGitignored', () => {
  const testDir = join(homedir(), '.cache/ocdc-test-copy-' + Date.now())
  const sourceDir = join(testDir, 'source')
  const destDir = join(testDir, 'dest')

  beforeEach(() => {
    mkdirSync(sourceDir, { recursive: true })
    mkdirSync(destDir, { recursive: true })
    
    // Create source repo with gitignore
    execSync('git init -b main', { cwd: sourceDir })
    writeFileSync(join(sourceDir, '.gitignore'), 'secrets.json\n.env\nnode_modules/\n')
    writeFileSync(join(sourceDir, 'README.md'), '# Test')
    execSync('git add .', { cwd: sourceDir })
    execSync('git commit -m "Initial"', { cwd: sourceDir })
    
    // Add gitignored files
    writeFileSync(join(sourceDir, 'secrets.json'), '{"key": "secret"}')
    writeFileSync(join(sourceDir, '.env'), 'API_KEY=xxx')
    
    // Add node_modules with many files (should be skipped)
    mkdirSync(join(sourceDir, 'node_modules', 'pkg'), { recursive: true })
    for (let i = 0; i < 20; i++) {
      writeFileSync(join(sourceDir, 'node_modules', 'pkg', `file${i}.js`), '')
    }
  })

  afterEach(() => {
    rmSync(testDir, { recursive: true, force: true })
  })

  test('copies small gitignored files', async () => {
    await copyGitignored(sourceDir, destDir)
    
    assert.ok(existsSync(join(destDir, 'secrets.json')))
    assert.ok(existsSync(join(destDir, '.env')))
  })

  test('skips directories with many gitignored files', async () => {
    await copyGitignored(sourceDir, destDir)
    
    // node_modules has >10 files, should be skipped entirely
    assert.ok(!existsSync(join(destDir, 'node_modules')))
  })

  test('preserves file content', async () => {
    await copyGitignored(sourceDir, destDir)
    
    const content = readFileSync(join(destDir, 'secrets.json'), 'utf-8')
    assert.strictEqual(content, '{"key": "secret"}')
  })

  test('does not overwrite existing files', async () => {
    writeFileSync(join(destDir, 'secrets.json'), 'existing')
    await copyGitignored(sourceDir, destDir)
    
    const content = readFileSync(join(destDir, 'secrets.json'), 'utf-8')
    assert.strictEqual(content, 'existing')
  })

  test('skips lock files', async () => {
    writeFileSync(join(sourceDir, 'package-lock.json'), '{}')
    await copyGitignored(sourceDir, destDir)
    
    assert.ok(!existsSync(join(destDir, 'package-lock.json')))
  })
})

describe('createClone', () => {
  const testDir = join(homedir(), '.cache/ocdc-test-createclone-' + Date.now())
  const sourceDir = join(testDir, 'source')

  beforeEach(() => {
    process.env.OCDC_CLONES_DIR = join(testDir, 'clones')
    
    mkdirSync(sourceDir, { recursive: true })
    
    // Create source repo
    execSync('git init -b main', { cwd: sourceDir })
    writeFileSync(join(sourceDir, '.gitignore'), '.env\n')
    writeFileSync(join(sourceDir, 'README.md'), '# Test')
    execSync('git add .', { cwd: sourceDir })
    execSync('git commit -m "Initial"', { cwd: sourceDir })
    
    // Add gitignored file
    writeFileSync(join(sourceDir, '.env'), 'SECRET=value')
  })

  afterEach(() => {
    delete process.env.OCDC_CLONES_DIR
    rmSync(testDir, { recursive: true, force: true })
  })

  test('creates clone in correct location', async () => {
    const result = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-x',
    })
    
    assert.ok(result.workspace.includes('clones'))
    assert.ok(result.workspace.includes('source'))
    assert.ok(result.workspace.includes('feature-x'))
    assert.ok(result.created)
    assert.ok(existsSync(result.workspace))
    assert.ok(existsSync(join(result.workspace, '.git')))
  })

  test('copies gitignored files to clone', async () => {
    const result = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-y',
    })
    
    assert.ok(existsSync(join(result.workspace, '.env')))
    const content = readFileSync(join(result.workspace, '.env'), 'utf-8')
    assert.strictEqual(content, 'SECRET=value')
  })

  test('returns existing clone without recreating', async () => {
    const result1 = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-z',
    })
    
    // Modify clone to verify it's not recreated
    writeFileSync(join(result1.workspace, 'marker.txt'), 'exists')
    
    const result2 = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-z',
    })
    
    assert.strictEqual(result1.workspace, result2.workspace)
    assert.ok(!result2.created)
    assert.ok(existsSync(join(result2.workspace, 'marker.txt')))
  })

  test('recreates clone with force option', async () => {
    const result1 = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-force',
    })
    
    writeFileSync(join(result1.workspace, 'marker.txt'), 'exists')
    
    const result2 = await createClone({
      repoRoot: sourceDir,
      branch: 'feature-force',
      force: true,
    })
    
    assert.ok(result2.created)
    assert.ok(!existsSync(join(result2.workspace, 'marker.txt')))
  })

  test('creates branch if it does not exist', async () => {
    const result = await createClone({
      repoRoot: sourceDir,
      branch: 'new-branch',
    })
    
    // Should create branch locally
    const { getCurrentBranch } = await import('../../plugin/core/git.js')
    const branch = await getCurrentBranch(result.workspace)
    assert.strictEqual(branch, 'new-branch')
  })
})

describe('listClones', () => {
  const testDir = join(homedir(), '.cache/ocdc-test-listclones-' + Date.now())

  beforeEach(() => {
    process.env.OCDC_CLONES_DIR = testDir
    
    // Create some clone directories
    mkdirSync(join(testDir, 'repo-a', 'main'), { recursive: true })
    mkdirSync(join(testDir, 'repo-a', 'feature'), { recursive: true })
    mkdirSync(join(testDir, 'repo-b', 'develop'), { recursive: true })
    
    // Add .git directories to simulate real clones
    mkdirSync(join(testDir, 'repo-a', 'main', '.git'), { recursive: true })
    mkdirSync(join(testDir, 'repo-a', 'feature', '.git'), { recursive: true })
    mkdirSync(join(testDir, 'repo-b', 'develop', '.git'), { recursive: true })
  })

  afterEach(() => {
    delete process.env.OCDC_CLONES_DIR
    rmSync(testDir, { recursive: true, force: true })
  })

  test('lists all clones', async () => {
    const clones = await listClones()
    
    assert.strictEqual(clones.length, 3)
    assert.ok(clones.some(c => c.repo === 'repo-a' && c.branch === 'main'))
    assert.ok(clones.some(c => c.repo === 'repo-a' && c.branch === 'feature'))
    assert.ok(clones.some(c => c.repo === 'repo-b' && c.branch === 'develop'))
  })

  test('filters by repo', async () => {
    const clones = await listClones({ repo: 'repo-a' })
    
    assert.strictEqual(clones.length, 2)
    assert.ok(clones.every(c => c.repo === 'repo-a'))
  })

  test('returns empty array when no clones', async () => {
    rmSync(testDir, { recursive: true, force: true })
    mkdirSync(testDir, { recursive: true })
    
    const clones = await listClones()
    assert.deepStrictEqual(clones, [])
  })
})
