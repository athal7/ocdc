/**
 * Tests for plugin/core/paths.js
 * 
 * Run with: node --test test/unit/paths.test.js
 */

import { test, describe, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert'
import { join } from 'path'
import { homedir } from 'os'
import { mkdirSync, rmSync, existsSync } from 'fs'

// Module under test - will fail until implemented
import { PATHS, pathId, ensureDirs, resolvePath } from '../../plugin/core/paths.js'

describe('PATHS', () => {
  const originalEnv = process.env

  beforeEach(() => {
    // Reset env before each test
    process.env = { ...originalEnv }
  })

  afterEach(() => {
    process.env = originalEnv
  })

  test('uses default paths when no env vars set', () => {
    delete process.env.OCDC_CONFIG_DIR
    delete process.env.OCDC_CACHE_DIR
    delete process.env.OCDC_CLONES_DIR
    
    // Getters return default paths when env vars are unset
    assert.strictEqual(PATHS.config, join(homedir(), '.config/opencode/devcontainers'))
    assert.strictEqual(PATHS.cache, join(homedir(), '.cache/opencode-devcontainers'))
    assert.strictEqual(PATHS.clones, join(homedir(), '.cache/devcontainer-clones'))
  })

  test('respects OCDC_CONFIG_DIR env var', () => {
    process.env.OCDC_CONFIG_DIR = '/custom/config'
    // Note: PATHS is already imported, so we test the getter behavior
    // This will need dynamic import or getter function in implementation
  })

  test('derives ports path from cache', () => {
    assert.strictEqual(PATHS.ports, join(PATHS.cache, 'ports.json'))
  })

  test('derives overrides path from cache', () => {
    assert.strictEqual(PATHS.overrides, join(PATHS.cache, 'overrides'))
  })

  test('derives configFile path from config', () => {
    assert.strictEqual(PATHS.configFile, join(PATHS.config, 'config.json'))
  })

  test('derives sessions path from cache', () => {
    assert.strictEqual(PATHS.sessions, join(PATHS.cache, 'opencode-sessions'))
  })
})

describe('pathId', () => {
  test('generates consistent hash for same path', () => {
    const path = '/Users/test/repo'
    const id1 = pathId(path)
    const id2 = pathId(path)
    assert.strictEqual(id1, id2)
  })

  test('generates different hash for different paths', () => {
    const id1 = pathId('/path/one')
    const id2 = pathId('/path/two')
    assert.notStrictEqual(id1, id2)
  })

  test('returns hex string', () => {
    const id = pathId('/some/path')
    assert.match(id, /^[a-f0-9]+$/)
  })

  test('returns 32 character string (MD5 hex)', () => {
    const id = pathId('/some/path')
    assert.strictEqual(id.length, 32)
  })
})

describe('resolvePath', () => {
  test('resolves symlinks to real path', async () => {
    // This tests that symlinks are resolved consistently
    const resolved = await resolvePath(homedir())
    assert.ok(typeof resolved === 'string')
    assert.ok(resolved.length > 0)
  })

  test('handles non-existent paths gracefully', async () => {
    const resolved = await resolvePath('/nonexistent/path')
    // Should return the original path if it doesn't exist
    assert.strictEqual(resolved, '/nonexistent/path')
  })
})

describe('ensureDirs', () => {
  const testDir = join(homedir(), '.cache/ocdc-test-' + Date.now())

  afterEach(() => {
    // Cleanup test directory
    rmSync(testDir, { recursive: true, force: true })
  })

  test('creates all required directories', async () => {
    // Override PATHS for test
    process.env.OCDC_CACHE_DIR = testDir
    process.env.OCDC_CONFIG_DIR = join(testDir, 'config')
    
    await ensureDirs()
    
    // Check directories were created
    assert.ok(existsSync(testDir))
    assert.ok(existsSync(join(testDir, 'config')))
    assert.ok(existsSync(join(testDir, 'overrides')))
    assert.ok(existsSync(join(testDir, 'opencode-sessions')))
  })

  test('is idempotent - can be called multiple times', async () => {
    process.env.OCDC_CACHE_DIR = testDir
    process.env.OCDC_CONFIG_DIR = join(testDir, 'config')
    
    await ensureDirs()
    await ensureDirs() // Should not throw
    
    assert.ok(existsSync(testDir))
  })

  test('creates ports.json if it does not exist', async () => {
    process.env.OCDC_CACHE_DIR = testDir
    process.env.OCDC_CONFIG_DIR = join(testDir, 'config')
    
    await ensureDirs()
    
    assert.ok(existsSync(join(testDir, 'ports.json')))
  })

  test('creates config.json if it does not exist', async () => {
    process.env.OCDC_CACHE_DIR = testDir
    process.env.OCDC_CONFIG_DIR = join(testDir, 'config')
    
    await ensureDirs()
    
    assert.ok(existsSync(join(testDir, 'config', 'config.json')))
  })
})
